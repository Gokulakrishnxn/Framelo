import Foundation

public enum TimelineEditError: Error, Equatable, LocalizedError {
    case clipNotFound
    case nothingAtPlayhead
    case tooCloseToEdge
    case noVideoTrack

    public var errorDescription: String? {
        switch self {
        case .clipNotFound: "That clip no longer exists."
        case .nothingAtPlayhead: "There is no clip under the playhead."
        case .tooCloseToEdge: "The playhead is too close to the edge of the clip to cut there."
        case .noVideoTrack: "This project has no video track."
        }
    }
}

/// Pure edit operations on a `Timeline`. Every function either succeeds completely or throws without side effects
/// on the caller's value (callers pass a copy; see `CommandStack`).
public enum TimelineEditor {
    // MARK: Clips

    /// Splits the clip under `time` in two. Returns the IDs of the left and right halves.
    @discardableResult
    public static func split(_ timeline: inout Timeline, at time: MediaTime) throws -> (left: UUID, right: UUID) {
        guard let track = timeline.videoTrackIndex else { throw TimelineEditError.noVideoTrack }
        guard let index = timeline.tracks[track].clips.firstIndex(where: { $0.timelineRange.contains(time) }) else {
            throw TimelineEditError.nothingAtPlayhead
        }
        let clip = timeline.tracks[track].clips[index]
        let minimum = TimelineValidator.minimumClipDuration
        guard time - clip.timelinePosition >= minimum, clip.timelineEnd - time >= minimum else {
            throw TimelineEditError.tooCloseToEdge
        }
        let cut = clip.sourceTime(atTimeline: time)
        var left = clip
        left.sourceEnd = cut
        left.transitionOut = nil
        var right = clip
        right.id = UUID()
        right.sourceStart = cut
        right.timelinePosition = time
        right.transitionIn = nil
        timeline.tracks[track].clips[index] = left
        timeline.tracks[track].clips.insert(right, at: index + 1)
        return (left.id, right.id)
    }

    /// Changes a clip's in/out points (source time). With `ripple`, everything after the clip moves to stay attached.
    public static func trim(_ timeline: inout Timeline, clipID: UUID, sourceStart: MediaTime? = nil,
                            sourceEnd: MediaTime? = nil, ripple: Bool = true) throws {
        guard let track = timeline.videoTrackIndex,
              let index = timeline.tracks[track].clips.firstIndex(where: { $0.id == clipID }) else {
            throw TimelineEditError.clipNotFound
        }
        var clip = timeline.tracks[track].clips[index]
        let oldRange = clip.timelineRange
        if let sourceStart {
            let delta = (sourceStart - clip.sourceStart).divided(by: clip.playbackSpeed)
            clip.sourceStart = sourceStart
            // Trimming the head: without ripple the clip's end stays put, so its position moves.
            if !ripple { clip.timelinePosition += delta }
        }
        if let sourceEnd { clip.sourceEnd = sourceEnd }
        timeline.tracks[track].clips[index] = clip
        if ripple {
            let delta = clip.timelineDuration - oldRange.duration
            shiftClips(&timeline, track: track, after: index, by: delta)
            rippleAnnotations(&timeline, at: delta.ticks < 0 ? oldRange.end + delta : oldRange.end, delta: delta)
        }
    }

    /// Removes a clip. With `ripple`, later clips close the gap.
    public static func delete(_ timeline: inout Timeline, clipID: UUID, ripple: Bool = true) throws {
        guard let track = timeline.videoTrackIndex,
              let index = timeline.tracks[track].clips.firstIndex(where: { $0.id == clipID }) else {
            throw TimelineEditError.clipNotFound
        }
        let range = timeline.tracks[track].clips[index].timelineRange
        timeline.tracks[track].clips.remove(at: index)
        if ripple {
            shiftClips(&timeline, track: track, after: index - 1, by: MediaTime(ticks: -range.duration.ticks))
            rippleAnnotations(&timeline, at: range.start, delta: MediaTime(ticks: -range.duration.ticks))
        }
    }

