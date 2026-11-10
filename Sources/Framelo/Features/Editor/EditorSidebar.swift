import FrameloCore
import SwiftUI

/// Left sidebar: media, audio, text, backgrounds and effects.
struct EditorSidebar: View {
    enum Tab: String, CaseIterable, Identifiable {
        case media, audio, text, backgrounds, effects
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .media: "film.stack"
            case .audio: "waveform"
            case .text: "textformat"
            case .backgrounds: "photo.on.rectangle"
            case .effects: "sparkles"
            }
        }
    }

    var model: EditorModel
    @State private var tab = Tab.backgrounds

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: Theme.xs) {
                ForEach(Tab.allCases) { item in
                    IconButton(symbol: item.symbol, help: item.title, isActive: tab == item, size: 32) { tab = item }
                }
                Spacer()
            }
            .padding(.vertical, Theme.s)
            .frame(width: 44)
            Divider().overlay(Theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.s) {
                    Text(tab.title).font(Theme.heading).foregroundStyle(Theme.text).padding(.bottom, Theme.xs)
                    switch tab {
                    case .media: media
                    case .audio: audio
                    case .text: text
                    case .backgrounds: backgrounds
                    case .effects: effects
                    }
                }
                .padding(Theme.m)
            }
        }
        .background(Theme.panel)
    }

    // MARK: Media

    private var media: some View {
        VStack(alignment: .leading, spacing: Theme.s) {
            ForEach(model.project.sources) { source in
                Panel(padding: Theme.s) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: source.kind == .recording ? "record.circle" : source.kind == .importedAudio ? "music.note" : "film")
                                .foregroundStyle(Theme.accent)
                            Text(source.name).font(Theme.body).foregroundStyle(Theme.text).lineLimit(1)
                        }
                        Text(formatTime(source.duration)).font(Theme.mono).foregroundStyle(Theme.textSecondary)
                        if let screen = source.screen, screen.pixelWidth > 0 {
                            mediaLine("Video", "\(screen.pixelWidth)×\(screen.pixelHeight)")
                        }
                        if source.camera != nil { mediaLine("Camera", "recorded") }
                        if source.microphone != nil { mediaLine("Microphone", "recorded") }
                        if source.systemAudio != nil { mediaLine("System audio", "recorded") }
                        if let drift = source.microphone?.rateCorrection, drift != 1 {
                            mediaLine("Drift fix", String(format: "%.4f×", drift))
                        }
                    }
                }
            }
            Text("Originals are never modified. Edits are stored as instructions and applied when you export.")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary)
        }
    }

    private func mediaLine(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(Theme.caption).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).font(Theme.caption).foregroundStyle(Theme.text)
        }
    }

    // MARK: Audio

    private var audio: some View {
        VStack(alignment: .leading, spacing: Theme.m) {
            ForEach(model.project.timeline.tracks.filter { [.microphone, .systemAudio, .audio].contains($0.type) }) { track in
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.name).font(Theme.body).foregroundStyle(Theme.text)
                    ToggleRow(title: "Muted", isOn: model.trackBinding(track.type, \.isMuted, fallback: false))
                    SliderRow(title: "Volume", value: model.trackBinding(track.type, \.volume, fallback: 1), range: 0...2,
                              format: { "\(Int($0 * 100))%" }, onEditingEnded: model.endGesture)
                }
            }
            InspectorSection(title: "Whole video") {
                SliderRow(title: "Fade in", value: model.binding(\.settings.audio.fadeIn, "Audio Fade In"), range: 0...5,
                          format: { String(format: "%.1fs", $0) }, onEditingEnded: model.endGesture)
                SliderRow(title: "Fade out", value: model.binding(\.settings.audio.fadeOut, "Audio Fade Out"), range: 0...5,
                          format: { String(format: "%.1fs", $0) }, onEditingEnded: model.endGesture)
            }
            Button {
                model.importAudio()
            } label: {
                Label("Add Music or Voice-over…", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondary)
        }
    }

    // MARK: Text

    private var text: some View {
        VStack(alignment: .leading, spacing: Theme.s) {
            Button {
                model.addText()
            } label: {
                Label("Add Text at Playhead", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondary)
            ForEach(model.project.timeline.textOverlays) { overlay in
                listRow(overlay.text, detail: formatTime(overlay.startTime.seconds), selected: model.selection == .text(overlay.id)) {
                    model.selection = .text(overlay.id)
                    model.seek(to: overlay.startTime.seconds)
                }
            }
            InspectorSection(title: "Captions") {
                Button {
                    model.generateCaptions()
                } label: {
                    HStack {
                        if model.isTranscribing { ProgressView().controlSize(.small) }
                        Text(model.isTranscribing ? "Transcribing…" : model.project.timeline.captions.isEmpty ? "Generate Captions" : "Regenerate Captions")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.secondary)
                .disabled(model.isTranscribing)
                Text("Speech is transcribed on this Mac when on-device recognition is available.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                ForEach(model.project.timeline.captions) { caption in
                    listRow(caption.text, detail: formatTime(caption.startTime.seconds), selected: model.selection == .caption(caption.id)) {
                        model.selection = .caption(caption.id)
                        model.seek(to: caption.startTime.seconds)
                    }
                }
            }
        }
    }

    private func listRow(_ title: String, detail: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(Theme.body).foregroundStyle(Theme.text).lineLimit(1)
                Spacer()
                Text(detail).font(Theme.mono).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, Theme.s).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Theme.radiusS).fill(selected ? Theme.accent.opacity(0.18) : Theme.raised))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Backgrounds

    private var backgrounds: some View {
        VStack(alignment: .leading, spacing: Theme.m) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: Theme.s) {
                ForEach(StylePreset.all) { preset in
                    Button {
                        model.apply(preset)
                    } label: {
                        VStack(spacing: 4) {
                            PresetSwatch(preset: preset).frame(height: 54)
                            Text(preset.name).font(Theme.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Button {
                model.chooseBackgroundImage()
            } label: {
                Label("Custom Image…", systemImage: "photo").frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondary)
            Button {
                model.useDesktopWallpaper()
            } label: {
                Label("Use Desktop Picture", systemImage: "menubar.dock.rectangle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondary)
        }
    }

    // MARK: Effects

    private var effects: some View {
        VStack(alignment: .leading, spacing: Theme.s) {
            ToggleRow(title: "Automatic zoom", isOn: model.binding(\.settings.motion.autoZoomEnabled, "Automatic Zoom"))
            Button {
                model.regenerateAutoZoom()
            } label: {
                Label("Regenerate from Clicks", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondary)
            if !model.project.timeline.suppressedAutoZoomRanges.isEmpty {
                Button("Restore Removed Suggestions") { model.clearSuppressedZooms() }.buttonStyle(.ghost)
            }
            Button {
                model.showMotionEditor = true
            } label: {
                Label("Open Motion Editor", systemImage: "scope").frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondary)
            InspectorSection(title: "Zooms") {
                let active = Set(model.resolvedMotion.events.map(\.id))
                ForEach(model.project.timeline.zoomEvents) { event in
                    listRow((event.isAutomatic ? "Auto " : "") + String(format: "%.1f× zoom", event.scale) + (active.contains(event.id) ? "" : " (inactive)"),
                            detail: formatTime(event.startTime.seconds), selected: model.selection == .zoom(event.id)) {
                        model.selection = .zoom(event.id)
                        model.seek(to: event.startTime.seconds)
                    }
                }
                if model.project.timeline.zoomEvents.isEmpty {
                    Text("No zooms yet. Add one with ⌥Z or double-click the zoom track.").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }
}

struct PresetSwatch: View {
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
                .overlay(alignment: .top) {
                    if preset.screen.frame == .window {
                        Rectangle().fill(Color(hex: 0x3A3A40)).frame(height: 5)
                    }
                }
                .padding(preset.screen.padding * 90)
                .shadow(color: .black.opacity(preset.screen.shadowOpacity), radius: 3, y: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusS, style: .continuous).strokeBorder(Theme.border))
    }
}
