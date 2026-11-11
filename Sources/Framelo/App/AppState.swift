import AppKit
import FrameloCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct AlertInfo: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

/// Top-level application state: navigation, the project library and the recording controller.
@MainActor @Observable
final class AppState {
    enum Route { case splash, dashboard, editor }

    static let splashDuration: Duration = .seconds(3)

    var route = Route.splash
    var projects: [ProjectSummary] = []
    var editor: EditorModel?
    var alert: AlertInfo?
    var notice: String?
    var showRecordingSetup = false
    var permissions: [PermissionKind: PermissionStatus] = [:]
    var isBusy = false

    let store = ProjectStore()
    let recorder: RecordingController
    let preferences = Preferences()

    init() {
        recorder = RecordingController(store: store)
        recorder.onFinished = { [weak self] project, notices in
            guard let self else { return }
            Task { await self.recordingFinished(project, notices: notices) }
        }
        recorder.onError = { [weak self] message in
            self?.alert = AlertInfo(title: "Recording", message: message)
        }
    }

    /// Runs once at launch: prepares the library, recovers interrupted recordings, then leaves the splash screen.
    func bootstrap() async {
        let started = ContinuousClock.now
        do {
            try await store.prepareLibrary()
        } catch {
            alert = AlertInfo(title: "Library unavailable",
                              message: "Framelo could not create its library in your Movies folder: \(error.localizedDescription)")
        }
        let report = await RecoveryService.run(store: store)
        if !report.recovered.isEmpty {
            notice = report.recovered.count == 1
                ? "An interrupted recording was recovered and added to your projects."
                : "\(report.recovered.count) interrupted recordings were recovered and added to your projects."
        } else if !report.quarantined.isEmpty {
            notice = "An interrupted recording could not be recovered. Its files were kept in Movies/Framelo/Recovery."
        }
        await refresh()
        refreshPermissions()
        applyHotKeyPreference()
        let remaining = Self.splashDuration - (ContinuousClock.now - started)
        if remaining > .zero, preferences.showSplash { try? await Task.sleep(for: remaining) }
        withAnimation(.easeInOut(duration: 0.45)) { route = .dashboard }
        // `Framelo --import <video>` opens a video straight into the editor (handy for scripting and testing).
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--import"), index + 1 < arguments.count {
            await importVideo(at: URL(fileURLWithPath: arguments[index + 1]))
        }
    }

    func importVideo(at url: URL) async {
        isBusy = true
        defer { isBusy = false }
        do {
            var project = try await MediaImporter.importVideo(url, store: store)
            preferences.applyDefaults(to: &project)
            try await store.save(project)
            await refresh()
            await openEditor(project)
        } catch {
            alert = AlertInfo(title: "Could not import video", message: error.localizedDescription)
        }
    }

    func refresh() async {
        projects = await store.list()
    }

    func refreshPermissions() {
        for kind in PermissionKind.allCases { permissions[kind] = PermissionManager.status(kind) }
    }

    func requestPermission(_ kind: PermissionKind) {
        Task {
            let status = await PermissionManager.request(kind)
            permissions[kind] = status
            if status != .granted { NSWorkspace.shared.open(kind.settingsURL) }
        }
    }

    /// Registers or removes the global shortcuts according to Settings › General.
    func applyHotKeyPreference() {
        HotKeyCenter.shared.unregisterAll()
        if preferences.globalShortcutsEnabled { registerHotKeys() }
    }

    private func registerHotKeys() {
        HotKeyCenter.shared.register(.toggleRecording) { [weak self] in
            guard let self else { return }
            if self.recorder.isActive {
                self.recorder.stop()
            } else if self.recorder.phase == .idle {
                self.recorder.beginWithCurrentSettings()
            }
        }
        HotKeyCenter.shared.register(.togglePause) { [weak self] in self?.recorder.togglePause() }
    }

    // MARK: Projects

    func open(_ id: UUID) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let project = try await store.load(id: id)
                await openEditor(project)
            } catch {
                alert = AlertInfo(title: "Could not open project", message: error.localizedDescription)
            }
        }
    }

    private func openEditor(_ project: Project) async {
        editor?.close()
        let model = EditorModel(project: project, store: store)
        editor = model
        withAnimation(.easeInOut(duration: 0.25)) { route = .editor }
        await model.load()
    }

    func closeEditor() {
        guard let editor else { return }
        Task {
            await editor.saveNow()
            editor.close()
            self.editor = nil
            await refresh()
            withAnimation(.easeInOut(duration: 0.25)) { route = .dashboard }
        }
    }

    private func recordingFinished(_ recorded: Project, notices: [String]) async {
        var project = recorded
        preferences.applyDefaults(to: &project)
        try? await store.save(project)
        await refresh()
        if preferences.openEditorAfterRecording {
            await openEditor(project)
        } else {
            withAnimation(.easeInOut(duration: 0.25)) { route = .dashboard }
        }
        var messages = notices
        if !preferences.openEditorAfterRecording { messages.insert("“\(project.name)” was saved to your library.", at: 0) }
        if !messages.isEmpty { notice = messages.joined(separator: "\n") }
        NSApp.activate(ignoringOtherApps: true)
    }

    func importVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a video to edit. The original file is never modified."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await importVideo(at: url) }
    }

    /// Moves every project to the Trash (Settings › Privacy & Data).
    func trashAllProjects() {
        Task {
            for project in projects { try? await store.trash(id: project.id) }
            await refresh()
        }
    }

    func trash(_ id: UUID) {
        Task {
            do {
                try await store.trash(id: id)
            } catch {
                alert = AlertInfo(title: "Could not move to Trash", message: error.localizedDescription)
            }
            await refresh()
        }
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            try? await store.rename(id: id, to: trimmed)
            await refresh()
        }
    }

    func revealInFinder(_ summary: ProjectSummary) {
        NSWorkspace.shared.activateFileViewerSelecting([summary.packageURL])
    }
}
