import AppKit
import FrameloCore
import Observation
import SwiftUI

/// Accent colours offered in Settings › Appearance.
enum AccentChoice: String, CaseIterable, Identifiable {
    case violet, blue, pink, orange, green, graphite
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var hex: UInt32 {
        switch self {
        case .violet: 0x7C5CFF
        case .blue: 0x0A84FF
        case .pink: 0xFF375F
        case .orange: 0xFF9F0A
        case .green: 0x30D158
        case .graphite: 0x8E8E93
        }
    }
    static let key = "appearance.accent"
    static var current: AccentChoice { AccentChoice(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .violet }
}

enum ThemeChoice: String, CaseIterable, Identifiable {
    case system, dark, light
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}

/// Everything the user can customise in Settings. Each value is saved to `UserDefaults` as soon as it changes.
@MainActor @Observable
final class Preferences {
    private let defaults = UserDefaults.standard

    // Profile
    var displayName: String { didSet { defaults.set(displayName, forKey: "profile.name") } }
    var email: String { didSet { defaults.set(email, forKey: "profile.email") } }
    var avatarPath: String? { didSet { defaults.set(avatarPath, forKey: "profile.avatar") } }
    var embedAuthorInExports: Bool { didSet { defaults.set(embedAuthorInExports, forKey: "profile.embedAuthor") } }

    // Appearance
    var theme: ThemeChoice { didSet { defaults.set(theme.rawValue, forKey: "appearance.theme") } }
    var accent: AccentChoice { didSet { defaults.set(accent.rawValue, forKey: AccentChoice.key); revision += 1 } }
    var showSplash: Bool { didSet { defaults.set(showSplash, forKey: "appearance.splash") } }
    /// Bumped when a change needs the whole interface redrawn (accent colour).
    private(set) var revision = 0

    // Recording behaviour (capture settings themselves live in `RecordingController`)
    var openEditorAfterRecording: Bool { didSet { defaults.set(openEditorAfterRecording, forKey: "recording.openEditor") } }
    var globalShortcutsEnabled: Bool { didSet { defaults.set(globalShortcutsEnabled, forKey: "recording.shortcuts") } }

    // New project defaults
    var defaultPresetID: String { didSet { defaults.set(defaultPresetID, forKey: "editing.preset") } }
    var autoZoomByDefault: Bool { didSet { defaults.set(autoZoomByDefault, forKey: "editing.autoZoom") } }
    var cursorSmoothingDefault: Double { didSet { defaults.set(cursorSmoothingDefault, forKey: "editing.smoothing") } }

    // Export defaults
    var exportContainer: ExportSettings.Container { didSet { defaults.set(exportContainer.rawValue, forKey: "export.container") } }
    var exportCodec: ExportSettings.Codec { didSet { defaults.set(exportCodec.rawValue, forKey: "export.codec") } }
    var exportResolution: ExportSettings.Resolution { didSet { defaults.set(exportResolution.rawValue, forKey: "export.resolution") } }
    var exportFrameRate: Int { didSet { defaults.set(exportFrameRate, forKey: "export.fps") } }
    var exportQuality: ExportSettings.Quality { didSet { defaults.set(exportQuality.rawValue, forKey: "export.quality") } }
    var exportFolder: String? { didSet { defaults.set(exportFolder, forKey: "export.folder") } }