    /// Removes a section of the timeline, cutting clips at its edges.
    public static func deleteRange(_ timeline: inout Timeline, range: MediaRange, ripple: Bool = true) throws {
        guard let track = timeline.videoTrackIndex else { throw TimelineEditError.noVideoTrack }
        guard !range.isEmpty else { return }
        var result: [VideoClip] = []
        for clip in timeline.tracks[track].clips {
            let clipRange = clip.timelineRange
            guard clipRange.overlaps(range) else { result.append(clip); continue }
            if clipRange.start < range.start {
                var head = clip
                head.sourceEnd = clip.sourceTime(atTimeline: range.start)
                head.transitionOut = nil
                if head.sourceDuration.ticks > 0 { result.append(head) }
            }
            if clipRange.end > range.end {
                var tail = clip
                if clipRange.start < range.start { tail.id = UUID() }
                tail.sourceStart = clip.sourceTime(atTimeline: range.end)
                tail.timelinePosition = range.end
                tail.transitionIn = nil
                if tail.sourceDuration.ticks > 0 { result.append(tail) }
            }
        }
        if ripple {
            let delta = MediaTime(ticks: -range.duration.ticks)
            result = result.map { clip in
                var c = clip
                if c.timelinePosition >= range.end { c.timelinePosition += delta }
                return c
            }
            rippleAnnotations(&timeline, at: range.start, delta: delta)
        }
        timeline.tracks[track].clips = result
    }

    /// Moves a clip to a new index and repacks the track so clips follow each other without gaps.
    public static func reorder(_ timeline: inout Timeline, clipID: UUID, toIndex: Int) throws {
        guard let track = timeline.videoTrackIndex,
              let index = timeline.tracks[track].clips.firstIndex(where: { $0.id == clipID }) else {
            throw TimelineEditError.clipNotFound
        }
        var clips = timeline.tracks[track].clips
        let clip = clips.remove(at: index)
        clips.insert(clip, at: min(max(toIndex, 0), clips.count))
        timeline.tracks[track].clips = packed(clips)
    }

    /// Moves a clip to a timeline position, leaving a gap where it was.
    public static func move(_ timeline: inout Timeline, clipID: UUID, to position: MediaTime) throws {
        guard let track = timeline.videoTrackIndex,
              let index = timeline.tracks[track].clips.firstIndex(where: { $0.id == clipID }) else {
            throw TimelineEditError.clipNotFound
        }
        timeline.tracks[track].clips[index].timelinePosition = max(position, .zero)
        timeline.tracks[track].clips.sort { $0.timelinePosition < $1.timelinePosition }
    }

    public static func setSpeed(_ timeline: inout Timeline, clipID: UUID, speed: Double, ripple: Bool = true) throws {
        guard let track = timeline.videoTrackIndex,
              let index = timeline.tracks[track].clips.firstIndex(where: { $0.id == clipID }) else {
            throw TimelineEditError.clipNotFound
        }
        let old = timeline.tracks[track].clips[index].timelineRange
        timeline.tracks[track].clips[index].playbackSpeed = speed
        if ripple {
            let delta = timeline.tracks[track].clips[index].timelineDuration - old.duration
            shiftClips(&timeline, track: track, after: index, by: delta)
            rippleAnnotations(&timeline, at: delta.ticks < 0 ? old.end + delta : old.end, delta: delta)
        }
    }

    /// Removes all gaps on the video track.
    public static func closeGaps(_ timeline: inout Timeline) {
        guard let track = timeline.videoTrackIndex else { return }
        timeline.tracks[track].clips = packed(timeline.tracks[track].clips.sorted { $0.timelinePosition < $1.timelinePosition })
    }

    // MARK: Zoom events and keyframes

    public static func upsertZoom(_ timeline: inout Timeline, _ event: ZoomEvent) {
        if let index = timeline.zoomEvents.firstIndex(where: { $0.id == event.id }) {
            timeline.zoomEvents[index] = event
        } else {
            timeline.zoomEvents.append(event)
        }
        timeline.zoomEvents.sort { $0.startTime < $1.startTime }
    }

