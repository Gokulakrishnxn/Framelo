import AppKit
import FrameloCore
import SwiftUI

/// Framelo › Settings (⌘,). A sidebar of categories, each with real, persisted options.
struct SettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case profile, general, appearance, recording, editing, export, storage, shortcuts, privacy, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .profile: "Profile"
            case .general: "General"
            case .appearance: "Appearance"
            case .recording: "Recording"
            case .editing: "Editing"
            case .export: "Export"
            case .storage: "Storage"
            case .shortcuts: "Shortcuts"
            case .privacy: "Privacy & Data"
            case .about: "About"
            }
        }
        var symbol: String {
            switch self {
            case .profile: "person.crop.circle"
            case .general: "gearshape"
            case .appearance: "paintbrush"
            case .recording: "record.circle"
            case .editing: "slider.horizontal.3"
            case .export: "square.and.arrow.up"
            case .storage: "internaldrive"
            case .shortcuts: "command"
            case .privacy: "hand.raised"
            case .about: "info.circle"
            }
        }
        var tint: Color {
            switch self {
            case .profile: Color(hex: 0x0A84FF)
            case .general: Color(hex: 0x8E8E93)
            case .appearance: Color(hex: 0xBF5AF2)
            case .recording: Color(hex: 0xFF453A)
            case .editing: Color(hex: 0xFF9F0A)
            case .export: Color(hex: 0x30D158)
            case .storage: Color(hex: 0x64D2FF)
            case .shortcuts: Color(hex: 0x5E5CE6)
            case .privacy: Color(hex: 0x0A84FF)
            case .about: Color(hex: 0x00D1BF)
            }
        }
    }

    @Environment(AppState.self) private var app
    @State private var page: Page? = .profile

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section {
                    profileRow.tag(Page.profile)
                }
                Section {
                    ForEach([Page.general, .appearance, .recording, .editing, .export]) { item in row(item).tag(item) }
                }
                Section {
                    ForEach([Page.storage, .shortcuts, .privacy, .about]) { item in row(item).tag(item) }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 260)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text((page ?? .profile).title).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.text)
                    switch page ?? .profile {
                    case .profile: ProfileSettings()
                    case .general: GeneralSettings()
                    case .appearance: AppearanceSettings()
                    case .recording: RecordingSettings()
                    case .editing: EditingSettings()
                    case .export: ExportDefaultsSettings()
                    case .storage: StorageSettings()
                    case .shortcuts: ShortcutsSettings()
                    case .privacy: PrivacySettings()
                    case .about: AboutSettings()
                    }
                }
                .padding(28)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.background)
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    private var profileRow: some View {
        HStack(spacing: 10) {
            AvatarView(preferences: app.preferences, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.preferences.displayName.isEmpty ? "Your Name" : app.preferences.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Text("Profile").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ item: Page) -> some View {
        Label {
            Text(item.title)
        } icon: {
            Image(systemName: item.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(item.tint))
        }
    }
}

// MARK: Building blocks

/// A rounded group of settings rows, like System Settings.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSecondary).padding(.leading, 4)
            }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
            if let footer {
                Text(footer).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One row: label (and optional description) on the left, a control on the right.
struct SettingsRow<Control: View>: View {
    var title: String
    var detail: String?
    var showsDivider = true
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13)).foregroundStyle(Theme.text)
                    if let detail {
                        Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            if showsDivider { Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 14) }
        }
    }
}

private func formatBytes(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

// MARK: Pages

struct ProfileSettings: View {
    @Environment(AppState.self) private var app
    @State private var error: String?

    var body: some View {
        @Bindable var prefs = app.preferences
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 18) {
                AvatarView(preferences: prefs, size: 76)
                VStack(alignment: .leading, spacing: 8) {
                    Text(prefs.displayName.isEmpty ? "Your Name" : prefs.displayName).font(.system(size: 18, weight: .semibold))
                    HStack(spacing: 8) {
                        Button("Choose Photo…") { choosePhoto() }
                        if prefs.avatarPath != nil { Button("Remove") { prefs.removeAvatar() } }
                    }
                    .controlSize(.small)
                }
            }
            SettingsGroup(title: "Details", footer: "Your profile stays on this Mac. Framelo has no accounts and never uploads anything.") {
                SettingsRow(title: "Name") {
                    TextField("Name", text: $prefs.displayName).textFieldStyle(.roundedBorder).frame(width: 240)
                }
                SettingsRow(title: "Email", detail: "Optional", showsDivider: false) {
                    TextField("you@example.com", text: $prefs.email).textFieldStyle(.roundedBorder).frame(width: 240)
                }
            }
            SettingsGroup(title: "Credits", footer: "Adds your name as the author in exported video files, visible in Finder's Get Info and most video players.") {
                SettingsRow(title: "Add my name to exported videos", showsDivider: false) {
                    Toggle("", isOn: $prefs.embedAuthorInExports).toggleStyle(.switch).labelsHidden()
                }
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
        }
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try app.preferences.setAvatar(from: url); error = nil } catch { self.error = error.localizedDescription }
    }
}

