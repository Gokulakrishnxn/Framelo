import Foundation

public enum TimelineValidationError: Error, Equatable, LocalizedError {
    case missingSource(clip: UUID)
    case emptyClip(clip: UUID)
    case sourceRangeOutOfBounds(clip: UUID)
    case invalidSpeed(clip: UUID, speed: Double)
    case negativePosition(clip: UUID)
    case overlappingClips(first: UUID, second: UUID)
    case invalidZoom(event: UUID, reason: String)
    case invalidOverlay(id: UUID)
    case unsortedKeyframes
    case invalidSetting(String)

    public var errorDescription: String? {
        switch self {
        case .missingSource: "A clip refers to media that is not part of this project."
        case .emptyClip: "A clip would have no duration."
        case .sourceRangeOutOfBounds: "A clip extends beyond the media it was cut from."
        case .invalidSpeed(_, let speed): "Playback speed \(speed) is outside the supported range (0.1× – 16×)."
        case .negativePosition: "A clip would start before the beginning of the timeline."
        case .overlappingClips: "Two clips would overlap on the timeline."
        case .invalidZoom(_, let reason): "Invalid zoom: \(reason)."
        case .invalidOverlay: "A text item or caption has an invalid time range."
        case .unsortedKeyframes: "Keyframes are out of order."
        case .invalidSetting(let name): "\(name) is out of range."
        }
    }
}

public enum TimelineValidator {
    public static let speedRange = 0.1...16.0
    public static let zoomScaleRange = 1.0...6.0
    /// Shortest clip allowed: one frame at 60 fps.
    public static let minimumClipDuration = MediaTime(ticks: 1000)

    public static func validate(_ project: Project) throws {
        let timeline = project.timeline
        for track in timeline.tracks {
            let sorted = track.clips.sorted { $0.timelinePosition < $1.timelinePosition }
            for clip in sorted {
                guard let source = project.source(clip.sourceID) else { throw TimelineValidationError.missingSource(clip: clip.id) }
                guard speedRange.contains(clip.playbackSpeed) else {
                    throw TimelineValidationError.invalidSpeed(clip: clip.id, speed: clip.playbackSpeed)
                }
                guard clip.sourceEnd > clip.sourceStart, clip.timelineDuration.ticks > 0 else {
                    throw TimelineValidationError.emptyClip(clip: clip.id)
                }
                // Half a tick of tolerance for durations stored as Double seconds.
                let sourceEnd = MediaTime(seconds: source.duration) + MediaTime(ticks: 1)
                guard clip.sourceStart >= .zero, clip.sourceEnd <= sourceEnd else {
                    throw TimelineValidationError.sourceRangeOutOfBounds(clip: clip.id)
                }
                guard clip.timelinePosition >= .zero else { throw TimelineValidationError.negativePosition(clip: clip.id) }
            }
            for (a, b) in zip(sorted, sorted.dropFirst()) where a.timelineEnd > b.timelinePosition {
                throw TimelineValidationError.overlappingClips(first: a.id, second: b.id)
            }
            let audio = track.audioClips.sorted { $0.timelinePosition < $1.timelinePosition }
            for clip in audio {
                guard project.source(clip.sourceID) != nil else { throw TimelineValidationError.missingSource(clip: clip.id) }
                guard clip.sourceEnd > clip.sourceStart else { throw TimelineValidationError.emptyClip(clip: clip.id) }
                guard clip.timelinePosition >= .zero else { throw TimelineValidationError.negativePosition(clip: clip.id) }
            }
            for (a, b) in zip(audio, audio.dropFirst()) where a.timelineEnd > b.timelinePosition {
                throw TimelineValidationError.overlappingClips(first: a.id, second: b.id)
            }
        }

        for event in timeline.zoomEvents {
            guard event.endTime > event.startTime else {
                throw TimelineValidationError.invalidZoom(event: event.id, reason: "it ends before it starts")
            }
            guard event.startTime >= .zero else {
                throw TimelineValidationError.invalidZoom(event: event.id, reason: "it starts before the timeline")
            }
            guard zoomScaleRange.contains(event.scale) else {
                throw TimelineValidationError.invalidZoom(event: event.id, reason: "scale must be between 1× and 6×")
            }
            guard (0...1).contains(event.targetX), (0...1).contains(event.targetY) else {
                throw TimelineValidationError.invalidZoom(event: event.id, reason: "its target is outside the screen")
            }
            guard event.transitionIn >= 0, event.transitionOut >= 0 else {
                throw TimelineValidationError.invalidZoom(event: event.id, reason: "transition durations must be positive")
            }
        }

        for (a, b) in zip(timeline.keyframes, timeline.keyframes.dropFirst()) where a.timestamp > b.timestamp {
            throw TimelineValidationError.unsortedKeyframes
        }
        for keyframe in timeline.keyframes where !zoomScaleRange.contains(keyframe.scale) {
            throw TimelineValidationError.invalidSetting("Keyframe scale")
        }
        for overlay in timeline.textOverlays where overlay.endTime <= overlay.startTime || overlay.startTime < .zero {
            throw TimelineValidationError.invalidOverlay(id: overlay.id)
        }
        for caption in timeline.captions where caption.endTime <= caption.startTime || caption.startTime < .zero {
            throw TimelineValidationError.invalidOverlay(id: caption.id)
        }

        let s = project.settings
        guard (0...0.4).contains(s.screen.padding) else { throw TimelineValidationError.invalidSetting("Padding") }
        guard (0...0.2).contains(s.screen.cornerRadius) else { throw TimelineValidationError.invalidSetting("Corner radius") }
        guard (0.05...1).contains(s.camera.size) else { throw TimelineValidationError.invalidSetting("Camera size") }
        guard (0.2...6).contains(s.cursor.size) else { throw TimelineValidationError.invalidSetting("Cursor size") }
    }
}
