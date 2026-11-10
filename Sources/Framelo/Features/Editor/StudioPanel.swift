import AppKit
import FrameloCore
import SwiftUI

/// Right side of the editor: a vertical icon rail and the settings panel for the chosen category.
struct StudioPanel: View {
    enum Section: String, CaseIterable, Identifiable {
        case background, cursor, camera, captions, text, audio, motion, shortcuts
        var id: String { rawValue }
        var title: String {
            switch self {
            case .background: "Background"
            case .cursor: "Cursor"
            case .camera: "Camera"
            case .captions: "Captions"
            case .text: "Text"
            case .audio: "Audio"
            case .motion: "Motion"
            case .shortcuts: "Shortcuts"
            }
        }
        var symbol: String {
            switch self {
            case .background: "rectangle.inset.filled"
            case .cursor: "cursorarrow"
            case .camera: "web.camera"
            case .captions: "captions.bubble"
            case .text: "text.alignleft"
            case .audio: "speaker.wave.2"
            case .motion: "point.topleft.down.to.point.bottomright.curvepath"
            case .shortcuts: "command"
            }
        }
    }

    var model: EditorModel
    @State private var section = Section.background

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 10) {
                ForEach(Section.allCases) { item in
                    RailButton(symbol: item.symbol, help: item.title, isSelected: section == item) { section = item }
                }
            }
            .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SelectionInspector(model: model)
                    switch section {
                    case .background: BackgroundSettings(model: model)
                    case .cursor: CursorSettings(model: model)
                    case .camera: CameraSettings(model: model)
                    case .captions: CaptionSettings(model: model)
                    case .text: TextSettings(model: model)
                    case .audio: AudioSettings(model: model)
                    case .motion: MotionSettingsPanel(model: model)
                    case .shortcuts: ShortcutList()
                    }
                }
                .padding(22)
            }
            .frame(width: 330)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border))
        }
        .padding(.vertical, 12)
        .padding(.trailing, 12)
        .onChange(of: model.selection) { _, selection in
            switch selection {
            case .zoom, .keyframe: section = .motion
            case .text: section = .text
            case .caption: section = .captions
            case .audioClip: section = .audio
            default: break
            }
        }
    }
}

struct RailButton: View {
    var symbol: String
    var help: String
    var isSelected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .trailing) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : Theme.textSecondary.opacity(hovering ? 1.4 : 1))
                    .frame(width: 38, height: 38)
                if isSelected {
                    Circle().fill(Theme.accent).frame(width: 5, height: 5).offset(x: 6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: Building blocks

/// Large section heading used inside the settings panel.
struct PanelHeading: View {
    var title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 14.5, weight: .medium)).foregroundStyle(Theme.text)
            if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Title, slider and a Reset button, as one block.
struct StudioSlider: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var defaultValue: Double
    var onEditingEnded: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeading(title: title)
            HStack(spacing: 14) {
                Slider(value: $value, in: range) { editing in if !editing { onEditingEnded() } }
                    .tint(Theme.accent)
                Button("Reset") { value = defaultValue }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(abs(value - defaultValue) > 1e-6 ? Theme.textSecondary : Theme.textTertiary)
                    .disabled(abs(value - defaultValue) <= 1e-6)
            }
        }
        .padding(.vertical, 14)
    }
}

