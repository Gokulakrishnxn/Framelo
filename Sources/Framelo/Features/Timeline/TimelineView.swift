import FrameloCore
import SwiftUI

/// Multi-track timeline: ruler, screen clips, zoom lane, text/keyframe markers and audio.
struct TimelineView: View {
    @Bindable var model: EditorModel

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width - 48, CGFloat(model.duration * model.pixelsPerSecond) + 40)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 8) {
                        RulerView(model: model).frame(height: 34)
                        ClipRow(model: model).frame(height: 64)
                        ZoomRow(model: model).frame(height: 62)
                        if hasMarkers { MarkerRow(model: model).frame(height: 30) }
                        ForEach(audioKinds, id: \.self) { kind in
                            AudioRow(model: model, kind: kind).frame(height: 30)
                        }
                    }
                    PlayheadView(model: model)
                }
                .frame(width: width, alignment: .topLeading)
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.visible)
        }
        .background(Theme.background)
    }

    private var hasMarkers: Bool {
        let timeline = model.project.timeline
        return !timeline.textOverlays.isEmpty || !timeline.captions.isEmpty || !timeline.keyframes.isEmpty
    }

    private var audioKinds: [TimelineTrack.Kind] {
        model.project.timeline.tracks.map(\.type).filter { [.microphone, .systemAudio, .audio].contains($0) }
    }
}

/// Converts between seconds and x positions in the timeline content.
private extension EditorModel {
    func x(_ seconds: Double) -> CGFloat { CGFloat(seconds * pixelsPerSecond) }
    func seconds(_ x: CGFloat) -> Double { Double(x) / pixelsPerSecond }
}

struct RulerView: View {
    var model: EditorModel

    var body: some View {
        Canvas { context, size in
            let pps = model.pixelsPerSecond
            let candidates: [Double] = [0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
            let step = candidates.first { $0 * pps >= 120 } ?? 600
            var t = 0.0
            while CGFloat(t * pps) <= size.width {
                let x = CGFloat(t * pps)
                if t > 0 {
                    let label = step < 1 ? String(format: "%.2f", t) : formatTime(t).replacingOccurrences(of: "00:", with: "0:")
                    context.draw(Text(label).font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.textSecondary),
                                 at: CGPoint(x: x, y: 10))
                }
                for quarter in 0..<4 {
                    let dot = x + CGFloat(Double(quarter) * step / 4 * pps)
                    context.fill(Path(ellipseIn: CGRect(x: dot - 1.5, y: 25, width: 3, height: 3)),
                                 with: .color(Theme.textTertiary))
                }
                t += step
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { model.seek(to: model.seconds($0.location.x)) })
    }
}

struct PlayheadView: View {
    var model: EditorModel

    var body: some View {
        let x = CGFloat(model.currentTime * model.pixelsPerSecond)
        ZStack(alignment: .top) {
            Rectangle().fill(Theme.accent).frame(width: 2)
            Circle().fill(Theme.accent).frame(width: 13, height: 13).offset(x: 0, y: -2)
        }
        .frame(maxHeight: .infinity)
        .offset(x: x - 1)
        .allowsHitTesting(false)
    }
}

// MARK: Clips

struct ClipRow: View {
    var model: EditorModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
                .onTapGesture { location in
                    model.selection = nil
                    model.seek(to: Double(location.x) / model.pixelsPerSecond)
                }
            ForEach(model.project.timeline.videoClips) { clip in
                ClipBlock(model: model, clip: clip)
            }
        }
    }
}

struct ClipBlock: View {
    var model: EditorModel
    var clip: VideoClip
    @State private var trimOffset: (head: CGFloat, tail: CGFloat) = (0, 0)

    private var selected: Bool { model.selection == .clip(clip.id) }