struct GeneralSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var prefs = app.preferences
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "After recording") {
                SettingsRow(title: "Open the recording in the editor",
                            detail: "When off, Framelo returns to your project library instead.", showsDivider: false) {
                    Toggle("", isOn: $prefs.openEditorAfterRecording).toggleStyle(.switch).labelsHidden()
                }
            }
            SettingsGroup(title: "Startup") {
                SettingsRow(title: "Show the splash screen at launch", showsDivider: false) {
                    Toggle("", isOn: $prefs.showSplash).toggleStyle(.switch).labelsHidden()
                }
            }
            SettingsGroup(title: "Global shortcuts",
                          footer: "Work from any app, even when Framelo is in the background. Changes apply immediately.") {
                SettingsRow(title: "Enable \(HotKeyCenter.Shortcut.toggleRecording.display) and \(HotKeyCenter.Shortcut.togglePause.display)",
                            showsDivider: false) {
                    Toggle("", isOn: Binding(get: { prefs.globalShortcutsEnabled },
                                             set: { prefs.globalShortcutsEnabled = $0; app.applyHotKeyPreference() }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
        }
    }
}

struct AppearanceSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var prefs = app.preferences
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Theme") {
                HStack(spacing: 18) {
                    ForEach(ThemeChoice.allCases) { theme in
                        Button { prefs.theme = theme } label: {
                            VStack(spacing: 8) {
                                ThemeSwatch(theme: theme)
                                    .frame(width: 120, height: 78)
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(prefs.theme == theme ? Theme.accent : Theme.border,
                                                                                            lineWidth: prefs.theme == theme ? 2.5 : 1))
                                Text(theme.title).font(.system(size: 12, weight: prefs.theme == theme ? .semibold : .regular))
                                    .foregroundStyle(Theme.text)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsGroup(title: "Accent colour", footer: "Used for buttons, selection and highlights throughout Framelo.") {
                HStack(spacing: 12) {
                    ForEach(AccentChoice.allCases) { choice in
                        Button { prefs.accent = choice } label: {
                            Circle().fill(Color(hex: choice.hex)).frame(width: 24, height: 24)
                                .overlay(Circle().strokeBorder(Color.white, lineWidth: prefs.accent == choice ? 2.5 : 0))
                                .overlay(Circle().strokeBorder(Theme.borderStrong, lineWidth: 1).padding(-3).opacity(prefs.accent == choice ? 1 : 0))
                        }
                        .buttonStyle(.plain)
                        .help(choice.title)
                    }
                    Spacer()
                    Text(prefs.accent.title).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                .padding(16)
            }
        }
    }
}

struct ThemeSwatch: View {
    var theme: ThemeChoice

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if theme != .light { pane(dark: true).frame(width: theme == .system ? geometry.size.width / 2 : geometry.size.width) }
                if theme != .dark { pane(dark: false).frame(width: theme == .system ? geometry.size.width / 2 : geometry.size.width) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func pane(dark: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            Color(hex: dark ? 0x151517 : 0xF4F4F6)
            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 3).fill(Theme.accent).frame(width: 34, height: 8)
                RoundedRectangle(cornerRadius: 3).fill(Color(hex: dark ? 0x2A2A30 : 0xDADADF)).frame(width: 46, height: 6)
                RoundedRectangle(cornerRadius: 3).fill(Color(hex: dark ? 0x2A2A30 : 0xDADADF)).frame(width: 30, height: 6)
            }
            .padding(10)
        }
    }
}

