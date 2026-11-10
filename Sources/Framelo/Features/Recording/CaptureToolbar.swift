import AppKit
import FrameloCore
import SwiftUI

/// Floating capture bar shown at the bottom of the screen when starting a recording:
/// choose what to record, pick the inputs, then press Record.
struct CaptureToolbar: View {
    var controller: RecordingController
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.4))
                .frame(width: 26, height: 44)
                .overlay(WindowDragArea())
                .help("Drag to move")
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.white))
            }
            .buttonStyle(.plain)
            .help("Close")
            .padding(.leading, 6)
            .padding(.trailing, 12)

            separator

            HStack(spacing: 4) {
                displayButton
                windowButton
                targetButton(.region, title: "Area", symbol: "rectangle.dashed") { controller.selectRegion() }
            }
            .padding(.horizontal, 6)

            separator

            HStack(spacing: 2) {
                deviceMenu(symbol: controller.captureCamera ? "video" : "video.slash",
                           title: controller.captureCamera ? deviceName(controller.cameraID, in: controller.cameras, fallback: "Camera") : "No camera") {
                    Button("No camera") { controller.captureCamera = false }
                    Divider()
                    ForEach(controller.cameras) { device in
                        Button(device.name) {
                            controller.cameraID = device.id
                            controller.captureCamera = true
                        }
                    }
                }
                deviceMenu(symbol: controller.captureMicrophone ? "mic" : "mic.slash",
                           title: controller.captureMicrophone ? deviceName(controller.microphoneID, in: controller.microphones, fallback: "Microphone") : "No microphone") {
                    Button("No microphone") { controller.captureMicrophone = false }
                    Divider()
                    Button("System default") {
                        controller.microphoneID = nil
                        controller.captureMicrophone = true
                    }
                    ForEach(controller.microphones) { device in
                        Button(device.name) {
                            controller.microphoneID = device.id
                            controller.captureMicrophone = true
                        }
                    }
                }
                Button {
                    controller.captureSystemAudio.toggle()
                } label: {
                    pill(symbol: controller.captureSystemAudio ? "speaker.wave.2" : "speaker.slash",
                         title: controller.captureSystemAudio ? "System audio" : "No system audio",
                         active: controller.captureSystemAudio)
                }
                .buttonStyle(.plain)
                .help("Record the sound your Mac plays")
            }
            .padding(.horizontal, 6)

            separator

            HStack(spacing: 2) {
                ToolbarIcon(symbol: "folder", help: "Open recordings folder") {
                    NSWorkspace.shared.open(LibraryLocation.standard.root)
                }
                settingsMenu
                if controller.target != nil {
                    Button {
                        controller.begin()
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(.white).frame(width: 7, height: 7)
                            Text("Record").font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .background(Capsule().fill(Theme.danger))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .help("Start recording \(controller.targetDescription)")
                    .padding(.leading, 6)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.leading, 4)
        .frame(height: 56)
        .background(VisualEffect().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.16)))
        .overlay(alignment: .top) {
            if let error = controller.sourceError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.textTint)
                    Text(error).lineLimit(2)
                    Button("Open Settings") { NSWorkspace.shared.open(PermissionKind.screenRecording.settingsURL) }
                    Button("Relaunch Framelo") { controller.relaunch() }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.85)))
                .fixedSize()
                .offset(y: -46)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: controller.target != nil)
        .preferredColorScheme(.dark)
        .task { await controller.loadSources() }
    }

    private var separator: some View {
        Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 32)
    }

    private var displayButton: some View {
        Group {
            if controller.displays.count > 1 {
                Menu {
                    ForEach(controller.displays) { display in
                        Button("\(display.name) — \(display.width)×\(display.height)") {
                            controller.displayID = display.id
                            controller.targetKind = .display
                        }
                    }
                } label: {
                    targetLabel(.display, title: "Display", symbol: "menubar.dock.rectangle")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                targetButton(.display, title: "Display", symbol: "menubar.dock.rectangle") {
                    controller.displayID = controller.displayID ?? controller.displays.first?.id
                }
            }
        }
        .help("Record a whole display")
    }

    private var windowButton: some View {
        Menu {
            if controller.windows.isEmpty {
                Text(controller.sourceError ?? "No windows available")
            }
            ForEach(controller.windows) { window in
                Button("\(window.appName) — \(window.title)") {
                    controller.windowID = window.id
                    controller.targetKind = .window
                }
            }
        } label: {
            targetLabel(.window, title: "Window", symbol: "macwindow")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Record one window")
    }

    private func targetButton(_ kind: RecordingController.TargetKind, title: String, symbol: String,
                              action: @escaping () -> Void) -> some View {
        Button {
            Task {
                if controller.displays.isEmpty { await controller.loadSources() }
                controller.targetKind = kind
                action()
            }
        } label: {
            targetLabel(kind, title: title, symbol: symbol)
        }
        .buttonStyle(.plain)
    }

    private func targetLabel(_ kind: RecordingController.TargetKind, title: String, symbol: String) -> some View {
        let selected = controller.targetKind == kind && controller.target != nil
        return VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 15, weight: .regular))
            Text(title).font(.system(size: 9.5, weight: .medium))
        }
        .foregroundStyle(selected ? Color.white : Color.white.opacity(0.72))
        .frame(width: 52, height: 44)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(selected ? 0.16 : 0)))
        .contentShape(Rectangle())
    }

    private func deviceMenu<Content: View>(symbol: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        Menu(content: content) {
            pill(symbol: symbol, title: title, active: !title.hasPrefix("No "))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func pill(symbol: String, title: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 12))
            Text(title).font(.system(size: 11.5)).lineLimit(1)
        }
        .foregroundStyle(active ? Color.white : Color.white.opacity(0.55))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(active ? 0.1 : 0)))
        .contentShape(Rectangle())
    }

    private var settingsMenu: some View {
        Menu {
            Picker("Frame rate", selection: Binding(get: { controller.frameRate }, set: { controller.frameRate = $0 })) {
                Text("30 fps").tag(30)
                Text("60 fps").tag(60)
            }
            Picker("Resolution", selection: Binding(get: { controller.resolution }, set: { controller.resolution = $0 })) {
                ForEach(RecordingConfig.Resolution.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Countdown", selection: Binding(get: { controller.countdown }, set: { controller.countdown = $0 })) {
                Text("None").tag(0)
                Text("3 seconds").tag(3)
                Text("5 seconds").tag(5)
                Text("10 seconds").tag(10)
            }
            Toggle("Microphone noise reduction", isOn: Binding(get: { controller.noiseReduction }, set: { controller.noiseReduction = $0 }))
            Divider()
            Text("Stop \(HotKeyCenter.Shortcut.toggleRecording.display) · Pause \(HotKeyCenter.Shortcut.togglePause.display)")
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gearshape").font(.system(size: 14))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Color.white.opacity(0.8))
            .frame(width: 40, height: 30)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Recording settings")
    }

    private func deviceName(_ id: String?, in devices: [CaptureDeviceInfo], fallback: String) -> String {
        devices.first { $0.id == id }?.name ?? (id == nil ? fallback : fallback)
    }
}

struct ToolbarIcon: View {
    var symbol: String
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Color.white.opacity(hovering ? 1 : 0.8))
                .frame(width: 32, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(hovering ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Native translucent material behind floating panels.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Drag handle for the borderless panel. Used only on the grip so it never covers the buttons.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
}