/// Row of selectable chips (like a segmented control, styled for the panel).
struct ChipPicker<Value: Hashable>: View {
    var options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options.indices, id: \.self) { index in
                let (value, title) = options[index]
                Button {
                    selection = value
                } label: {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(selection == value ? Theme.text : Theme.textSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(selection == value ? Theme.control : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(selection == value ? Theme.borderStrong : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct PanelDivider: View {
    var body: some View { Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 6) }
}

/// Square thumbnail tile in a picker grid.
struct SwatchTile<Content: View>: View {
    var isSelected: Bool
    var action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        Button(action: action) {
            content
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? Color.white : Color.white.opacity(0.1), lineWidth: isSelected ? 2 : 1))
                .padding(2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Background

struct BackgroundSettings: View {
    var model: EditorModel
    @State private var library = WallpaperLibrary.shared

    private static let gradients: [(UInt32, UInt32, Double)] = [
        (0x4F46E5, 0xC026D3, 45), (0x0EA5E9, 0x1E3A8A, 60), (0xF97316, 0xDB2777, 30), (0x10B981, 0x064E3B, 70),
        (0x334155, 0x0F172A, 90), (0xFDE68A, 0xF472B6, 40), (0x22D3EE, 0x8B5CF6, 20), (0xFB7185, 0x7C3AED, 135),
        (0x84CC16, 0x0EA5E9, 45), (0x1F2937, 0x4B5563, 90), (0xF59E0B, 0xB91C1C, 60), (0xE0E7FF, 0x6366F1, 100),
    ]
    private static let colors: [UInt32] = [0x0B0B0C, 0x18181B, 0x3F3F46, 0xF4F4F5, 0xFFFFFF, 0x1E3A8A,
                                           0x4F46E5, 0x7C3AED, 0xDB2777, 0xDC2626, 0xF59E0B, 0x16A34A]

    private var background: FrameloCore.BackgroundStyle { model.project.settings.background }

    private var kindTab: Binding<FrameloCore.BackgroundStyle.Kind> {
        Binding(get: {
            switch background.kind {
            case .none: .solid
            default: background.kind
            }
        }, set: { kind in
            var updated = background
            updated.kind = kind
            if kind == .wallpaper, updated.imagePath == nil || background.kind != .wallpaper {
                updated.imagePath = library.wallpapers.first?.path ?? NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0)?.path }
            }
            if kind == .image, background.kind != .image { updated.imagePath = nil }
            model.perform(SetValueCommand("Background Type", \Project.settings.background, updated))
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PanelHeading(title: "Background")
                ScrollView(.horizontal, showsIndicators: false) {
                    ChipPicker(options: [(FrameloCore.BackgroundStyle.Kind.wallpaper, "Wallpaper"), (.gradient, "Gradient"),
                                         (.solid, "Color"), (.image, "Image")], selection: kindTab)
                }
            }
            .padding(.bottom, 18)

            switch kindTab.wrappedValue {
            case .wallpaper: wallpapers
            case .gradient: gradients
            case .image: image
            default: colors
            }

            if background.kind == .wallpaper || background.kind == .image {
                StudioSlider(title: "Background blur", value: model.binding(\.settings.background.blurAmount_, "Background Blur"),
                             range: 0...1, defaultValue: 0, onEditingEnded: model.endGesture)
            }
            PanelDivider()
            StudioSlider(title: "Padding", value: model.binding(\.settings.screen.padding, "Padding"),
                         range: 0...0.3, defaultValue: ScreenStyle().padding, onEditingEnded: model.endGesture)
            StudioSlider(title: "Screen rounded corners", value: model.binding(\.settings.screen.cornerRadius, "Corner Radius"),
                         range: 0...0.08, defaultValue: ScreenStyle().cornerRadius, onEditingEnded: model.endGesture)
            HStack {
                PanelHeading(title: "Inset", subtitle: "Add inset around the screen.")
                Toggle("", isOn: Binding(get: { model.project.settings.screen.insetAmount > 0 },
                                         set: { model.perform(SetValueCommand("Inset", \Project.settings.screen.inset, $0 ? 0.012 : 0)) }))
                    .toggleStyle(.switch).labelsHidden().tint(Theme.accent)
            }
            .padding(.vertical, 14)
            if model.project.settings.screen.insetAmount > 0 {
                StudioSlider(title: "Inset size", value: model.binding(\.settings.screen.insetAmount_, "Inset"),
                             range: 0.002...0.05, defaultValue: 0.012, onEditingEnded: model.endGesture)
            }
            PanelDivider()
            StudioSlider(title: "Shadow", value: model.binding(\.settings.screen.shadowOpacity, "Shadow"),
                         range: 0...1, defaultValue: ScreenStyle().shadowOpacity, onEditingEnded: model.endGesture)
            DisclosureGroup {
                StudioSlider(title: "Shadow size", value: model.binding(\.settings.screen.shadowRadius, "Shadow Size"),
                             range: 0...0.12, defaultValue: ScreenStyle().shadowRadius, onEditingEnded: model.endGesture)
            } label: {
                PanelHeading(title: "Advanced shadow settings")
            }
            .padding(.vertical, 8)
            PanelDivider()
            HStack {
                PanelHeading(title: "Window frame", subtitle: "Show the screen inside a window title bar.")
                Toggle("", isOn: Binding(get: { model.project.settings.screen.frame == .window },
                                         set: { model.perform(SetValueCommand("Window Frame", \Project.settings.screen.frame, $0 ? .window : .none)) }))
                    .toggleStyle(.switch).labelsHidden().tint(Theme.accent)
            }
            .padding(.vertical, 14)
        }
        .onAppear { library.load() }
    }

    private func setBackground(_ name: String, _ change: (inout FrameloCore.BackgroundStyle) -> Void) {
        var updated = background
        change(&updated)
        model.perform(SetValueCommand(name, \Project.settings.background, updated))
    }

    private var wallpapers: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                if let pick = library.wallpapers.randomElement() {
                    setBackground("Random Wallpaper") { $0.kind = .wallpaper; $0.imagePath = pick.path }
                }
            } label: {
                Label("Pick random wallpaper", systemImage: "wand.and.stars")
                    .font(.system(size: 13)).foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity).frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.borderStrong))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(library.wallpapers.isEmpty)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(48), spacing: 6), count: 5), alignment: .leading, spacing: 6) {
                SwatchTile(isSelected: false, action: {
                    if let path = NSScreen.main.flatMap({ NSWorkspace.shared.desktopImageURL(for: $0)?.path }) {
                        setBackground("Desktop Background") { $0.kind = .wallpaper; $0.imagePath = path }
                    }
                }) {
                    ZStack { Theme.control; Image(systemName: "menubar.dock.rectangle").foregroundStyle(Theme.textSecondary) }
                }
                .help("Use your current desktop picture")
                ForEach(library.wallpapers) { wallpaper in
                    SwatchTile(isSelected: background.imagePath == wallpaper.path,
                               action: { setBackground("Wallpaper") { $0.kind = .wallpaper; $0.imagePath = wallpaper.path } }) {
                        if let thumbnail = library.thumbnails[wallpaper.path] {
                            Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Theme.control
                        }
                    }
                    .help(wallpaper.name)
                }
            }
            if library.wallpapers.isEmpty {
                Text("No desktop pictures were found on this Mac.").font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.bottom, 8)
    }

    private var gradients: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(48), spacing: 6), count: 5), alignment: .leading, spacing: 6) {
            ForEach(Self.gradients.indices, id: \.self) { index in
                let (a, b, angle) = Self.gradients[index]
                let start = RGBAColor(hex: a), end = RGBAColor(hex: b)
                SwatchTile(isSelected: background.kind == .gradient && background.gradientStart == start && background.gradientEnd == end,
                           action: { setBackground("Gradient") { $0.kind = .gradient; $0.gradientStart = start; $0.gradientEnd = end; $0.gradientAngle = angle } }) {
                    LinearGradient(colors: [Color(hex: a), Color(hex: b)], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottomTrailing) { EmptyView() }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                ColorRow(title: "From", color: model.binding(\.settings.background.gradientStart, "Gradient"))
                ColorRow(title: "To", color: model.binding(\.settings.background.gradientEnd, "Gradient"))
                SliderRow(title: "Angle", value: model.binding(\.settings.background.gradientAngle, "Gradient Angle"), range: 0...360,
                          format: { "\(Int($0))°" }, onEditingEnded: model.endGesture)
            }
            .padding(.top, 12)
        }
    }

    private var colors: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(48), spacing: 6), count: 5), alignment: .leading, spacing: 6) {
                ForEach(Self.colors, id: \.self) { hex in
                    let color = RGBAColor(hex: hex)
                    SwatchTile(isSelected: background.kind == .solid && background.color == color,
                               action: { setBackground("Background Color") { $0.kind = .solid; $0.color = color } }) {
                        Color(hex: hex)
                    }
                }
            }
            ColorRow(title: "Custom", color: Binding(get: { background.color }, set: { color in
                setBackground("Background Color") { $0.kind = .solid; $0.color = color }
            }))
        }
        .padding(.bottom, 8)
    }

    private var image: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                model.chooseBackgroundImage()
            } label: {
                Label(background.imagePath == nil ? "Choose Image…" : "Choose Another Image…", systemImage: "photo")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondary)
            if let path = background.imagePath {
                Text(URL(fileURLWithPath: path).lastPathComponent).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
        .padding(.bottom, 8)
    }
}

