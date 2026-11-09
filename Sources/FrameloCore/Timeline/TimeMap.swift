import Foundation

/// Deterministic mapping between timeline time and source (session) time.
/// Built from the video clips; pure value type, safe to use from any thread.
public struct TimeMap: Sendable, Equatable {
    public struct Segment: Sendable, Equatable {
        public var clipID: UUID
        public var sourceID: UUID
        public var timeline: MediaRange
        public var sourceStart: MediaTime
        public var sourceEnd: MediaTime
        public var speed: Double
    }

    public enum Location: Sendable, Equatable {
        /// `sourceTime` is in the source's session timebase.
        case clip(segmentIndex: Int, sourceTime: MediaTime)
        /// No clip covers this time; the background is shown.
        case gap
    }

    public let segments: [Segment]
    public let duration: MediaTime

    public init(clips: [VideoClip], duration: MediaTime? = nil) {
        let sorted = clips.sorted { $0.timelinePosition < $1.timelinePosition }
        self.segments = sorted.map {
            Segment(clipID: $0.id, sourceID: $0.sourceID, timeline: $0.timelineRange,
                    sourceStart: $0.sourceStart, sourceEnd: $0.sourceEnd, speed: $0.playbackSpeed)
        }
        self.duration = duration ?? (segments.map(\.timeline.end).max() ?? .zero)
    }

    public init(project: Project) {
        self.init(clips: project.timeline.videoClips, duration: project.timeline.duration)
    }

    /// Index of the segment covering `time`. The final instant of the timeline belongs to the last segment.
    public func segmentIndex(at time: MediaTime) -> Int? {
        var lo = 0
        var hi = segments.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let range = segments[mid].timeline
            if time < range.start {
                hi = mid - 1
            } else if time >= range.end {
                lo = mid + 1
            } else {
                return mid
            }
        }
        if let last = segments.indices.last, time == segments[last].timeline.end, time == duration { return last }
        return nil
    }

    public func locate(_ time: MediaTime) -> Location {
        guard let index = segmentIndex(at: time) else { return .gap }
        return .clip(segmentIndex: index, sourceTime: sourceTime(in: index, at: time))
    }

    public func sourceTime(in index: Int, at time: MediaTime) -> MediaTime {
        let segment = segments[index]
        let local = (time - segment.timeline.start).multiplied(by: segment.speed)
        return min(max(segment.sourceStart + local, segment.sourceStart), segment.sourceEnd)
    }

    /// Every timeline time at which a source time is visible (a source range can be used by several clips).
    public func timelineTimes(forSource time: MediaTime, sourceID: UUID) -> [MediaTime] {
        segments.compactMap { segment in
            guard segment.sourceID == sourceID, time >= segment.sourceStart, time < segment.sourceEnd else { return nil }
            return segment.timeline.start + (time - segment.sourceStart).divided(by: segment.speed)
        }
    }

    /// Gaps between and before clips, in timeline time.
    public var gaps: [MediaRange] {
        var result: [MediaRange] = []
        var cursor = MediaTime.zero
        for segment in segments {
            if segment.timeline.start > cursor { result.append(MediaRange(start: cursor, end: segment.timeline.start)) }
            cursor = max(cursor, segment.timeline.end)
        }
        if duration > cursor { result.append(MediaRange(start: cursor, end: duration)) }
        return result
    }
}
