import Foundation

public struct ClipTransform: Codable, Hashable, Sendable {
    public var scale: Double
    public var offsetX: Double
    public var offsetY: Double

    public init(scale: Double = 1, offsetX: Double = 0, offsetY: Double = 0) {
        self.scale = scale; self.offsetX = offsetX; self.offsetY = offsetY
    }

    public static let identity = ClipTransform()
}

/// Transition played at a clip boundary. Rendered as an opacity/scale ramp of the screen card.
public struct ClipTransition: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case fade, zoomFade
        public var id: String { rawValue }
        public var displayName: String { self == .fade ? "Fade" : "Zoom Fade" }
    }

    public var kind: Kind
    public var duration: Double

    public init(kind: Kind = .fade, duration: Double = 0.4) {
        self.kind = kind; self.duration = duration
    }
}

/// A non-destructive reference to a time range of a source, placed on the timeline.
/// `sourceStart`/`sourceEnd` are in the source's session timebase.
public struct VideoClip: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sourceID: UUID
    public var sourceStart: MediaTime
    public var sourceEnd: MediaTime
    public var timelinePosition: MediaTime
    public var playbackSpeed: Double
    public var volume: Double
    public var isMuted: Bool
    public var transform: ClipTransform
    public var transitionIn: ClipTransition?
    public var transitionOut: ClipTransition?

    public init(id: UUID = UUID(), sourceID: UUID, sourceStart: MediaTime, sourceEnd: MediaTime,
                timelinePosition: MediaTime, playbackSpeed: Double = 1, volume: Double = 1, isMuted: Bool = false,
                transform: ClipTransform = .identity, transitionIn: ClipTransition? = nil,
                transitionOut: ClipTransition? = nil) {
        self.id = id; self.sourceID = sourceID
        self.sourceStart = sourceStart; self.sourceEnd = sourceEnd
        self.timelinePosition = timelinePosition; self.playbackSpeed = playbackSpeed
        self.volume = volume; self.isMuted = isMuted; self.transform = transform
        self.transitionIn = transitionIn; self.transitionOut = transitionOut
    }

    public var sourceDuration: MediaTime { sourceEnd - sourceStart }
    public var timelineDuration: MediaTime { sourceDuration.divided(by: playbackSpeed) }
    public var timelineRange: MediaRange { MediaRange(start: timelinePosition, duration: timelineDuration) }
    public var timelineEnd: MediaTime { timelinePosition + timelineDuration }

    /// Source time shown at a timeline time inside this clip.
    public func sourceTime(atTimeline time: MediaTime) -> MediaTime {
        let local = (time - timelinePosition).multiplied(by: playbackSpeed)
        return min(max(sourceStart + local, sourceStart), sourceEnd)
    }

    /// Timeline time at which a source time is shown (clamped to the clip).
    public func timelineTime(forSource time: MediaTime) -> MediaTime {
        let local = (min(max(time, sourceStart), sourceEnd) - sourceStart).divided(by: playbackSpeed)
        return timelinePosition + local
    }
}