    init() {
        let d = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) == nil ? fallback : d.bool(forKey: key) }
        displayName = d.string(forKey: "profile.name") ?? NSFullUserName()
        email = d.string(forKey: "profile.email") ?? ""
        avatarPath = d.string(forKey: "profile.avatar")
        embedAuthorInExports = bool("profile.embedAuthor", true)
        theme = ThemeChoice(rawValue: d.string(forKey: "appearance.theme") ?? "") ?? .dark
        accent = AccentChoice.current
        showSplash = bool("appearance.splash", true)
        openEditorAfterRecording = bool("recording.openEditor", true)
        globalShortcutsEnabled = bool("recording.shortcuts", true)
        defaultPresetID = d.string(forKey: "editing.preset") ?? "aurora"
        autoZoomByDefault = bool("editing.autoZoom", true)
        cursorSmoothingDefault = d.object(forKey: "editing.smoothing") == nil ? CursorStyle().smoothing : d.double(forKey: "editing.smoothing")
        exportContainer = ExportSettings.Container(rawValue: d.string(forKey: "export.container") ?? "") ?? .mp4
        exportCodec = ExportSettings.Codec(rawValue: d.string(forKey: "export.codec") ?? "") ?? .h264
        exportResolution = ExportSettings.Resolution(rawValue: d.string(forKey: "export.resolution") ?? "") ?? .p1080
        exportFrameRate = d.object(forKey: "export.fps") == nil ? 60 : d.integer(forKey: "export.fps")
        exportQuality = ExportSettings.Quality(rawValue: d.string(forKey: "export.quality") ?? "") ?? .high
        exportFolder = d.string(forKey: "export.folder")
    }

    var avatar: NSImage? { avatarPath.flatMap { NSImage(contentsOfFile: $0) } }

    var initials: String {
        let parts = displayName.split(separator: " ").prefix(2)
        let letters = parts.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    var exportDefaults: ExportSettings {
        ExportSettings(container: exportContainer, codec: exportCodec, resolution: exportResolution,
                       frameRate: exportFrameRate, quality: exportQuality)
    }

    /// Author written into exported files, if the user allows it.
    var exportAuthor: String? {
        embedAuthorInExports && !displayName.trimmingCharacters(in: .whitespaces).isEmpty ? displayName : nil
    }

    /// Applies the user's defaults to a project that has just been created.
    func applyDefaults(to project: inout Project) {
        if let preset = StylePreset.all.first(where: { $0.id == defaultPresetID }) {
            project.settings.background = preset.background
            project.settings.screen = preset.screen
        }
        if project.sources.contains(where: { $0.kind == .recording }) {
            project.settings.motion.autoZoomEnabled = autoZoomByDefault
        }
        project.settings.cursor.smoothing = cursorSmoothingDefault
        project.settings.export = exportDefaults
    }

    /// Copies a chosen picture into Framelo's support folder and uses it as the profile photo.
    func setAvatar(from url: URL) throws {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Framelo", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("avatar-\(UUID().uuidString).\(url.pathExtension.isEmpty ? "png" : url.pathExtension)")
        try FileManager.default.copyItem(at: url, to: destination)
        if let old = avatarPath { try? FileManager.default.removeItem(atPath: old) }
        avatarPath = destination.path
    }

    func removeAvatar() {
        if let old = avatarPath { try? FileManager.default.removeItem(atPath: old) }
        avatarPath = nil
    }

    /// Restores every setting to its default (projects are not touched).
    func resetAll() {
        if let domain = Bundle.main.bundleIdentifier { defaults.removePersistentDomain(forName: domain) }
        removeAvatar()
        let fresh = Preferences()
        displayName = fresh.displayName; email = fresh.email; embedAuthorInExports = fresh.embedAuthorInExports
        theme = fresh.theme; accent = fresh.accent; showSplash = fresh.showSplash
        openEditorAfterRecording = fresh.openEditorAfterRecording; globalShortcutsEnabled = fresh.globalShortcutsEnabled
        defaultPresetID = fresh.defaultPresetID; autoZoomByDefault = fresh.autoZoomByDefault
        cursorSmoothingDefault = fresh.cursorSmoothingDefault
        exportContainer = fresh.exportContainer; exportCodec = fresh.exportCodec; exportResolution = fresh.exportResolution
        exportFrameRate = fresh.exportFrameRate; exportQuality = fresh.exportQuality; exportFolder = nil
    }
}

/// Round profile picture, or initials when there is no photo.
struct AvatarView: View {
    var preferences: Preferences
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            if let image = preferences.avatar {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(preferences.initials).font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