    var body: some View {
        let pps = model.pixelsPerSecond
        let x = CGFloat(clip.timelinePosition.seconds * pps) + trimOffset.head
        let width = max(CGFloat(clip.timelineDuration.seconds * pps) - trimOffset.head + trimOffset.tail, 6)
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xD99A1E), Color(hex: 0xC2850F)], startPoint: .top, endPoint: .bottom))
            if width > 70 {
                VStack(spacing: 2) {
                    Text("Clip").font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.55))
                    HStack(spacing: 6) {
                        Text(durationLabel).font(.system(size: 13.5, weight: .medium))
                        HStack(spacing: 2) {
                            Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 11))
                            Text(String(format: "%g×", clip.playbackSpeed)).font(.system(size: 13.5, weight: .medium))
                        }
                        if clip.isMuted { Image(systemName: "speaker.slash.fill").font(.system(size: 11)) }
                    }
                    .foregroundStyle(.white)
                }
            }
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.white : Color.white.opacity(0.12), lineWidth: selected ? 2 : 1)
            HStack {
                handle(isHead: true)
                Spacer(minLength: 0)
                handle(isHead: false)
            }
        }
        .frame(width: width, height: 64)
        .offset(x: x)
        .onTapGesture { model.selection = .clip(clip.id) }
        .contextMenu {
            Button("Split at Playhead") { model.splitAtPlayhead() }
            Button("Move Earlier") { model.moveClip(clip.id, by: -1) }
            Button("Move Later") { model.moveClip(clip.id, by: 1) }
            Divider()
            Button(clip.isMuted ? "Unmute" : "Mute") { model.clipBinding(clip.id, \.isMuted, "Mute Clip")?.wrappedValue.toggle() }
            Button("Delete", role: .destructive) {
                model.selection = .clip(clip.id)
                model.deleteSelection()
            }
        }
    }

    private var durationLabel: String {
        let seconds = clip.timelineDuration.seconds
        return seconds < 60 ? String(format: "%.0fs", seconds.rounded()) : formatTime(seconds)
    }

    @ViewBuilder
    private func thumbnails(width: CGFloat) -> some View {
        let strip = model.thumbnails[clip.sourceID] ?? []
        if strip.isEmpty {
            LinearGradient(colors: [Theme.accent.opacity(0.55), Theme.accent.opacity(0.3)], startPoint: .top, endPoint: .bottom)
        } else {
            Canvas { context, size in
                let tile = size.height * 16 / 9
                var x: CGFloat = 0
                while x < size.width {
                    let timeline = clip.timelinePosition.seconds + Double(x + trimOffset.head) / model.pixelsPerSecond
                    let source = clip.sourceTime(atTimeline: MediaTime(seconds: timeline)).seconds
                    let nearest = strip.min { abs($0.time - source) < abs($1.time - source) }
                    if let image = nearest?.image {
                        context.draw(Image(decorative: image, scale: 1), in: CGRect(x: x, y: 0, width: tile, height: size.height))
                    }
                    x += tile
                }
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.15)))
            }
        }
    }

    /// Drag a clip edge to trim its in or out point.
    private func handle(isHead: Bool) -> some View {
        Rectangle()
            .fill(Color.white.opacity(selected ? 0.9 : 0.001))
            .frame(width: 7)
            .clipShape(Capsule())
            .padding(.vertical, 14)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if isHead { trimOffset.head = value.translation.width } else { trimOffset.tail = value.translation.width }
                }
                .onEnded { value in
                    let delta = MediaTime(seconds: Double(value.translation.width) / model.pixelsPerSecond).multiplied(by: clip.playbackSpeed)
                    let duration = model.project.source(clip.sourceID).map { MediaTime(seconds: $0.duration) } ?? clip.sourceEnd
                    if isHead {
                        let start = min(max(clip.sourceStart + delta, .zero), clip.sourceEnd - TimelineValidator.minimumClipDuration)
                        model.trim(clipID: clip.id, sourceStart: start)
                    } else {
                        let end = max(min(clip.sourceEnd + delta, duration), clip.sourceStart + TimelineValidator.minimumClipDuration)
                        model.trim(clipID: clip.id, sourceEnd: end)
                    }
                    trimOffset = (0, 0)
                })
    }
}

// MARK: Zooms

/// Lane for zoom events. Click to add a zoom on the cursor, or drag across a range to add one that long.
struct ZoomRow: View {
    var model: EditorModel
    @State private var draft: (start: CGFloat, end: CGFloat)?