/// Writable accessors so sliders can bind to the optional style values.
extension FrameloCore.BackgroundStyle {
    var blurAmount_: Double {
        get { blurAmount }
        set { blur = newValue }
    }
}

extension ScreenStyle {
    var insetAmount_: Double {
        get { insetAmount }
        set { inset = newValue }
    }
}

// MARK: Other sections

struct CursorSettings: View {
    var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                PanelHeading(title: "Show cursor")
                Toggle("", isOn: model.binding(\.settings.cursor.isVisible, "Cursor Visibility")).toggleStyle(.switch).labelsHidden().tint(Theme.accent)
            }
            .padding(.bottom, 8)
            StudioSlider(title: "Size", value: model.binding(\.settings.cursor.size, "Cursor Size"), range: 0.5...4,
                         defaultValue: CursorStyle().size, onEditingEnded: model.endGesture)
            StudioSlider(title: "Smooth movement", value: model.binding(\.settings.cursor.smoothing, "Cursor Smoothing"), range: 0...1,
                         defaultValue: CursorStyle().smoothing, onEditingEnded: model.endGesture)
            VStack(alignment: .leading, spacing: 12) {
                PanelHeading(title: "Click effect")
                ChipPicker(options: CursorStyle.ClickEffect.allCases.map { ($0, $0.displayName) },
                           selection: model.binding(\.settings.cursor.clickEffect, "Click Effect"))
                ColorRow(title: "Color", color: model.binding(\.settings.cursor.clickColor, "Click Color"))
            }
            .padding(.vertical, 14)
            StudioSlider(title: "Click press", value: model.binding(\.settings.cursor.pressScale, "Click Press"), range: 0.6...1,
                         defaultValue: CursorStyle().pressScale, onEditingEnded: model.endGesture)
            HStack {
                PanelHeading(title: "Hide when idle", subtitle: "Fade the cursor out when it stops moving.")
                Toggle("", isOn: model.binding(\.settings.cursor.hidesWhenIdle, "Hide Idle Cursor")).toggleStyle(.switch).labelsHidden().tint(Theme.accent)
            }
            .padding(.vertical, 14)
            if !model.project.sources.contains(where: { $0.cursorPath != nil }) {
                Text("This video has no recorded cursor data, so cursor effects and automatic zoom are unavailable.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

struct CameraSettings: View {
    var model: EditorModel

    var body: some View {
        if model.project.sources.contains(where: { $0.camera != nil }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    PanelHeading(title: "Show camera")
                    Toggle("", isOn: model.binding(\.settings.camera.isVisible, "Camera Visibility")).toggleStyle(.switch).labelsHidden().tint(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 12) {
                    PanelHeading(title: "Shape")
                    ChipPicker(options: CameraStyle.Shape.allCases.map { ($0, $0.displayName) },
                               selection: model.binding(\.settings.camera.shape, "Camera Shape"))
                    PanelHeading(title: "Position")
                    HStack(spacing: 6) {
                        ForEach([("arrow.up.left", 0.12, 0.18), ("arrow.up.right", 0.88, 0.18),
                                 ("arrow.down.left", 0.12, 0.82), ("arrow.down.right", 0.88, 0.82)], id: \.0) { item in
                            IconButton(symbol: item.0, help: "Move to corner", size: 34) {
                                var style = model.project.settings.camera
                                style.positionX = item.1
                                style.positionY = item.2
                                model.perform(SetValueCommand("Camera Corner", \Project.settings.camera, style))
                            }
                        }
                    }
                }
                .padding(.vertical, 14)
                StudioSlider(title: "Size", value: model.binding(\.settings.camera.size, "Camera Size"), range: 0.1...0.6,
                             defaultValue: CameraStyle().size, onEditingEnded: model.endGesture)
                StudioSlider(title: "Horizontal position", value: model.binding(\.settings.camera.positionX, "Camera Position"), range: 0...1,
                             defaultValue: CameraStyle().positionX, onEditingEnded: model.endGesture)
                StudioSlider(title: "Vertical position", value: model.binding(\.settings.camera.positionY, "Camera Position"), range: 0...1,
                             defaultValue: CameraStyle().positionY, onEditingEnded: model.endGesture)
                if model.project.settings.camera.shape == .roundedRect {
                    StudioSlider(title: "Rounded corners", value: model.binding(\.settings.camera.cornerRadius, "Camera Corners"), range: 0...0.5,
                                 defaultValue: CameraStyle().cornerRadius, onEditingEnded: model.endGesture)
                }
                StudioSlider(title: "Border", value: model.binding(\.settings.camera.borderWidth, "Camera Border"), range: 0...0.05,
                             defaultValue: CameraStyle().borderWidth, onEditingEnded: model.endGesture)
                ColorRow(title: "Border color", color: model.binding(\.settings.camera.borderColor, "Camera Border Color"))
                StudioSlider(title: "Shadow", value: model.binding(\.settings.camera.shadowOpacity, "Camera Shadow"), range: 0...1,
                             defaultValue: CameraStyle().shadowOpacity, onEditingEnded: model.endGesture)
                ColorRow(title: "Background", color: model.binding(\.settings.camera.backgroundColor, "Camera Background"))
                StudioSlider(title: "Size while zoomed", value: model.binding(\.settings.camera.zoomedScale, "Camera Zoom Shrink"), range: 0.4...1,
                             defaultValue: CameraStyle().zoomedScale, onEditingEnded: model.endGesture)
                HStack {
                    PanelHeading(title: "Mirror")
                    Toggle("", isOn: model.binding(\.settings.camera.isMirrored, "Mirror Camera")).toggleStyle(.switch).labelsHidden().tint(Theme.accent)
                }
                .padding(.vertical, 14)
            }
        } else {
            EmptyState(symbol: "web.camera", title: "No camera recorded",
                       message: "Choose a camera in the capture toolbar to add a picture-in-picture.")
        }
    }
}

struct CaptionSettings: View {
    var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                PanelHeading(title: "Captions", subtitle: "Transcribed on this Mac when on-device recognition is available.")
                Button {
                    model.generateCaptions()
                } label: {
                    HStack {
                        if model.isTranscribing { ProgressView().controlSize(.small) }
                        Text(model.isTranscribing ? "Transcribing…" : model.project.timeline.captions.isEmpty ? "Generate Captions" : "Regenerate Captions")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.primary)
                .disabled(model.isTranscribing)
            }
            .padding(.bottom, 10)
            HStack {
                PanelHeading(title: "Show captions")
                Toggle("", isOn: model.binding(\.settings.captions.isVisible, "Caption Visibility")).toggleStyle(.switch).labelsHidden().tint(Theme.accent)
            }
            .padding(.vertical, 10)
            StudioSlider(title: "Text size", value: model.binding(\.settings.captions.fontSize, "Caption Size"), range: 0.02...0.08,
                         defaultValue: CaptionStyle().fontSize, onEditingEnded: model.endGesture)
            StudioSlider(title: "Vertical position", value: model.binding(\.settings.captions.positionY, "Caption Position"), range: 0.1...0.95,
                         defaultValue: CaptionStyle().positionY, onEditingEnded: model.endGesture)
            ColorRow(title: "Text", color: model.binding(\.settings.captions.color, "Caption Color"))
            ColorRow(title: "Box", color: model.binding(\.settings.captions.backgroundColor, "Caption Background"))
            if !model.project.timeline.captions.isEmpty {
                PanelDivider()
                HStack {
                    PanelHeading(title: "Timing")
                    Button("−0.1s") { model.shiftCaptions(by: -0.1) }.buttonStyle(.compact)
                    Button("+0.1s") { model.shiftCaptions(by: 0.1) }.buttonStyle(.compact)
                }
                .padding(.vertical, 8)
                ForEach(model.project.timeline.captions) { caption in
                    ItemRow(title: caption.text, detail: formatTime(caption.startTime.seconds),
                            selected: model.selection == .caption(caption.id)) {
                        model.selection = .caption(caption.id)
                        model.seek(to: caption.startTime.seconds)
                    }
                }
            }
        }
    }
}