struct RecordingSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var recorder = app.recorder
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Video", footer: "These are also available from the gear menu in the capture bar.") {
                SettingsRow(title: "Frame rate") {
                    Picker("", selection: $recorder.frameRate) { Text("30 fps").tag(30); Text("60 fps").tag(60) }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 160)
                }
                SettingsRow(title: "Resolution") {
                    Picker("", selection: $recorder.resolution) {
                        ForEach(RecordingConfig.Resolution.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().frame(width: 160)
                }
                SettingsRow(title: "Countdown", showsDivider: false) {
                    Picker("", selection: $recorder.countdown) {
                        Text("None").tag(0); Text("3 seconds").tag(3); Text("5 seconds").tag(5); Text("10 seconds").tag(10)
                    }
                    .labelsHidden().frame(width: 160)
                }
            }
            SettingsGroup(title: "Audio") {
                SettingsRow(title: "Record microphone") {
                    Toggle("", isOn: $recorder.captureMicrophone).toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(title: "Noise reduction", detail: "Reduces background noise and echo while recording.") {
                    Toggle("", isOn: $recorder.noiseReduction).toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(title: "Record system audio", showsDivider: false) {
                    Toggle("", isOn: $recorder.captureSystemAudio).toggleStyle(.switch).labelsHidden()
                }
            }
            SettingsGroup(title: "Camera") {
                SettingsRow(title: "Record camera", detail: "Adds a picture-in-picture you can style in the editor.", showsDivider: false) {
                    Toggle("", isOn: $recorder.captureCamera).toggleStyle(.switch).labelsHidden()
                }
            }
        }
    }
}

struct EditingSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var prefs = app.preferences
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Default style for new projects") {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(110), spacing: 12), count: 4), spacing: 12) {
                    ForEach(StylePreset.all) { preset in
                        Button { prefs.defaultPresetID = preset.id } label: {
                            VStack(spacing: 6) {
                                PresetPreview(preset: preset)
                                    .frame(width: 110, height: 68)
                                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(prefs.defaultPresetID == preset.id ? Theme.accent : Theme.border,
                                                                                           lineWidth: prefs.defaultPresetID == preset.id ? 2.5 : 1))
                                Text(preset.name).font(.system(size: 11.5)).foregroundStyle(Theme.text)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            SettingsGroup(title: "Motion") {
                SettingsRow(title: "Automatic zoom for new recordings", detail: "Suggests zooms where you clicked. You can edit or remove any of them.") {
                    Toggle("", isOn: $prefs.autoZoomByDefault).toggleStyle(.switch).labelsHidden()
                }
                SettingsRow(title: "Cursor smoothing", showsDivider: false) {
                    HStack {
                        Slider(value: $prefs.cursorSmoothingDefault, in: 0...1).frame(width: 160)
                        Text("\(Int(prefs.cursorSmoothingDefault * 100))%").font(.system(size: 12, design: .monospaced)).frame(width: 40)
                    }
                }
            }
        }
    }
}

struct PresetPreview: View {
    var preset: StylePreset

