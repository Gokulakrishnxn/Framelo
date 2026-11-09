import Foundation

/// An independent audio clip (music, voice-over) on an audio track.
public struct AudioClip: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sourceID: UUID
    public var sourceStart: MediaTime
    public var sourceEnd: MediaTime
    public var timelinePosition: MediaTime
    public var volume: Double
    public var isMuted: Bool
    public var fadeIn: Double
    public var fadeOut: Double

    public init(id: UUID = UUID(), sourceID: UUID, sourceStart: MediaTime, sourceEnd: MediaTime,
                timelinePosition: MediaTime, volume: Double = 1, isMuted: Bool = false,
                fadeIn: Double = 0, fadeOut: Double = 0) {
        self.id = id; self.sourceID = sourceID
        self.sourceStart = sourceStart; self.sourceEnd = sourceEnd
        self.timelinePosition = timelinePosition
        self.volume = volume; self.isMuted = isMuted; self.fadeIn = fadeIn; self.fadeOut = fadeOut
    }

    public var duration: MediaTime { sourceEnd - sourceStart }
    public var timelineRange: MediaRange { MediaRange(start: timelinePosition, duration: duration) }
    public var timelineEnd: MediaTime { timelinePosition + duration }
}