struct TextSettings: View {
    var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeading(title: "Text", subtitle: "Titles and callouts over your video.")
            Button {
                model.addText()
            } label: {
                Label("Add Text at Playhead", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondary)
            ForEach(model.project.timeline.textOverlays) { overlay in
                ItemRow(title: overlay.text, detail: formatTime(overlay.startTime.seconds), selected: model.selection == .text(overlay.id)) {
                    model.selection = .text(overlay.id)
                    model.seek(to: overlay.startTime.seconds)
                }
            }
        }
    }
}

struct AudioSettings: View {
    var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.project.timeline.tracks.filter { [.microphone, .systemAudio, .audio].contains($0.type) }) { track in
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        PanelHeading(title: track.name)
                        let muted = model.trackBinding(track.type, \.isMuted, fallback: false)
                        IconButton(symbol: muted.wrappedValue ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                   help: muted.wrappedValue ? "Unmute" : "Mute", isActive: muted.wrappedValue) { muted.wrappedValue.toggle() }
                    }
                    StudioSlider(title: "Volume", value: model.trackBinding(track.type, \.volume, fallback: 1), range: 0...2,
                                 defaultValue: 1, onEditingEnded: model.endGesture)
                }
                PanelDivider()
            }
            StudioSlider(title: "Fade in", value: model.binding(\.settings.audio.fadeIn, "Audio Fade In"), range: 0...5,
                         defaultValue: 0, onEditingEnded: model.endGesture)
            StudioSlider(title: "Fade out", value: model.binding(\.settings.audio.fadeOut, "Audio Fade Out"), range: 0...5,
                         defaultValue: 0, onEditingEnded: model.endGesture)
            Button {
                model.importAudio()
            } label: {
                Label("Add Music or Voice-over…", systemImage: "plus").frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondary)
            .padding(.top, 8)
        }
    }
}

