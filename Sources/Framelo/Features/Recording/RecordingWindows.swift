import AppKit
import SwiftUI

/// Owns the auxiliary windows of a recording: the countdown, the floating control panel and the region selector.
@MainActor
final class RecordingWindows {
    private var countdownWindow: NSWindow?
    private var hud: NSPanel?
    private var selector: RegionSelectorWindow?

    // MARK: Countdown

    func showCountdown(_ value: Int) {
        let window = countdownWindow ?? makeOverlay(size: CGSize(width: 220, height: 220))
        countdownWindow = window
        window.contentView = NSHostingView(rootView: CountdownView(value: value))
        if let screen = NSScreen.main {
            window.setFrameOrigin(CGPoint(x: screen.frame.midX - 110, y: screen.frame.midY - 110))
        }
        window.orderFrontRegardless()
    }

    func hideCountdown() {
        countdownWindow?.orderOut(nil)
        countdownWindow = nil
    }

    private func makeOverlay(size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        return window
    }

    // MARK: Floating controls

    func showHUD(controller: RecordingController) {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 300, height: 52),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: RecordingHUD(controller: controller))
        if let screen = NSScreen.main {
            panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - 150, y: screen.visibleFrame.minY + 36))
        }
        panel.orderFrontRegardless()
        hud = panel
    }

    func hideHUD() {
        hud?.orderOut(nil)
        hud = nil
    }

    // MARK: Region selection

    /// Lets the user drag a rectangle on `screen`. Calls back with the rectangle in the display's points,
    /// top-left origin, or `nil` if cancelled.
    func selectRegion(on screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        let window = RegionSelectorWindow(screen: screen) { [weak self] rect in
            self?.selector?.orderOut(nil)
            self?.selector = nil
            completion(rect)
        }
        selector = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct CountdownView: View {
    var value: Int

    var body: some View {
        ZStack {
            Circle().fill(.black.opacity(0.72))
            Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            Text("\(value)")
                .font(.system(size: 104, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        }
        .padding(10)
    }
}

/// Compact control panel that floats above everything while recording. It belongs to Framelo's own process,
/// which is excluded from display capture, so it never appears in the recording.
struct RecordingHUD: View {
    var controller: RecordingController

    var body: some View {
        HStack(spacing: Theme.m) {
            Circle()
                .fill(controller.phase == .paused ? Theme.textTint : Theme.danger)
                .frame(width: 9, height: 9)
            Text(formatTime(controller.elapsed))
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 58, alignment: .leading)
            Spacer(minLength: 0)
            IconButton(symbol: controller.phase == .paused ? "play.fill" : "pause.fill",
                       help: controller.phase == .paused ? "Resume (⇧⌘P)" : "Pause (⇧⌘P)", size: 30) {
                controller.togglePause()
            }
            IconButton(symbol: "trash", help: "Discard recording", size: 30) { controller.discard() }
            Button {
                controller.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.danger)
            .help("Stop and open in the editor (⇧⌘2)")
        }
        .padding(.horizontal, Theme.m)
        .frame(width: 300, height: 52)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: 0x1A1A1D)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
        .preferredColorScheme(.dark)
    }
}

// MARK: Region selector

final class RegionSelectorWindow: NSWindow {
    init(screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        isReleasedWhenClosed = false
        contentView = RegionSelectorView(frame: CGRect(origin: .zero, size: screen.frame.size), completion: completion)
    }

    override var canBecomeKey: Bool { true }
}

final class RegionSelectorView: NSView {
    private let completion: (CGRect?) -> Void
    private var start: CGPoint?
    private var current: CGPoint?

    init(frame: CGRect, completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.45).setFill()
        bounds.fill()
        if let selection {
            NSColor.clear.setFill()
            selection.fill(using: .copy)
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
            path.lineWidth = 1.5
            path.stroke()
            let label = "\(Int(selection.width)) × \(Int(selection.height))" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                                             .foregroundColor: NSColor.white]
            label.draw(at: CGPoint(x: selection.minX + 6, y: selection.maxY + 6), withAttributes: attributes)
        } else {
            let hint = "Drag to choose the area to record  ·  Esc to cancel" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .medium),
                                                             .foregroundColor: NSColor.white]
            let size = hint.size(withAttributes: attributes)
            hint.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY), withAttributes: attributes)
        }
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let selection, selection.width >= 64, selection.height >= 64 else {
            start = nil
            current = nil
            needsDisplay = true
            return
        }
        // AppKit's origin is bottom-left; ScreenCaptureKit's source rectangle is top-left.
        completion(CGRect(x: selection.minX, y: bounds.height - selection.maxY, width: selection.width, height: selection.height))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { completion(nil) } else { super.keyDown(with: event) }
    }
}
