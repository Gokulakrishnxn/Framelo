import AppKit
import FrameloCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When launched as a bare executable (swift run) there is no bundle to make it a regular app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
        return true
    }
}

@main
struct FrameloApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState()

    var body: some Scene {
        Window("Framelo", id: "main") {
            RootView()
                .environment(app)
                .frame(minWidth: 1080, minHeight: 680)
                .preferredColorScheme(.dark)
                .task { await app.bootstrap() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Recording…") { app.showRecordingSetup = true }
                    .keyboardShortcut("n")
                    .disabled(app.recorder.phase != .idle)
                Button("Import Video…") { app.importVideo() }
                    .keyboardShortcut("i")
            }
            CommandGroup(replacing: .undoRedo) {
                Button(app.editor?.undoTitle ?? "Undo") { app.editor?.undo() }
                    .keyboardShortcut("z")
                    .disabled(!(app.editor?.canUndo ?? false))
                Button(app.editor?.redoTitle ?? "Redo") { app.editor?.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!(app.editor?.canRedo ?? false))
            }
            CommandMenu("Edit Timeline") {
                Group {
                    Button("Split at Playhead") { app.editor?.splitAtPlayhead() }
                        .keyboardShortcut("b")
                    Button("Delete Selection") { app.editor?.deleteSelection() }
                        .keyboardShortcut(.delete, modifiers: [.command])
                    Divider()
                    Button("Add Zoom at Playhead") { app.editor?.addZoom() }
                        .keyboardShortcut("z", modifiers: [.option])
                    Button("Add Keyframe at Playhead") { app.editor?.addKeyframe() }
                        .keyboardShortcut("k", modifiers: [.option])
                    Button("Add Text at Playhead") { app.editor?.addText() }
                        .keyboardShortcut("t", modifiers: [.option])
                    Button("Regenerate Automatic Zooms") { app.editor?.regenerateAutoZoom() }
                    Divider()
                    Button("Export…") { app.editor?.showExport = true }
                        .keyboardShortcut("e")
                }
                .disabled(app.editor == nil)
            }
        }

        MenuBarExtra {
            MenuBarContent().environment(app)
        } label: {
            MenuBarLabel(recorder: app.recorder)
        }
    }
}

/// Menu bar icon: a dot that turns into a live timer while recording.
struct MenuBarLabel: View {
    var recorder: RecordingController

    var body: some View {
        if recorder.isActive {
            Label(formatTime(recorder.elapsed), systemImage: recorder.phase == .paused ? "pause.circle.fill" : "record.circle.fill")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "record.circle")
        }
    }
}

struct MenuBarContent: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let recorder = app.recorder
        if recorder.isActive {
            Text("Recording — \(formatTime(recorder.elapsed))")
            Button(recorder.phase == .paused ? "Resume" : "Pause") { recorder.togglePause() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Stop Recording") { recorder.stop() }
                .keyboardShortcut("2", modifiers: [.command, .shift])
            Button("Discard Recording") { recorder.discard() }
        } else {
            Button("New Recording…") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                app.showRecordingSetup = true
            }
            .disabled(recorder.phase != .idle)
            Button("Record with Last Settings") { recorder.beginWithCurrentSettings() }
                .keyboardShortcut("2", modifiers: [.command, .shift])
                .disabled(recorder.phase != .idle)
        }
        Divider()
        Button("Open Framelo") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit Framelo") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        ZStack {
            Theme.background.ignoresSafeArea()
            switch app.route {
            case .splash:
                SplashView().transition(.opacity)
            case .dashboard:
                DashboardView().transition(.opacity)
            case .editor:
                if let editor = app.editor {
                    EditorView(model: editor).transition(.opacity)
                }
            }
            if app.isBusy {
                ProgressView().controlSize(.large).padding(Theme.xl)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusL).fill(.ultraThinMaterial))
            }
        }
        .overlay(alignment: .top) {
            if let notice = app.notice {
                NoticeBanner(text: notice) { app.notice = nil }
                    .padding(.top, 44)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: app.notice)
        .sheet(isPresented: $app.showRecordingSetup) {
            RecordingSetupView().environment(app)
        }
        .alert(item: $app.alert) { info in
            Alert(title: Text(info.title), message: Text(info.message), dismissButton: .default(Text("OK")))
        }
    }
}

struct NoticeBanner: View {
    var text: String
    var dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.s) {
            Image(systemName: "info.circle.fill").foregroundStyle(Theme.accent)
            Text(text).font(Theme.body).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            IconButton(symbol: "xmark", help: "Dismiss", size: 20, action: dismiss)
        }
        .padding(Theme.m)
        .frame(maxWidth: 520)
        .background(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous).strokeBorder(Theme.borderStrong))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
    }
}