    var body: some View {
        let active = Set(model.resolvedMotion.events.map(\.id))
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(hex: 0x1E1B3A))
                .overlay {
                    if model.project.timeline.zoomEvents.isEmpty {
                        Text("Click or drag to add zoom on cursor").font(.system(size: 13.5)).foregroundStyle(Theme.textSecondary)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in draft = (value.startLocation.x, value.location.x) }
                    .onEnded { value in
                        let a = model.seconds(min(value.startLocation.x, value.location.x))
                        let b = model.seconds(max(value.startLocation.x, value.location.x))
                        draft = nil
                        model.seek(to: a)
                        if b - a >= 0.5 { model.addZoom(length: b - a) } else { model.addZoom() }
                    })
            if let draft {
                RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(0.4))
                    .frame(width: abs(draft.end - draft.start), height: 46)
                    .offset(x: min(draft.start, draft.end), y: 8)
                    .allowsHitTesting(false)
            }
            ForEach(model.project.timeline.zoomEvents) { event in
                ZoomBlock(model: model, event: event, isActive: active.contains(event.id))
            }
        }
    }
}

struct ZoomBlock: View {
    var model: EditorModel
    var event: ZoomEvent
    var isActive: Bool
    @State private var drag: (move: CGFloat, head: CGFloat, tail: CGFloat) = (0, 0, 0)

    var body: some View {
        let pps = model.pixelsPerSecond
        let selected = model.selection == .zoom(event.id)
        let x = CGFloat(event.startTime.seconds * pps) + drag.move + drag.head
        let width = max(CGFloat(event.duration.seconds * pps) - drag.head + drag.tail, 8)
        let tint = event.isAutomatic ? Theme.accent.opacity(0.85) : Theme.accent
        HStack(spacing: 4) {
            Image(systemName: event.isAutomatic ? "wand.and.stars" : "plus.magnifyingglass").font(.system(size: 9))
            Text(String(format: "%.1f×", event.scale)).font(.system(size: 12, weight: .semibold))
            if width > 110 { Text(event.isAutomatic ? "Auto" : "Zoom").font(.system(size: 11)).opacity(0.7) }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .frame(width: width, height: 46)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(isActive ? 0.8 : 0.3)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selected ? Color.white : tint, lineWidth: selected ? 2 : 1))
        .overlay(alignment: .leading) { edge(head: true) }
        .overlay(alignment: .trailing) { edge(head: false) }
        .offset(x: x, y: 8)
        .help(isActive ? (event.isAutomatic ? "Automatic zoom — edit it to make it yours" : "Zoom") : "Overridden by a manual zoom or keyframes")
        .onTapGesture { model.selection = .zoom(event.id) }
        .gesture(DragGesture(minimumDistance: 3)
            .onChanged { drag.move = $0.translation.width }
            .onEnded { value in
                let delta = MediaTime(seconds: Double(value.translation.width) / pps)
                let start = max(.zero, event.startTime + delta)
                let length = event.endTime - event.startTime
                model.updateZoom(event.id, name: "Move Zoom") {
                    $0.startTime = start
                    $0.endTime = start + length
                }
                model.endGesture()
                drag = (0, 0, 0)
            })
        .contextMenu {
            Button("Delete Zoom", role: .destructive) {
                model.selection = .zoom(event.id)
                model.deleteSelection()
            }
        }
    }

    private func edge(head: Bool) -> some View {
        Rectangle().fill(Color.white.opacity(0.001)).frame(width: 6)
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in if head { drag.head = value.translation.width } else { drag.tail = value.translation.width } }
                .onEnded { value in
                    let delta = MediaTime(seconds: Double(value.translation.width) / model.pixelsPerSecond)
                    model.updateZoom(event.id, name: "Resize Zoom") {
                        if head { $0.startTime = max(.zero, $0.startTime + delta) } else { $0.endTime = min($0.endTime + delta, model.project.duration) }
                    }
                    model.endGesture()
                    drag = (0, 0, 0)
                })
    }
}

// MARK: Keyframes, text and captions

struct MarkerRow: View {
    var model: EditorModel

