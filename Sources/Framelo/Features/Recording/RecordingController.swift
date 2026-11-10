import AppKit
import FrameloCore
import Observation
import SwiftUI

/// Drives the recording flow for the UI: source lists, settings, countdown, the session and its floating controls.
@MainActor @Observable
final class RecordingController {
    enum Phase: Equatable { case idle, countdown(Int), starting, recording, paused, finishing }
    enum TargetKind: String, CaseIterable, Identifiable {
        case display, window, region
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .display: "display"
            case .window: "macwindow"
            case .region: "rectangle.dashed"
            }
        }
    }

    // Sources
    var displays: [DisplayInfo] = []
    var windows: [WindowInfo] = []
    var cameras: [CaptureDeviceInfo] = []
    var microphones: [CaptureDeviceInfo] = []
    var sourceError: String?

    // Settings (remembered between launches)
    var targetKind = TargetKind.display
    var displayID: UInt32?
    var windowID: UInt32?
    var region: CGRect?
    var regionDisplayID: UInt32?
    var frameRate = 60 { didSet { defaults.set(frameRate, forKey: "rec.fps") } }
    var resolution = RecordingConfig.Resolution.native { didSet { defaults.set(resolution.rawValue, forKey: "rec.resolution") } }
    var captureSystemAudio = true { didSet { defaults.set(captureSystemAudio, forKey: "rec.system") } }
    var captureMicrophone = true { didSet { defaults.set(captureMicrophone, forKey: "rec.mic") } }
    var noiseReduction = false { didSet { defaults.set(noiseReduction, forKey: "rec.noise") } }
    var captureCamera = false { didSet { defaults.set(captureCamera, forKey: "rec.camera") } }
    var microphoneID: String?
    var cameraID: String?
    var countdown = 3 { didSet { defaults.set(countdown, forKey: "rec.countdown") } }

    // State
    private(set) var phase = Phase.idle
    private(set) var elapsed = 0.0
    var onFinished: (Project, [String]) -> Void = { _, _ in }
    var onError: (String) -> Void = { _ in }

    private let store: ProjectStore
    private let defaults = UserDefaults.standard
    private var session: RecordingSession?
    private var ticker: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private let windowsController = RecordingWindows()
    private var hiddenWindows: [NSWindow] = []

    init(store: ProjectStore) {
        self.store = store
        if defaults.object(forKey: "rec.fps") != nil {
            frameRate = defaults.integer(forKey: "rec.fps") == 30 ? 30 : 60
            resolution = RecordingConfig.Resolution(rawValue: defaults.string(forKey: "rec.resolution") ?? "") ?? .native
            captureSystemAudio = defaults.bool(forKey: "rec.system")
            captureMicrophone = defaults.bool(forKey: "rec.mic")
            noiseReduction = defaults.bool(forKey: "rec.noise")
            captureCamera = defaults.bool(forKey: "rec.camera")
            countdown = defaults.integer(forKey: "rec.countdown")
        }
    }

    var isActive: Bool { phase == .recording || phase == .paused }

    func loadSources() async {
        cameras = CaptureCatalog.cameras()
        microphones = CaptureCatalog.microphones()
        do {
            displays = try await CaptureCatalog.displays()
            windows = try await CaptureCatalog.windows()
            sourceError = nil
            if displayID == nil || !displays.contains(where: { $0.id == displayID }) { displayID = displays.first?.id }
            if windowID != nil, !windows.contains(where: { $0.id == windowID }) { windowID = nil }
        } catch {
            displays = []
            windows = []
            sourceError = PermissionManager.status(.screenRecording) == .granted
                ? error.localizedDescription
                : "Screen Recording is not allowed for this copy of Framelo. Turn it on in System Settings, then relaunch."
        }
        if sourceError == nil, displays.isEmpty {
            sourceError = "No displays are available to record."
        }
    }

    /// The target chosen in the UI, or `nil` when the selection is incomplete.
    var target: RecordingConfig.Target? {
        switch targetKind {
        case .display:
            return displayID.map { .display(id: $0) }
        case .window:
            return windowID.map { .window(id: $0) }
        case .region:
            guard let region, let regionDisplayID else { return nil }
            return .region(displayID: regionDisplayID, x: region.minX, y: region.minY, width: region.width, height: region.height)
        }
    }

    var targetDescription: String {
        switch targetKind {
        case .display: displays.first { $0.id == displayID }?.name ?? "Display"
        case .window: windows.first { $0.id == windowID }?.title ?? "Window"
        case .region: region.map { "Region \(Int($0.width))×\(Int($0.height))" } ?? "Region"
        }
    }

    /// Quits and reopens Framelo — macOS applies a newly granted Screen Recording permission only to a new process.
    func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Shows the floating capture toolbar and hides Framelo's own windows so the screen is clear.
    func showToolbar() {
        guard phase == .idle else { return }
        hideAppWindows()
        windowsController.showToolbar(controller: self)
        Task { await loadSources() }
    }

    func hideToolbar() {
        windowsController.hideToolbar()
        if phase == .idle { restoreAppWindows() }
    }

    func selectRegion() {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == (displayID ?? CGMainDisplayID()) }) ?? NSScreen.main else { return }
        windowsController.selectRegion(on: screen) { [weak self] rect in
            guard let self, let rect else { return }
            self.region = rect
            self.regionDisplayID = screen.displayID
            self.targetKind = .region
        }
    }

    // MARK: Lifecycle

    /// Starts with whatever is currently configured (used by the global shortcut and the menu bar).
    func beginWithCurrentSettings() {
        Task {
            if displays.isEmpty { await loadSources() }
            if target == nil { targetKind = .display; displayID = displayID ?? displays.first?.id }
            begin()
        }
    }

    func begin() {
        guard phase == .idle else { return }
        guard PermissionManager.status(.screenRecording) == .granted else {
            _ = CGRequestScreenCaptureAccess()
            onError(RecordingError.permissionDenied(.screenRecording).localizedDescription +
                    "\n\nAfter allowing it, quit and reopen Framelo so macOS applies the change.")
            return
        }
        guard let target else {
            onError("Choose what to record first: a display, a window or a region.")
            return
        }
        let config = RecordingConfig(target: target, frameRate: frameRate, resolution: resolution,
                                     captureSystemAudio: captureSystemAudio, captureMicrophone: captureMicrophone,
                                     microphoneID: microphoneID, noiseReduction: noiseReduction,
                                     captureCamera: captureCamera, cameraID: cameraID, countdownSeconds: countdown)
        let name = "Recording " + Date().formatted(date: .abbreviated, time: .shortened)
        let session = RecordingSession(config: config, name: name, store: store)
        self.session = session

        windowsController.hideToolbar()
        if hiddenWindows.isEmpty { hideAppWindows() }
        countdownTask = Task {
            if countdown > 0 {
                for remaining in stride(from: countdown, to: 0, by: -1) {
                    phase = .countdown(remaining)
                    windowsController.showCountdown(remaining)
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                }
                windowsController.hideCountdown()
            }
            phase = .starting
            do {
                try await session.start()
                // Only now is something actually being written to disk.
                phase = .recording
                elapsed = 0
                windowsController.showHUD(controller: self)
                startTicking(session)
                watch(session)
            } catch {
                self.session = nil
                phase = .idle
                restoreAppWindows()
                onError(error.localizedDescription)
            }
        }
    }

    func cancelCountdown() {
        guard case .countdown = phase else { return }
        countdownTask?.cancel()
        windowsController.hideCountdown()
        session = nil
        phase = .idle
        restoreAppWindows()
    }

    private func startTicking(_ session: RecordingSession) {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.elapsed = session.clock.elapsed
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Reacts to the session stopping on its own (display unplugged, window closed, disk error).
    private func watch(_ session: RecordingSession) {
        watcher?.cancel()
        watcher = Task { [weak self] in
            for await phase in session.phases {
                if case .interrupted = phase { self?.stop() }
            }
        }
    }

    func togglePause() {
        guard let session else { return }
        Task {
            if phase == .recording {
                try? await session.pause()
                phase = .paused
            } else if phase == .paused {
                try? await session.resume()
                phase = .recording
            }
        }
    }

    func stop() {
        guard let session, isActive else { return }
        phase = .finishing
        ticker?.cancel()
        watcher?.cancel()
        windowsController.hideHUD()
        Task {
            defer {
                self.session = nil
                phase = .idle
                restoreAppWindows()
            }
            do {
                let project = try await session.stop()
                let notices = await session.notices
                onFinished(project, notices)
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    func discard() {
        guard let session, isActive else { return }
        phase = .finishing
        ticker?.cancel()
        watcher?.cancel()
        windowsController.hideHUD()
        Task {
            await session.discard()
            self.session = nil
            phase = .idle
            restoreAppWindows()
        }
    }

    private func hideAppWindows() {
        hiddenWindows = NSApp.windows.filter { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
        hiddenWindows.forEach { $0.orderOut(nil) }
    }

    private func restoreAppWindows() {
        hiddenWindows.forEach { $0.makeKeyAndOrderFront(nil) }
        hiddenWindows = []
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension NSScreen {
    var displayID: UInt32 {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }
}