    var body: some View {
        ZStack {
            switch preset.background.kind {
            case .gradient:
                LinearGradient(colors: [Color(preset.background.gradientStart), Color(preset.background.gradientEnd)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            default:
                Color(preset.background.color)
            }
            RoundedRectangle(cornerRadius: preset.screen.cornerRadius > 0 ? 3 : 0)
                .fill(Color(hex: 0x2A2A30))
                .padding(preset.screen.padding * 110)
                .shadow(color: .black.opacity(preset.screen.shadowOpacity), radius: 3, y: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct ExportDefaultsSettings: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var prefs = app.preferences
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Format", footer: "Used for new projects. Each project remembers its own export settings.") {
                SettingsRow(title: "Container") {
                    Picker("", selection: $prefs.exportContainer) {
                        ForEach(ExportSettings.Container.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 160)
                }
                SettingsRow(title: "Codec", detail: "HEVC makes smaller files; H.264 plays everywhere.") {
                    Picker("", selection: $prefs.exportCodec) {
                        ForEach(ExportSettings.Codec.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 160)
                }
                SettingsRow(title: "Resolution") {
                    Picker("", selection: $prefs.exportResolution) {
                        ForEach(ExportSettings.Resolution.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 200)
                }
                SettingsRow(title: "Frame rate") {
                    Picker("", selection: $prefs.exportFrameRate) { Text("30 fps").tag(30); Text("60 fps").tag(60) }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 160)
                }
                SettingsRow(title: "Quality", showsDivider: false) {
                    Picker("", selection: $prefs.exportQuality) {
                        ForEach(ExportSettings.Quality.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(width: 240)
                }
            }
            SettingsGroup(title: "Destination") {
                SettingsRow(title: "Save exports to", detail: prefs.exportFolder ?? "Ask each time", showsDivider: false) {
                    HStack {
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let url = panel.url { prefs.exportFolder = url.path }
                        }
                        if prefs.exportFolder != nil { Button("Clear") { prefs.exportFolder = nil } }
                    }
                }
            }
        }
    }
}

struct StorageSettings: View {
    @Environment(AppState.self) private var app
    @State private var usage: (projects: Int64, temp: Int64, recovery: Int64, count: Int)?
    @State private var confirmEmptyRecovery = false
    @State private var movedNotice: String?

    var body: some View {
        let location = app.store.location
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Library") {
                SettingsRow(title: "Location", detail: location.root.path) {
                    HStack {
                        Button("Show in Finder") { NSWorkspace.shared.open(location.root) }
                        Button("Change…") { changeLocation() }
                    }
                }
                SettingsRow(title: "Projects", detail: usage.map { "\($0.count) projects" }, showsDivider: false) {
                    Text(usage.map { formatBytes($0.projects) } ?? "Calculating…").font(.system(size: 13, design: .monospaced))
                }
            }
            if let usage {
                StorageBar(projects: usage.projects, temp: usage.temp, recovery: usage.recovery)
            }
            SettingsGroup(title: "Clean up") {
                SettingsRow(title: "Temporary export files", detail: "Leftovers from cancelled or interrupted exports.") {
                    HStack {
                        Text(usage.map { formatBytes($0.temp) } ?? "—").font(.system(size: 12, design: .monospaced))
                        Button("Clear") {
                            try? FileManager.default.removeItem(at: location.exportTempDirectory)
                            Task { await measure() }
                        }
                        .disabled((usage?.temp ?? 0) == 0)
                    }
                }
                SettingsRow(title: "Unrecoverable recordings", detail: "Sessions Framelo could not rebuild after a crash, kept just in case.", showsDivider: false) {
                    HStack {
                        Text(usage.map { formatBytes($0.recovery) } ?? "—").font(.system(size: 12, design: .monospaced))
                        Button("Move to Trash") { confirmEmptyRecovery = true }.disabled((usage?.recovery ?? 0) == 0)
                    }
                }
            }
            if let movedNotice { Text(movedNotice).font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
        }
        .task { await measure() }
        .confirmationDialog("Move unrecoverable recordings to the Trash?", isPresented: $confirmEmptyRecovery) {
            Button("Move to Trash", role: .destructive) {
                let folder = location.root.appendingPathComponent("Recovery", isDirectory: true)
                try? FileManager.default.trashItem(at: folder, resultingItemURL: nil)
                Task { await measure() }
            }
        } message: {
            Text("They stay in the Trash until you empty it.")
        }
    }

    private func measure() async {
        let location = app.store.location
        let count = app.projects.count
        let result = await Task.detached(priority: .utility) { () -> (Int64, Int64, Int64) in
            (Self.size(location.projectsDirectory), Self.size(location.exportTempDirectory),
             Self.size(location.root.appendingPathComponent("Recovery", isDirectory: true)))
        }.value
        usage = (result.0, result.1, result.2, count)
    }

    nonisolated static func size(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    private func changeLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose where Framelo keeps new recordings and projects. Existing projects stay where they are."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.appendingPathComponent("Framelo", isDirectory: true).path, forKey: LibraryLocation.customPathKey)
        movedNotice = "The new location is used after Framelo restarts."
        let alert = NSAlert()
        alert.messageText = "Restart Framelo to use the new library location?"
        alert.informativeText = "Existing projects are not moved. You can move them yourself in Finder."
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn { app.recorder.relaunch() }
    }
}

struct StorageBar: View {
    var projects: Int64
    var temp: Int64
    var recovery: Int64

    var body: some View {
        let total = max(projects + temp + recovery, 1)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    segment(projects, total, geometry.size.width, Theme.accent)
                    segment(temp, total, geometry.size.width, Color(hex: 0xFF9F0A))
                    segment(recovery, total, geometry.size.width, Color(hex: 0x8E8E93))
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 10)
            .background(Capsule().fill(Theme.control))
            .clipShape(Capsule())
            HStack(spacing: 16) {
                legend("Projects", Theme.accent, projects)
                legend("Temporary", Color(hex: 0xFF9F0A), temp)
                legend("Recovery", Color(hex: 0x8E8E93), recovery)
            }
        }
    }

    private func segment(_ value: Int64, _ total: Int64, _ width: CGFloat, _ color: Color) -> some View {
        Rectangle().fill(color).frame(width: value > 0 ? max(3, width * CGFloat(value) / CGFloat(total)) : 0)
    }

    private func legend(_ title: String, _ color: Color, _ value: Int64) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(title) · \(formatBytes(value))").font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
        }
    }
}