struct MotionSettingsPanel: View {
    var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                PanelHeading(title: "Automatic zoom", subtitle: "Zoom in where you click.")
                Toggle("", isOn: model.binding(\.settings.motion.autoZoomEnabled, "Automatic Zoom")).toggleStyle(.switch).labelsHidden().tint(Theme.accent)
            }
            .padding(.bottom, 10)
            HStack(spacing: 8) {
                Button("Regenerate") { model.regenerateAutoZoom() }.buttonStyle(.secondary)
                Button("Motion Editor…") { model.showMotionEditor = true }.buttonStyle(.secondary)
            }
            if !model.project.timeline.suppressedAutoZoomRanges.isEmpty {
                Button("Restore removed suggestions") { model.clearSuppressedZooms() }.buttonStyle(.ghost).padding(.top, 6)
            }
            StudioSlider(title: "Zoom level", value: model.binding(\.settings.motion.defaultZoomScale, "Default Zoom"), range: 1.2...4,
                         defaultValue: MotionSettings().defaultZoomScale, onEditingEnded: model.endGesture)
            StudioSlider(title: "Zoom in speed", value: model.binding(\.settings.motion.zoomInDuration, "Zoom In Time"), range: 0.2...2,
                         defaultValue: MotionSettings().zoomInDuration, onEditingEnded: model.endGesture)
            StudioSlider(title: "Zoom out speed", value: model.binding(\.settings.motion.zoomOutDuration, "Zoom Out Time"), range: 0.2...2,
                         defaultValue: MotionSettings().zoomOutDuration, onEditingEnded: model.endGesture)
            VStack(alignment: .leading, spacing: 12) {
                PanelHeading(title: "Animation")
                Picker("", selection: model.binding(\.settings.motion.easing, "Easing")) {
                    ForEach(Easing.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
            }
            .padding(.vertical, 14)
            StudioSlider(title: "Motion blur", value: model.binding(\.settings.motion.motionBlur, "Motion Blur"), range: 0...1,
                         defaultValue: MotionSettings().motionBlur, onEditingEnded: model.endGesture)
        }
    }
}

struct ShortcutList: View {
    private let items: [(String, String)] = [
        ("Play / pause", "Space"), ("Previous / next frame", "← →"), ("Split at playhead", "⌘B"),
        ("Delete selection", "⌘⌫"), ("Add zoom", "⌥Z"), ("Add keyframe", "⌥K"), ("Add text", "⌥T"),
        ("Undo / redo", "⌘Z  ⇧⌘Z"), ("Export", "⌘E"), ("New recording", "⌘N"),
        ("Stop recording (anywhere)", HotKeyCenter.Shortcut.toggleRecording.display),
        ("Pause recording (anywhere)", HotKeyCenter.Shortcut.togglePause.display),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeading(title: "Keyboard shortcuts")
            ForEach(items, id: \.0) { item in
                HStack {
                    Text(item.0).font(Theme.body).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text(item.1).font(Theme.mono).foregroundStyle(Theme.text)
                }
            }
        }
    }
}

struct ItemRow: View {
    var title: String
    var detail: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(Theme.body).foregroundStyle(Theme.text).lineLimit(1)
                Spacer()
                Text(detail).font(Theme.mono).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.accent.opacity(0.2) : Theme.raised))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
