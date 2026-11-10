import AppKit
import FrameloCore
import SwiftUI

struct DashboardView: View {
    @Environment(AppState.self) private var app
    @State private var renaming: ProjectSummary?
    @State private var newName = ""

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: Theme.l)]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Theme.border)
            content
        }
        .onAppear { app.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.refreshPermissions()
        }
        .alert("Rename Project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let renaming { app.rename(renaming.id, to: newName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Theme.l) {
            HStack(spacing: Theme.s) {
                LogoMark(size: 30)
                Text("Framelo").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
            }
            .padding(.top, 38)

            VStack(spacing: Theme.s) {
                Button {
                    app.showRecordingSetup = true
                } label: {
                    Label("New Recording", systemImage: "record.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.primary)
                .disabled(app.recorder.phase != .idle)

                Button {
                    app.importVideo()
                } label: {
                    Label("Import Video", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
                }
                .buttonStyle(.secondary)
            }

            InspectorSection(title: "Quick actions") {
                quickAction("Record with last settings", symbol: "bolt.fill", shortcut: HotKeyCenter.Shortcut.toggleRecording.display) {
                    app.recorder.beginWithCurrentSettings()
                }
                quickAction("Open library folder", symbol: "folder", shortcut: nil) {
                    NSWorkspace.shared.open(app.store.location.root)
                }
            }

            InspectorSection(title: "Recording settings") {
                settingLine("Frame rate", "\(app.recorder.frameRate) fps")
                settingLine("Resolution", app.recorder.resolution.displayName)
                settingLine("Microphone", app.recorder.captureMicrophone ? "On" : "Off")
                settingLine("System audio", app.recorder.captureSystemAudio ? "On" : "Off")
                settingLine("Camera", app.recorder.captureCamera ? "On" : "Off")
            }

            InspectorSection(title: "Permissions") {
                ForEach([PermissionKind.screenRecording, .microphone, .camera]) { kind in
                    permissionRow(kind)
                }
            }
            Spacer()
        }
        .padding(.horizontal, Theme.l)
        .frame(width: 252)
        .background(Theme.panel)
    }

    private func quickAction(_ title: String, symbol: String, shortcut: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.s) {
                Image(systemName: symbol).frame(width: 16).foregroundStyle(Theme.textSecondary)
                Text(title).font(Theme.body).foregroundStyle(Theme.text)
                Spacer()
                if let shortcut { Text(shortcut).font(Theme.caption).foregroundStyle(Theme.textTertiary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func settingLine(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(Theme.body).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).font(Theme.body).foregroundStyle(Theme.text)
        }
    }

    private func permissionRow(_ kind: PermissionKind) -> some View {
        let status = app.permissions[kind] ?? .notDetermined
        return HStack(spacing: Theme.s) {
            Circle().fill(status == .granted ? Theme.success : Theme.danger.opacity(0.85)).frame(width: 7, height: 7)
            Text(kind.displayName).font(Theme.body).foregroundStyle(Theme.textSecondary)
            Spacer()
            if status != .granted {
                Button("Allow") { app.requestPermission(kind) }.buttonStyle(.compact)
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.xl) {
                let recordings = app.projects.filter(\.isRecording)
                let imported = app.projects.filter { !$0.isRecording }
                if app.projects.isEmpty {
                    EmptyState(symbol: "film.stack", title: "No projects yet",
                               message: "Start a recording or import a video.\nEverything stays on this Mac, in Movies/Framelo.")
                        .frame(height: 420)
                } else {
                    if !recordings.isEmpty { section("Recent recordings", recordings) }
                    if !imported.isEmpty { section("Imported projects", imported) }
                }
            }
            .padding(Theme.xl)
            .padding(.top, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func section(_ title: String, _ items: [ProjectSummary]) -> some View {
        VStack(alignment: .leading, spacing: Theme.m) {
            Text(title).font(Theme.title).foregroundStyle(Theme.text)
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.l) {
                ForEach(items) { summary in
                    ProjectCard(summary: summary)
                        .onTapGesture(count: 2) { app.open(summary.id) }
                        .contextMenu {
                            Button("Open") { app.open(summary.id) }
                            Button("Rename…") {
                                newName = summary.name
                                renaming = summary
                            }
                            Button("Show in Finder") { app.revealInFinder(summary) }
                            Divider()
                            Button("Move to Trash", role: .destructive) { app.trash(summary.id) }
                        }
                }
            }
        }
    }
}

struct ProjectCard: View {
    @Environment(AppState.self) private var app
    var summary: ProjectSummary
    @State private var hovering = false
    @State private var poster: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.s) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous).fill(Theme.raised)
                if let poster {
                    Image(nsImage: poster).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.textTertiary)
                }
                if hovering {
                    Color.black.opacity(0.35)
                    Button("Open") { app.open(summary.id) }.buttonStyle(.primary)
                }
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusM, style: .continuous)
                .strokeBorder(hovering ? Theme.borderStrong : Theme.border))
            .overlay(alignment: .bottomTrailing) {
                Text(formatTime(summary.duration))
                    .font(Theme.mono).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.6)))
                    .padding(Theme.s)
            }
            .overlay(alignment: .topLeading) {
                if summary.isRecovered {
                    Text("Recovered")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.textTint))
                        .padding(Theme.s)
                }
            }

            Text(summary.name).font(Theme.heading).foregroundStyle(Theme.text).lineLimit(1)
            Text(summary.updatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(Theme.caption).foregroundStyle(Theme.textSecondary)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .task(id: summary.posterURL) {
            guard let url = summary.posterURL else { return }
            poster = NSImage(contentsOf: url)
        }
    }
}