struct ShortcutsSettings: View {
    private let groups: [(String, [(String, String)])] = [
        ("Recording (work in any app)", [("Start / stop recording", HotKeyCenter.Shortcut.toggleRecording.display),
                                         ("Pause / resume", HotKeyCenter.Shortcut.togglePause.display)]),
        ("Library", [("New recording", "⌘N"), ("Import video", "⌘I"), ("Settings", "⌘,")]),
        ("Editor", [("Play / pause", "Space"), ("Previous / next frame", "← →"), ("Split at playhead", "⌘B"),
                    ("Delete selection", "⌫"), ("Back to settings", "Esc"), ("Undo", "⌘Z"), ("Redo", "⇧⌘Z"),
                    ("Add zoom", "⌥Z"), ("Add keyframe", "⌥K"), ("Add text", "⌥T"), ("Export", "⌘E")]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(groups, id: \.0) { group in
                SettingsGroup(title: group.0) {
                    ForEach(Array(group.1.enumerated()), id: \.offset) { index, item in
                        SettingsRow(title: item.0, showsDivider: index < group.1.count - 1) {
                            Text(item.1).font(.system(size: 12, weight: .medium, design: .rounded))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.control))
                        }
                    }
                }
            }
        }
    }
}

struct PrivacySettings: View {
    @Environment(AppState.self) private var app
    @State private var confirmReset = false
    @State private var confirmTrashAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsGroup(title: "Your data",
                          footer: "Framelo makes no network connections. Recordings, projects, captions and settings never leave this Mac.") {
                SettingsRow(title: "Analytics and tracking", detail: "None. Framelo collects nothing.", showsDivider: false) {
                    Image(systemName: "checkmark.shield.fill").foregroundStyle(Theme.success).font(.system(size: 18))
                }
            }
            SettingsGroup(title: "Permissions") {
                let kinds: [PermissionKind] = [.screenRecording, .microphone, .camera, .speechRecognition]
                ForEach(Array(kinds.enumerated()), id: \.element) { index, kind in
                    let status = app.permissions[kind] ?? PermissionManager.status(kind)
                    SettingsRow(title: kind.displayName, detail: status == .granted ? "Allowed" : "Not allowed",
                                showsDivider: index < kinds.count - 1) {
                        HStack(spacing: 10) {
                            Circle().fill(status == .granted ? Theme.success : Theme.danger).frame(width: 8, height: 8)
                            Button(status == .granted ? "Manage…" : "Allow…") {
                                if status == .granted { NSWorkspace.shared.open(kind.settingsURL) } else { app.requestPermission(kind) }
                            }
                        }
                    }
                }
            }
            SettingsGroup(title: "Reset") {
                SettingsRow(title: "Reset all settings", detail: "Restores every preference to its default. Projects are not affected.") {
                    Button("Reset…") { confirmReset = true }
                }
                SettingsRow(title: "Move all projects to Trash", detail: "Recordings and projects go to the Trash, where you can still restore them.",
                            showsDivider: false) {
                    Button("Move to Trash…") { confirmTrashAll = true }.disabled(app.projects.isEmpty)
                }
            }
        }
        .onAppear { app.refreshPermissions() }
        .confirmationDialog("Reset all Framelo settings?", isPresented: $confirmReset) {
            Button("Reset Settings", role: .destructive) { app.preferences.resetAll(); app.applyHotKeyPreference() }
        } message: {
            Text("Your profile, appearance and default options go back to their original values.")
        }
        .confirmationDialog("Move all \(app.projects.count) projects to the Trash?", isPresented: $confirmTrashAll) {
            Button("Move to Trash", role: .destructive) { app.trashAllProjects() }
        } message: {
            Text("You can restore them from the Trash until you empty it.")
        }
    }
}

struct AboutSettings: View {
    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                LogoMark(size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Framelo").font(.system(size: 22, weight: .semibold))
                    Text("Version \(version) (\(build))").foregroundStyle(Theme.textSecondary)
                    Text("Record. Polish. Share.").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
            }
            SettingsGroup {
                SettingsRow(title: "Source code", detail: "github.com/Gokulakrishnxn/Framelo") {
                    Button("Open") { NSWorkspace.shared.open(URL(string: "https://github.com/Gokulakrishnxn/Framelo")!) }
                }
                SettingsRow(title: "Built with", detail: "SwiftUI, ScreenCaptureKit, AVFoundation, Metal", showsDivider: false) { EmptyView() }
            }
        }
    }
}
