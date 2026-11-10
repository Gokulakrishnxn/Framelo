import FrameloCore
import SwiftUI

/// Right-hand inspector: the selected item first, then project-wide settings by category.
struct InspectorView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case video, motion, cursor, camera, background
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .video: "rectangle.on.rectangle"
            case .motion: "plus.magnifyingglass"
            case .cursor: "cursorarrow.rays"
            case .camera: "web.camera"
            case .background: "paintpalette"
            }
        }
    }

    var model: EditorModel
    @State private var tab = Tab.video

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Tab.allCases) { item in
                    IconButton(symbol: item.symbol, help: item.rawValue.capitalized, isActive: tab == item, size: 30) { tab = item }
                }
            }
            .padding(.vertical, 6)
            Divider().overlay(Theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.xs) {
                    SelectionInspector(model: model)
                    switch tab {
                    case .video: video
                    case .motion: motion
                    case .cursor: cursor
                    case .camera: camera
                    case .background: background
                    }
                }
                .padding(Theme.m)
            }
        }
        .background(Theme.panel)
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    private var video: some View {
        InspectorSection(title: "Screen") {
            SliderRow(title: "Padding", value: model.binding(\.settings.screen.padding, "Padding"), range: 0...0.3,
                      format: percent, onEditingEnded: model.endGesture)
            SliderRow(title: "Corners", value: model.binding(\.settings.screen.cornerRadius, "Corner Radius"), range: 0...0.08,
                      format: percent, onEditingEnded: model.endGesture)
            SliderRow(title: "Shadow", value: model.binding(\.settings.screen.shadowOpacity, "Shadow"), range: 0...1,
                      format: percent, onEditingEnded: model.endGesture)
            SliderRow(title: "Shadow size", value: model.binding(\.settings.screen.shadowRadius, "Shadow Size"), range: 0...0.12,
                      format: percent, onEditingEnded: model.endGesture)
            PickerRow(title: "Frame", selection: model.binding(\.settings.screen.frame, "Device Frame")) {
                ForEach(ScreenStyle.Frame.allCases) { Text($0.displayName).tag($0) }
            }
            PickerRow(title: "Aspect", selection: model.binding(\.settings.aspect.kind, "Aspect Ratio")) {
                ForEach(AspectRatio.Kind.allCases) { Text($0.displayName).tag($0) }
            }
            if model.project.settings.aspect.kind == .custom {
                SliderRow(title: "Width", value: model.binding(\.settings.aspect.customWidth, "Custom Aspect"), range: 1...32,
                          format: { String(format: "%.0f", $0) }, onEditingEnded: model.endGesture)
                SliderRow(title: "Height", value: model.binding(\.settings.aspect.customHeight, "Custom Aspect"), range: 1...32,
                          format: { String(format: "%.0f", $0) }, onEditingEnded: model.endGesture)
            }
        }
    }

    private var motion: some View {
        InspectorSection(title: "Motion") {
            ToggleRow(title: "Automatic zoom", isOn: model.binding(\.settings.motion.autoZoomEnabled, "Automatic Zoom"))
            SliderRow(title: "Zoom level", value: model.binding(\.settings.motion.defaultZoomScale, "Default Zoom"), range: 1.2...4,
                      format: { String(format: "%.1f×", $0) }, onEditingEnded: model.endGesture)
            SliderRow(title: "Zoom in", value: model.binding(\.settings.motion.zoomInDuration, "Zoom In Time"), range: 0.2...2,
                      format: { String(format: "%.1fs", $0) }, onEditingEnded: model.endGesture)
            SliderRow(title: "Zoom out", value: model.binding(\.settings.motion.zoomOutDuration, "Zoom Out Time"), range: 0.2...2,
                      format: { String(format: "%.1fs", $0) }, onEditingEnded: model.endGesture)
            PickerRow(title: "Easing", selection: model.binding(\.settings.motion.easing, "Easing")) {
                ForEach(Easing.allCases) { Text($0.displayName).tag($0) }
            }
            SliderRow(title: "Motion blur", value: model.binding(\.settings.motion.motionBlur, "Motion Blur"), range: 0...1,
                      format: percent, onEditingEnded: model.endGesture)
            Button("Apply to Automatic Zooms") { model.regenerateAutoZoom() }.buttonStyle(.compact)
        }
    }

    private var cursor: some View {
        InspectorSection(title: "Cursor") {
            ToggleRow(title: "Show cursor", isOn: model.binding(\.settings.cursor.isVisible, "Cursor Visibility"))
            SliderRow(title: "Size", value: model.binding(\.settings.cursor.size, "Cursor Size"), range: 0.5...4,
                      format: { String(format: "%.1f×", $0) }, onEditingEnded: model.endGesture)
            SliderRow(title: "Smoothing", value: model.binding(\.settings.cursor.smoothing, "Cursor Smoothing"), range: 0...1,
                      format: percent, onEditingEnded: model.endGesture)
            PickerRow(title: "Click effect", selection: model.binding(\.settings.cursor.clickEffect, "Click Effect")) {
                ForEach(CursorStyle.ClickEffect.allCases) { Text($0.displayName).tag($0) }
            }
            ColorRow(title: "Click color", color: model.binding(\.settings.cursor.clickColor, "Click Color"))
            SliderRow(title: "Press", value: model.binding(\.settings.cursor.pressScale, "Click Press"), range: 0.6...1,
                      format: percent, onEditingEnded: model.endGesture)
            ToggleRow(title: "Hide when idle", isOn: model.binding(\.settings.cursor.hidesWhenIdle, "Hide Idle Cursor"))
            if !model.project.sources.contains(where: { $0.cursorPath != nil }) {
                Text("This video has no recorded cursor data, so cursor effects and automatic zoom are unavailable.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    @ViewBuilder
    private var camera: some View {
        if model.project.sources.contains(where: { $0.camera != nil }) {
            InspectorSection(title: "Camera") {
                ToggleRow(title: "Show camera", isOn: model.binding(\.settings.camera.isVisible, "Camera Visibility"))
                PickerRow(title: "Shape", selection: model.binding(\.settings.camera.shape, "Camera Shape")) {
                    ForEach(CameraStyle.Shape.allCases) { Text($0.displayName).tag($0) }
                }
                SliderRow(title: "Size", value: model.binding(\.settings.camera.size, "Camera Size"), range: 0.1...0.6,
                          format: percent, onEditingEnded: model.endGesture)
                SliderRow(title: "Position X", value: model.binding(\.settings.camera.positionX, "Camera Position"), range: 0...1,
                          format: percent, onEditingEnded: model.endGesture)
                SliderRow(title: "Position Y", value: model.binding(\.settings.camera.positionY, "Camera Position"), range: 0...1,
                          format: percent, onEditingEnded: model.endGesture)
                HStack {
                    ForEach([("↖", 0.12, 0.18), ("↗", 0.88, 0.18), ("↙", 0.12, 0.82), ("↘", 0.88, 0.82)], id: \.0) { item in
                        Button(item.0) {
                            var style = model.project.settings.camera
                            style.positionX = item.1
                            style.positionY = item.2
                            model.perform(SetValueCommand("Camera Corner", \Project.settings.camera, style))
                        }
                        .buttonStyle(.compact)
                    }
                }
                if model.project.settings.camera.shape == .roundedRect {
                    SliderRow(title: "Corners", value: model.binding(\.settings.camera.cornerRadius, "Camera Corners"), range: 0...0.5,
                              format: percent, onEditingEnded: model.endGesture)
                }
                SliderRow(title: "Border", value: model.binding(\.settings.camera.borderWidth, "Camera Border"), range: 0...0.05,
                          format: percent, onEditingEnded: model.endGesture)
                ColorRow(title: "Border color", color: model.binding(\.settings.camera.borderColor, "Camera Border Color"))
                SliderRow(title: "Shadow", value: model.binding(\.settings.camera.shadowOpacity, "Camera Shadow"), range: 0...1,
                          format: percent, onEditingEnded: model.endGesture)
                ColorRow(title: "Background", color: model.binding(\.settings.camera.backgroundColor, "Camera Background"))
                ToggleRow(title: "Mirror", isOn: model.binding(\.settings.camera.isMirrored, "Mirror Camera"))
                SliderRow(title: "When zoomed", value: model.binding(\.settings.camera.zoomedScale, "Camera Zoom Shrink"), range: 0.4...1,
                          format: percent, onEditingEnded: model.endGesture)
            }
        } else {
            EmptyState(symbol: "web.camera", title: "No camera recorded",
                       message: "Turn on Camera in the recording settings to add a picture-in-picture.")
        }
    }

    private var background: some View {
        InspectorSection(title: "Background") {
            PickerRow(title: "Type", selection: model.binding(\.settings.background.kind, "Background Type")) {
                ForEach(BackgroundStyle.Kind.allCases) { Text($0.displayName).tag($0) }
            }
            switch model.project.settings.background.kind {
            case .solid, .none:
                ColorRow(title: "Color", color: model.binding(\.settings.background.color, "Background Color"))
            case .gradient:
                ColorRow(title: "From", color: model.binding(\.settings.background.gradientStart, "Gradient"))
                ColorRow(title: "To", color: model.binding(\.settings.background.gradientEnd, "Gradient"))
                SliderRow(title: "Angle", value: model.binding(\.settings.background.gradientAngle, "Gradient Angle"), range: 0...360,
                          format: { "\(Int($0))°" }, onEditingEnded: model.endGesture)
            case .image, .wallpaper:
                Text(model.project.settings.background.imagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No image chosen")
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                HStack {
                    Button("Choose Image…") { model.chooseBackgroundImage() }.buttonStyle(.compact)
                    Button("Desktop Picture") { model.useDesktopWallpaper() }.buttonStyle(.compact)
                }
            }
            InspectorSection(title: "Captions") {
                ToggleRow(title: "Show captions", isOn: model.binding(\.settings.captions.isVisible, "Caption Visibility"))
                SliderRow(title: "Size", value: model.binding(\.settings.captions.fontSize, "Caption Size"), range: 0.02...0.08,
                          format: percent, onEditingEnded: model.endGesture)
                SliderRow(title: "Position", value: model.binding(\.settings.captions.positionY, "Caption Position"), range: 0.1...0.95,
                          format: percent, onEditingEnded: model.endGesture)
                ColorRow(title: "Text", color: model.binding(\.settings.captions.color, "Caption Color"))
                ColorRow(title: "Box", color: model.binding(\.settings.captions.backgroundColor, "Caption Background"))
            }
        }
    }
}

/// Properties of whatever is selected on the timeline.
struct SelectionInspector: View {
    var model: EditorModel

    var body: some View {
        switch model.selection {
        case .clip(let id):
            if let clip = model.clip(id) { clipSection(clip) }
        case .zoom(let id):
            if model.zoom(id) != nil { ZoomInspector(model: model, id: id) }
        case .keyframe(let id):
            if model.keyframe(id) != nil { keyframeSection(id) }
        case .text(let id):
            if model.text(id) != nil { textSection(id) }
        case .caption(let id):
            captionSection(id)
        case .audioClip(let id):
            audioSection(id)
        case nil:
            EmptyView()
        }
    }

    private func selectionHeader(_ title: String) -> some View {
        HStack {
            Text(title).font(Theme.heading).foregroundStyle(Theme.text)
            Spacer()
            IconButton(symbol: "trash", help: "Delete") { model.deleteSelection() }
        }
    }

    private func clipSection(_ clip: VideoClip) -> some View {
        VStack(alignment: .leading, spacing: Theme.s) {
            selectionHeader("Clip")
            Text("\(formatTime(clip.sourceStart.seconds, showFraction: true)) – \(formatTime(clip.sourceEnd.seconds, showFraction: true)) of source")
                .font(Theme.mono).foregroundStyle(Theme.textSecondary)
            PickerRow(title: "Speed", selection: Binding(get: { clip.playbackSpeed }, set: { model.setSpeed(clip.id, $0) })) {
                ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4, 8], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
            }
            if let volume = model.clipBinding(clip.id, \.volume, "Clip Volume") {
                SliderRow(title: "Volume", value: volume, range: 0...2, format: { "\(Int($0 * 100))%" }, onEditingEnded: model.endGesture)
            }
            if let muted = model.clipBinding(clip.id, \.isMuted, "Mute Clip") {
                ToggleRow(title: "Mute", isOn: muted)
            }
            if let transitionIn = model.clipBinding(clip.id, \.transitionIn, "Transition In") {
                transitionPicker("Transition in", transitionIn)
            }
            if let transitionOut = model.clipBinding(clip.id, \.transitionOut, "Transition Out") {
                transitionPicker("Transition out", transitionOut)
            }
            HStack {
                Button("Move Earlier") { model.moveClip(clip.id, by: -1) }.buttonStyle(.compact)
                Button("Move Later") { model.moveClip(clip.id, by: 1) }.buttonStyle(.compact)
            }
            Divider().overlay(Theme.border).padding(.vertical, Theme.xs)
        }
    }

    private func transitionPicker(_ title: String, _ binding: Binding<ClipTransition?>) -> some View {
        PickerRow(title: title, selection: Binding(get: { binding.wrappedValue?.kind }, set: { kind in
            binding.wrappedValue = kind.map { ClipTransition(kind: $0, duration: 0.4) }
        })) {
            Text("None").tag(ClipTransition.Kind?.none)
            ForEach(ClipTransition.Kind.allCases) { Text($0.displayName).tag(ClipTransition.Kind?.some($0)) }
        }
    }

    private func keyframeSection(_ id: UUID) -> some View {
        VStack(alignment: .leading, spacing: Theme.s) {
            selectionHeader("Camera Keyframe")
            SliderRow(title: "Scale", value: model.keyframeBinding(id, \.scale, fallback: 1), range: 1...5,
                      format: { String(format: "%.2f×", $0) }, onEditingEnded: model.endGesture)
            SliderRow(title: "Position X", value: model.keyframeBinding(id, \.positionX, fallback: 0.5), range: 0...1,
                      format: { "\(Int($0 * 100))%" }, onEditingEnded: model.endGesture)
            SliderRow(title: "Position Y", value: model.keyframeBinding(id, \.positionY, fallback: 0.5), range: 0...1,
                      format: { "\(Int($0 * 100))%" }, onEditingEnded: model.endGesture)
            PickerRow(title: "Easing", selection: model.keyframeBinding(id, \.easing, fallback: .easeInOut)) {
                ForEach(Easing.allCases) { Text($0.displayName).tag($0) }
            }
            Text("Keyframes take over the camera between the first and last keyframe.").font(Theme.caption).foregroundStyle(Theme.textTertiary)
            Divider().overlay(Theme.border).padding(.vertical, Theme.xs)
        }
    }

    private func textSection(_ id: UUID) -> some View {
        VStack(alignment: .leading, spacing: Theme.s) {
            selectionHeader("Text")
            TextField("Text", text: model.textBinding(id, \.text, fallback: ""), axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...4)
            SliderRow(title: "Size", value: model.textBinding(id, \.fontSize, fallback: 0.06), range: 0.02...0.2,
                      format: { "\(Int($0 * 100))%" }, onEditingEnded: model.endGesture)
            PickerRow(title: "Weight", selection: model.textBinding(id, \.weight, fallback: .semibold)) {
                ForEach(TextOverlay.Weight.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            SliderRow(title: "Position X", value: model.textBinding(id, \.positionX, fallback: 0.5), range: 0...1,
                      format: { "\(Int($0 * 100))%" }, onEditingEnded: model.endGesture)
            SliderRow(title: "Position Y", value: model.textBinding(id, \.positionY, fallback: 0.15), range: 0...1,
                      format: { "\(Int($0 * 100))%" }, onEditingEnded: model.endGesture)
            ColorRow(title: "Color", color: model.textBinding(id, \.color, fallback: .white))
            ColorRow(title: "Background", color: model.textBinding(id, \.backgroundColor, fallback: .clear))
            timeRow(start: model.textBinding(id, \.startTime, fallback: .zero), end: model.textBinding(id, \.endTime, fallback: .zero))
            Divider().overlay(Theme.border).padding(.vertical, Theme.xs)
        }
    }

    private func captionSection(_ id: UUID) -> some View {
        VStack(alignment: .leading, spacing: Theme.s) {
            selectionHeader("Caption")
            TextField("Caption", text: model.captionBinding(id, \.text, fallback: ""), axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3)
            timeRow(start: model.captionBinding(id, \.startTime, fallback: .zero), end: model.captionBinding(id, \.endTime, fallback: .zero))
            HStack {
                Text("Shift all").font(Theme.body).foregroundStyle(Theme.textSecondary)
                Button("−0.1s") { model.shiftCaptions(by: -0.1) }.buttonStyle(.compact)
                Button("+0.1s") { model.shiftCaptions(by: 0.1) }.buttonStyle(.compact)
            }
            Divider().overlay(Theme.border).padding(.vertical, Theme.xs)
        }
    }

    private func audioSection(_ id: UUID) -> some View {
        VStack(alignment: .leading, spacing: Theme.s) {
            selectionHeader("Audio Clip")
            SliderRow(title: "Volume", value: model.audioClipBinding(id, \.volume, fallback: 1), range: 0...2,
                      format: { "\(Int($0 * 100))%" }, onEditingEnded: model.endGesture)
            ToggleRow(title: "Mute", isOn: model.audioClipBinding(id, \.isMuted, fallback: false))
            SliderRow(title: "Fade in", value: model.audioClipBinding(id, \.fadeIn, fallback: 0), range: 0...5,
                      format: { String(format: "%.1fs", $0) }, onEditingEnded: model.endGesture)
            SliderRow(title: "Fade out", value: model.audioClipBinding(id, \.fadeOut, fallback: 0), range: 0...5,
                      format: { String(format: "%.1fs", $0) }, onEditingEnded: model.endGesture)
            Divider().overlay(Theme.border).padding(.vertical, Theme.xs)
        }
    }

    /// Start and end time steppers in 0.1 s increments.
    private func timeRow(start: Binding<MediaTime>, end: Binding<MediaTime>) -> some View {
        let step = MediaTime(seconds: 0.1)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Start").font(Theme.body).foregroundStyle(Theme.textSecondary).frame(width: 84, alignment: .leading)
                Text(formatTime(start.wrappedValue.seconds, showFraction: true)).font(Theme.mono).foregroundStyle(Theme.text)
                Spacer()
                Stepper("", onIncrement: { if start.wrappedValue + step < end.wrappedValue { start.wrappedValue += step } },
                        onDecrement: { start.wrappedValue = max(.zero, start.wrappedValue - step) }).labelsHidden()
            }
            HStack {
                Text("End").font(Theme.body).foregroundStyle(Theme.textSecondary).frame(width: 84, alignment: .leading)
                Text(formatTime(end.wrappedValue.seconds, showFraction: true)).font(Theme.mono).foregroundStyle(Theme.text)
                Spacer()
                Stepper("", onIncrement: { end.wrappedValue += step },
                        onDecrement: { if end.wrappedValue - step > start.wrappedValue { end.wrappedValue -= step } }).labelsHidden()
            }
        }
    }
}

/// Editor for one zoom event; shared by the inspector and the motion editor.
struct ZoomInspector: View {
    var model: EditorModel
    var id: UUID
    var showsHeader = true

    var body: some View {
        let event = model.zoom(id)
        VStack(alignment: .leading, spacing: Theme.s) {
            if showsHeader {
                HStack {
                    Text(event?.isAutomatic == true ? "Automatic Zoom" : "Zoom").font(Theme.heading).foregroundStyle(Theme.text)
                    Spacer()
                    IconButton(symbol: "trash", help: "Delete zoom") {
                        model.selection = .zoom(id)
                        model.deleteSelection()
                    }
                }
            }
            if event?.isAutomatic == true {
                Text("Suggested from your clicks. Any change makes it a manual zoom that regeneration keeps.")
                    .font(Theme.caption).foregroundStyle(Theme.textTertiary)
            }
            SliderRow(title: "Scale", value: model.zoomBinding(id, \.scale, fallback: 2), range: 1.1...5,
                      format: { String(format: "%.2f×", $0) }, onEditingEnded: model.endGesture)
            SliderRow(title: "Target X", value: model.zoomBinding(id, \.targetX, fallback: 0.5), range: 0...1,
                      format: { "\(Int($0 * 100))%" }, onEditingEnded: model.endGesture)
            SliderRow(title: "Target Y", value: model.zoomBinding(id, \.targetY, fallback: 0.5), range: 0...1,
                      format: { "\(Int($0 * 100))%" }, onEditingEnded: model.endGesture)
            ToggleRow(title: "Follow cursor", isOn: model.zoomBinding(id, \.followsCursor, fallback: true))
            SliderRow(title: "Zoom in", value: model.zoomBinding(id, \.transitionIn, fallback: 0.7), range: 0.15...3,
                      format: { String(format: "%.1fs", $0) }, onEditingEnded: model.endGesture)
            SliderRow(title: "Zoom out", value: model.zoomBinding(id, \.transitionOut, fallback: 0.8), range: 0.15...3,
                      format: { String(format: "%.1fs", $0) }, onEditingEnded: model.endGesture)
            PickerRow(title: "Easing", selection: model.zoomBinding(id, \.easing, fallback: .easeInOut)) {
                ForEach(Easing.allCases) { Text($0.displayName).tag($0) }
            }
            if let event {
                Text("\(formatTime(event.startTime.seconds, showFraction: true)) – \(formatTime(event.endTime.seconds, showFraction: true))")
                    .font(Theme.mono).foregroundStyle(Theme.textSecondary)
            }
            Divider().overlay(Theme.border).padding(.vertical, Theme.xs)
        }
    }
}