    var body: some View {
        let pps = model.pixelsPerSecond
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(model.project.timeline.captions) { caption in
                let selected = model.selection == .caption(caption.id)
                Text(caption.text).font(.system(size: 9.5)).lineLimit(1).foregroundStyle(Theme.text)
                    .padding(.horizontal, 4)
                    .frame(width: max(CGFloat(caption.range.duration.seconds * pps), 4), height: 11, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(selected ? 0.35 : 0.14)))
                    .offset(x: CGFloat(caption.startTime.seconds * pps), y: 17)
                    .onTapGesture { model.selection = .caption(caption.id) }
            }
            ForEach(model.project.timeline.textOverlays) { overlay in
                let selected = model.selection == .text(overlay.id)
                Text(overlay.text).font(.system(size: 9.5, weight: .medium)).lineLimit(1).foregroundStyle(.black)
                    .padding(.horizontal, 4)
                    .frame(width: max(CGFloat(overlay.range.duration.seconds * pps), 4), height: 13, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.textTint.opacity(selected ? 1 : 0.75)))
                    .offset(x: CGFloat(overlay.startTime.seconds * pps), y: 2)
                    .onTapGesture { model.selection = .text(overlay.id) }
            }
            ForEach(model.project.timeline.keyframes) { keyframe in
                let selected = model.selection == .keyframe(keyframe.id)
                Image(systemName: "diamond.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white : Theme.zoomTint)
                    .offset(x: CGFloat(keyframe.timestamp.seconds * pps) - 5, y: 8)
                    .onTapGesture {
                        model.selection = .keyframe(keyframe.id)
                        model.seek(to: keyframe.timestamp.seconds)
                    }
            }
        }
    }
}

// MARK: Audio

struct AudioRow: View {
    var model: EditorModel
    var kind: TimelineTrack.Kind

    var body: some View {
        let pps = model.pixelsPerSecond
        let track = model.project.timeline.track(kind)
        let muted = track?.isMuted ?? false
        ZStack(alignment: .topLeading) {
            Color.clear
            if kind == .audio {
                ForEach(track?.audioClips ?? []) { clip in
                    let selected = model.selection == .audioClip(clip.id)
                    let path = model.project.source(clip.sourceID)?.screen?.relativePath
                    WaveformShape(peaks: path.flatMap { model.waveforms[$0] } ?? [], start: clip.sourceStart.seconds, span: clip.duration.seconds)
                        .fill(Theme.success.opacity(muted || clip.isMuted ? 0.25 : 0.7))
                        .frame(width: CGFloat(clip.duration.seconds * pps), height: 24)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.success.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? Color.white : Theme.success.opacity(0.4)))
                        .offset(x: CGFloat(clip.timelinePosition.seconds * pps), y: 3)
                        .onTapGesture { model.selection = .audioClip(clip.id) }
                }
            } else {
                // Linked tracks follow the screen clips.
                ForEach(model.project.timeline.videoClips) { clip in
                    let file = model.project.source(clip.sourceID).flatMap { kind == .microphone ? $0.microphone : ($0.systemAudio ?? $0.screen) }
                    let peaks = file.flatMap { model.waveforms[$0.relativePath] } ?? []
                    WaveformShape(peaks: peaks, start: clip.sourceStart.seconds - (file?.startOffset ?? 0),
                                  span: clip.sourceDuration.seconds)
                        .fill((kind == .microphone ? Theme.zoomTint : Theme.autoZoomTint).opacity(muted || clip.isMuted ? 0.2 : 0.65))
                        .frame(width: CGFloat(clip.timelineDuration.seconds * pps), height: 24)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.04)))
                        .offset(x: CGFloat(clip.timelinePosition.seconds * pps), y: 3)
                }
            }
        }
    }
}

/// Mirrored peak waveform of the file span `[start, start + span)` seconds. `peaks` holds `rate` values per second.
struct WaveformShape: Shape {
    var peaks: [Float]
    var start: Double
    var span: Double
    var rate: Double = 20

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let columns = max(Int(rect.width / 2), 1)
        guard !peaks.isEmpty, span > 0 else {
            path.addRect(CGRect(x: 0, y: rect.midY - 0.5, width: rect.width, height: 1))
            return path
        }
        let secondsPerColumn = span / Double(columns)
        for column in 0..<columns {
            let from = Int((start + Double(column) * secondsPerColumn) * rate)
            let to = max(from + 1, Int((start + Double(column + 1) * secondsPerColumn) * rate))
            var value: Float = 0
            if from < peaks.count, to > 0 {
                for index in max(from, 0)..<min(to, peaks.count) { value = max(value, peaks[index]) }
            }
            let height = max(1, CGFloat(value) * rect.height)
            path.addRect(CGRect(x: CGFloat(column) * 2, y: rect.midY - height / 2, width: 1.4, height: height))
        }
        return path
    }
}