    /// Removes a zoom. Removing an automatic one remembers its range so regeneration does not bring it back.
    public static func removeZoom(_ timeline: inout Timeline, id: UUID) {
        guard let index = timeline.zoomEvents.firstIndex(where: { $0.id == id }) else { return }
        let event = timeline.zoomEvents.remove(at: index)
        if event.isAutomatic { timeline.suppressedAutoZoomRanges.append(event.range) }
    }

    public static func upsertKeyframe(_ timeline: inout Timeline, _ keyframe: MotionKeyframe) {
        if let index = timeline.keyframes.firstIndex(where: { $0.id == keyframe.id }) {
            timeline.keyframes[index] = keyframe
        } else {
            timeline.keyframes.append(keyframe)
        }
        timeline.keyframes.sort { $0.timestamp < $1.timestamp }
    }

    // MARK: Helpers

    private static func packed(_ clips: [VideoClip]) -> [VideoClip] {
        var cursor = MediaTime.zero
        return clips.map { clip in
            var c = clip
            c.timelinePosition = cursor
            cursor = c.timelineEnd
            return c
        }
    }

    private static func shiftClips(_ timeline: inout Timeline, track: Int, after index: Int, by delta: MediaTime) {
        guard delta.ticks != 0 else { return }
        for i in timeline.tracks[track].clips.indices where i > index {
            timeline.tracks[track].clips[i].timelinePosition += delta
        }
    }

    /// Inserts (`delta > 0`) or removes (`delta < 0`) time at `time` for everything that lives in timeline time:
    /// zoom events, keyframes, text, captions, suppression ranges and independent audio clips.
    static func rippleAnnotations(_ timeline: inout Timeline, at time: MediaTime, delta: MediaTime) {
        guard delta.ticks != 0 else { return }
        let removed: MediaRange? = delta.ticks < 0 ? MediaRange(start: time, duration: MediaTime(ticks: -delta.ticks)) : nil

        func map(_ t: MediaTime) -> MediaTime {
            if let removed {
                if t <= removed.start { return t }
                if t >= removed.end { return t + delta }
                return removed.start
            }
            return t >= time ? t + delta : t
        }
        func mapRange(_ start: MediaTime, _ end: MediaTime) -> (MediaTime, MediaTime)? {
            let s = map(start)
            let e = map(end)
            return e > s ? (s, e) : nil
        }

        timeline.zoomEvents = timeline.zoomEvents.compactMap { event in
            guard let (s, e) = mapRange(event.startTime, event.endTime) else { return nil }
            var copy = event
            copy.startTime = s
            copy.endTime = e
            return copy
        }
        timeline.keyframes = timeline.keyframes.compactMap { keyframe in
            if let removed, keyframe.timestamp > removed.start, keyframe.timestamp < removed.end { return nil }
            var copy = keyframe
            copy.timestamp = map(keyframe.timestamp)
            return copy
        }
        timeline.textOverlays = timeline.textOverlays.compactMap { overlay in
            guard let (s, e) = mapRange(overlay.startTime, overlay.endTime) else { return nil }
            var copy = overlay
            copy.startTime = s
            copy.endTime = e
            return copy
        }
        timeline.captions = timeline.captions.compactMap { caption in
            guard let (s, e) = mapRange(caption.startTime, caption.endTime) else { return nil }
            var copy = caption
            copy.startTime = s
            copy.endTime = e
            return copy
        }
        timeline.suppressedAutoZoomRanges = timeline.suppressedAutoZoomRanges.compactMap { range in
            guard let (s, e) = mapRange(range.start, range.end) else { return nil }
            return MediaRange(start: s, end: e)
        }
        for t in timeline.tracks.indices where timeline.tracks[t].type == .audio {
            for c in timeline.tracks[t].audioClips.indices where timeline.tracks[t].audioClips[c].timelinePosition >= time {
                let moved = timeline.tracks[t].audioClips[c].timelinePosition + delta
                timeline.tracks[t].audioClips[c].timelinePosition = max(moved, .zero)
            }
        }
    }
}
