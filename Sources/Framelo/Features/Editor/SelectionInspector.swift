import FrameloCore
import SwiftUI

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
        InspectorHeader(title: title, onBack: { model.selection = nil }, onDelete: { model.deleteSelection() })
    }

    private func clipSection(_ clip: VideoClip) -> some View {
        VStack(alignment: .leading, spacing: 14) {
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
        VStack(alignment: .leading, spacing: 14) {
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
        }
    }

    private func textSection(_ id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 14) {
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
        }
    }

    private func captionSection(_ id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            selectionHeader("Caption")
            TextField("Caption", text: model.captionBinding(id, \.text, fallback: ""), axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...3)
            timeRow(start: model.captionBinding(id, \.startTime, fallback: .zero), end: model.captionBinding(id, \.endTime, fallback: .zero))
            HStack {
                Text("Shift all").font(Theme.body).foregroundStyle(Theme.textSecondary)
                Button("−0.1s") { model.shiftCaptions(by: -0.1) }.buttonStyle(.compact)
                Button("+0.1s") { model.shiftCaptions(by: 0.1) }.buttonStyle(.compact)
            }
        }
    }

    private func audioSection(_ id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            selectionHeader("Audio Clip")
            SliderRow(title: "Volume", value: model.audioClipBinding(id, \.volume, fallback: 1), range: 0...2,
                      format: { "\(Int($0 * 100))%" }, onEditingEnded: model.endGesture)
            ToggleRow(title: "Mute", isOn: model.audioClipBinding(id, \.isMuted, fallback: false))
            SliderRow(title: "Fade in", value: model.audioClipBinding(id, \.fadeIn, fallback: 0), range: 0...5,
                      format: { String(format: "%.1fs", $0) }, onEditingEnded: model.endGesture)
            SliderRow(title: "Fade out", value: model.audioClipBinding(id, \.fadeOut, fallback: 0), range: 0...5,
                      format: { String(format: "%.1fs", $0) }, onEditingEnded: model.endGesture)
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
        VStack(alignment: .leading, spacing: 14) {
            if showsHeader {
                InspectorHeader(title: event?.isAutomatic == true ? "Automatic Zoom" : "Zoom",
                                onBack: { model.selection = nil },
                                onDelete: {
                                    model.selection = .zoom(id)
                                    model.deleteSelection()
                                })
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
        }
    }
}

/// Header for a selected item: Back on the left, the item's name, Delete on the right.
struct InspectorHeader: View {
    var title: String
    var onBack: () -> Void
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Back")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.raised))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to settings (Esc)")
                Spacer()
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 13))
                        .foregroundStyle(Theme.danger.opacity(0.9))
                        .frame(width: 30, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.raised))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete (⌫)")
            }
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
        }
        .padding(.bottom, 4)
    }
}
