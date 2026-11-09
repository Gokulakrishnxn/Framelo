import Foundation

/// A row of the timeline.
/// `.video` holds the edit decisions (`clips`). `.camera`, `.microphone` and `.systemAudio` are linked tracks:
/// they follow the video clips of the same recording and only carry mute / visibility / volume.
/// `.audio` holds independent `audioClips`.
public struct TimelineTrack: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case video, camera, microphone, systemAudio, audio }

    public var id: UUID
    public var name: String
    public var type: Kind
    public var clips: [VideoClip]
    public var audioClips: [AudioClip]
    public var isMuted: Bool
    public var isVisible: Bool
    public var volume: Double

    public init(id: UUID = UUID(), name: String, type: Kind, clips: [VideoClip] = [], audioClips: [AudioClip] = [],
                isMuted: Bool = false, isVisible: Bool = true, volume: Double = 1) {
        self.id = id; self.name = name; self.type = type
        self.clips = clips; self.audioClips = audioClips
        self.isMuted = isMuted; self.isVisible = isVisible; self.volume = volume
    }
}
