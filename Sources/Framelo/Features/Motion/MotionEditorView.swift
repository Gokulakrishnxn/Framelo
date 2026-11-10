import FrameloCore
import SwiftUI

/// Motion editor: every zoom event, the camera path preview, cursor effects, motion blur and keyframes.
struct MotionEditorView: View {
    var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.l) {
            HStack {
                Text("Motion").font(Theme.title).foregroundStyle(Theme.text)
                Spacer()
                Button {
                    model.regenerateAutoZoom()
                } label: {
                    Label("Regenerate Automatic Zooms", systemImage: "wand.and.stars")
                }
                .buttonStyle(.secondary)
                Button("Done") { dismiss() }.buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }

            CameraPathGraph(model: model).frame(height: 90)

            HStack(alignment: .top, spacing: Theme.l) {
                VStack(alignment: .leading, spacing: Theme.s) {
                    Text("ZOOM EVENTS").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    let active = Set(model.resolvedMotion.events.map(\.id))
                    List(selection: $selected) {
                        ForEach(model.project.timeline.zoomEvents) { event in
                            HStack {
                                Image(systemName: event.isAutomatic ? "wand.and.stars" : "plus.magnifyingglass")
                                    .foregroundStyle(event.isAutomatic ? Theme.autoZoomTint : Theme.zoomTint)
                                VStack(alignment: .leading) {
                                    Text(String(format: "%.1f× · %@", event.scale, event.easing.displayName)).font(Theme.body)
                                    Text("\(formatTime(event.startTime.seconds, showFraction: true)) – \(formatTime(event.endTime.seconds, showFraction: true))")
                                        .font(Theme.mono).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                                if !active.contains(event.id) {
                                    Text("Overridden").font(Theme.caption).foregroundStyle(Theme.textTertiary)
                                }
                            }
                            .tag(event.id)
                        }
                    }
                    .listStyle(.bordered)
                    .frame(minHeight: 220)
                    HStack {
                        Button("Add at Playhead") { model.addZoom() }.buttonStyle(.compact)
                        Button("Delete") {
                            if let selected {
                                model.selection = .zoom(selected)
                                model.deleteSelection()
                                self.selected = nil
                            }
                        }
                        .buttonStyle(.compact)
                        .disabled(selected == nil)
                    }
                }
                .frame(width: 300)

                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.s) {
                        if let selected, model.zoom(selected) != nil {
                            ZoomInspector(model: model, id: selected, showsHeader: false)
                            Button("Preview This Zoom") {
                                if let event = model.zoom(selected) {
                                    model.seek(to: event.startTime.seconds)
                                    model.togglePlay()
                                }
                            }
                            .buttonStyle(.compact)
                        } else {
                            Text("Select a zoom to edit its scale, position, timing and easing.")
                                .font(Theme.body).foregroundStyle(Theme.textSecondary)
                        }
                        InspectorSection(title: "Defaults & effects") {
                            SliderRow(title: "Motion blur", value: model.binding(\.settings.motion.motionBlur, "Motion Blur"), range: 0...1,
                                      format: { "\(Int($0 * 100))%" }, onEditingEnded: model.endGesture)
                            SliderRow(title: "Cursor smooth", value: model.binding(\.settings.cursor.smoothing, "Cursor Smoothing"), range: 0...1,
                                      format: { "\(Int($0 * 100))%" }, onEditingEnded: model.endGesture)
                            PickerRow(title: "Click effect", selection: model.binding(\.settings.cursor.clickEffect, "Click Effect")) {
                                ForEach(CursorStyle.ClickEffect.allCases) { Text($0.displayName).tag($0) }
                            }
                            SliderRow(title: "Cursor size", value: model.binding(\.settings.cursor.size, "Cursor Size"), range: 0.5...4,
                                      format: { String(format: "%.1f×", $0) }, onEditingEnded: model.endGesture)
                        }
                        InspectorSection(title: "Keyframes") {
                            ForEach(model.project.timeline.keyframes) { keyframe in
                                HStack {
                                    Image(systemName: "diamond.fill").foregroundStyle(Theme.zoomTint)
                                    Text(String(format: "%.2f× at %@", keyframe.scale, formatTime(keyframe.timestamp.seconds, showFraction: true)))
                                        .font(Theme.body)
                                    Spacer()
                                    Button("Edit") {
                                        model.selection = .keyframe(keyframe.id)
                                        model.seek(to: keyframe.timestamp.seconds)
                                        dismiss()
                                    }
                                    .buttonStyle(.compact)
                                }
                            }
                            Button("Add Keyframe at Playhead") { model.addKeyframe() }.buttonStyle(.compact)
                        }
                    }
                }
            }
        }
        .padding(Theme.xl)
        .frame(width: 820, height: 620)
        .background(Theme.panel)
        .preferredColorScheme(.dark)
        .onAppear {
            if case .zoom(let id) = model.selection { selected = id }
        }
    }
}

/// Plot of the resolved camera zoom over the whole timeline.
struct CameraPathGraph: View {
    var model: EditorModel

    var body: some View {
        let path = model.resolvedMotion.path
        let duration = max(model.duration, 0.1)
        Canvas { context, size in
            var line = Path()
            let samples = Int(size.width)
            for i in 0...samples {
                let t = duration * Double(i) / Double(samples)
                let scale = path.state(at: t).scale
                let y = size.height - CGFloat((scale - 1) / 4) * (size.height - 8) - 4
                if i == 0 { line.move(to: CGPoint(x: 0, y: y)) } else { line.addLine(to: CGPoint(x: CGFloat(i), y: y)) }
            }
            context.stroke(line, with: .color(Theme.zoomTint), lineWidth: 1.5)
            let x = CGFloat(model.currentTime / duration) * size.width
            context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.white))
        }
        .background(RoundedRectangle(cornerRadius: Theme.radiusM).fill(Theme.raised))
        .overlay(alignment: .topLeading) {
            Text("Camera zoom over time").font(Theme.caption).foregroundStyle(Theme.textTertiary).padding(Theme.s)
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusM).strokeBorder(Theme.border))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            model.seek(to: duration * Double(value.location.x / 760))
        })
    }
}
