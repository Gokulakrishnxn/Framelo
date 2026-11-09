@preconcurrency import AVFoundation
import CoreGraphics
import Foundation

/// The mutable part of a render: the plan the compositor draws from. The editor replaces the plan as the
/// user changes styling, without rebuilding the composition. Lock-protected.
public final class RenderContext: @unchecked Sendable {
    private let lock = NSLock()
    private var current: RenderPlan
    public let screenTrackID: CMPersistentTrackID
    public let cameraTrackID: CMPersistentTrackID

    public init(plan: RenderPlan, screenTrackID: CMPersistentTrackID, cameraTrackID: CMPersistentTrackID) {
        self.current = plan
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
    }

    public var plan: RenderPlan {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// An `AVComposition` assembled from a project's edit decisions. Immutable once built
/// (the invariant behind `@unchecked Sendable`).
public struct BuiltComposition: @unchecked Sendable {
    public let composition: AVComposition
    public let audioMix: AVAudioMix?
    public let screenTrackID: CMPersistentTrackID
    /// `kCMPersistentTrackID_Invalid` when the project has no camera.
    public let cameraTrackID: CMPersistentTrackID
    public let hasAudio: Bool
    public let duration: MediaTime

    public func makeContext(plan: RenderPlan) -> RenderContext {
        RenderContext(plan: plan, screenTrackID: screenTrackID, cameraTrackID: cameraTrackID)
    }

    /// Video composition that routes every frame through `FrameloCompositor`.
    public func videoComposition(context: RenderContext, renderSize: CGSize, frameRate: Int) -> AVVideoComposition {
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = FrameloCompositor.self
        composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        composition.renderSize = renderSize
        var trackIDs = [screenTrackID]
        if cameraTrackID != kCMPersistentTrackID_Invalid { trackIDs.append(cameraTrackID) }
        composition.instructions = [
            FrameloInstruction(timeRange: CMTimeRange(start: .zero, duration: duration.cmTime), context: context, trackIDs: trackIDs),
        ]
        return composition
    }
}

public enum CompositionError: Error, LocalizedError {
    case emptyTimeline
    case missingMedia(String)
    case insertFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyTimeline: "There is nothing on the timeline yet."
        case .missingMedia(let name): "“\(name)” could not be found. It may have been moved, renamed or deleted."
        case .insertFailed(let reason): "The timeline could not be assembled: \(reason)"
        }
    }
}

/// Turns the non-destructive edit list into an `AVComposition` + audio mix. Source files are only read.
public enum CompositionBuilder {
    private struct Loaded {
        /// Tracks only hold a weak reference to their asset, so the asset must be kept alive alongside them.
        var asset: AVURLAsset
        var video: AVAssetTrack?
        var audio: AVAssetTrack?
        var videoDuration = CMTime.zero
        var audioDuration = CMTime.zero
    }

    public static func build(project: Project, package: URL) async throws -> BuiltComposition {
        let timeline = project.timeline
        let clips = timeline.videoClips.sorted { $0.timelinePosition < $1.timelinePosition }
        guard !clips.isEmpty, timeline.duration > .zero else { throw CompositionError.emptyTimeline }

        let composition = AVMutableComposition()
        guard let screenTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CompositionError.insertFailed("no video track")
        }
        var cameraTrack: AVMutableCompositionTrack?
        var micTrack: AVMutableCompositionTrack?
        var systemTrack: AVMutableCompositionTrack?
        var cache: [URL: Loaded] = [:]

        func load(_ file: MediaFile) async throws -> Loaded {
            let url = ProjectPackage.resolve(file.relativePath, in: package)
            if let existing = cache[url] { return existing }
            guard FileManager.default.fileExists(atPath: url.path) else { throw CompositionError.missingMedia(url.lastPathComponent) }
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            var loaded = Loaded(asset: asset)
            do {
                if let track = try await asset.loadTracks(withMediaType: .video).first {
                    loaded.video = track
                    loaded.videoDuration = try await track.load(.timeRange).duration
                }
                if let track = try await asset.loadTracks(withMediaType: .audio).first {
                    loaded.audio = track
                    loaded.audioDuration = try await track.load(.timeRange).duration
                }
            } catch {
                throw CompositionError.missingMedia(url.lastPathComponent)
            }
            cache[url] = loaded
            return loaded
        }

        /// Places the part of `file` that falls inside `clip` onto `track`.
        func insert(_ file: MediaFile, assetTrack: AVAssetTrack, available: CMTime, clip: VideoClip,
                    into track: AVMutableCompositionTrack) throws {
            let rate = file.rateCorrection > 0 ? file.rateCorrection : 1
            let offset = MediaTime(seconds: file.startOffset)
            let fileEnd = offset + MediaTime(available).divided(by: rate)
            let start = max(clip.sourceStart, offset)
            let end = min(clip.sourceEnd, fileEnd)
            guard end > start else { return }
            let fileRange = CMTimeRange(start: (start - offset).multiplied(by: rate).cmTime,
                                        duration: (end - start).multiplied(by: rate).cmTime)
            let position = clip.timelinePosition + (start - clip.sourceStart).divided(by: clip.playbackSpeed)
            let target = (end - start).divided(by: clip.playbackSpeed).cmTime
            do {
                try track.insertTimeRange(fileRange, of: assetTrack, at: position.cmTime)
            } catch {
                throw CompositionError.insertFailed(error.localizedDescription)
            }
            if target != fileRange.duration {
                track.scaleTimeRange(CMTimeRange(start: position.cmTime, duration: fileRange.duration), toDuration: target)
            }
        }

        func audioTrack(_ existing: inout AVMutableCompositionTrack?) -> AVMutableCompositionTrack? {
            if existing == nil {
                existing = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            }
            return existing
        }

        for clip in clips {
            guard let source = project.source(clip.sourceID) else { continue }
            if let file = source.screen {
                let loaded = try await load(file)
                if let video = loaded.video {
                    try insert(file, assetTrack: video, available: loaded.videoDuration, clip: clip, into: screenTrack)
                }
                // Imported videos carry their own audio in the same file.
                if source.systemAudio == nil, let audio = loaded.audio, let track = audioTrack(&systemTrack) {
                    try insert(file, assetTrack: audio, available: loaded.audioDuration, clip: clip, into: track)
                }
            }
            if let file = source.camera, let video = try await load(file).video {
                if cameraTrack == nil {
                    cameraTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                }
                if let cameraTrack {
                    try insert(file, assetTrack: video, available: try await load(file).videoDuration, clip: clip, into: cameraTrack)
                }
            }
            if let file = source.microphone, let audio = try await load(file).audio, let track = audioTrack(&micTrack) {
                try insert(file, assetTrack: audio, available: try await load(file).audioDuration, clip: clip, into: track)
            }
            if let file = source.systemAudio, let audio = try await load(file).audio, let track = audioTrack(&systemTrack) {
                try insert(file, assetTrack: audio, available: try await load(file).audioDuration, clip: clip, into: track)
            }
        }

        // Audio mix: linked tracks follow per-clip volume; independent audio tracks use their own clips.
        var parameters: [AVMutableAudioMixInputParameters] = []
        let duration = timeline.duration
        let audioSettings = project.settings.audio

        func applyFades(_ params: AVMutableAudioMixInputParameters, first: Float, last: Float) {
            if audioSettings.fadeIn > 0 {
                params.setVolumeRamp(fromStartVolume: 0, toEndVolume: first,
                                     timeRange: CMTimeRange(start: .zero, duration: MediaTime(seconds: audioSettings.fadeIn).cmTime))
            }
            if audioSettings.fadeOut > 0 {
                let fade = min(MediaTime(seconds: audioSettings.fadeOut), duration)
                params.setVolumeRamp(fromStartVolume: last, toEndVolume: 0,
                                     timeRange: CMTimeRange(start: (duration - fade).cmTime, duration: fade.cmTime))
            }
        }

        func linkedParameters(_ track: AVMutableCompositionTrack?, kind: TimelineTrack.Kind) {
            guard let track else { return }
            let settings = timeline.track(kind)
            let base = (settings?.isMuted ?? false) ? 0 : Float(settings?.volume ?? 1)
            let params = AVMutableAudioMixInputParameters(track: track)
            var volumes: [Float] = []
            for clip in clips {
                let volume = clip.isMuted ? 0 : base * Float(clip.volume)
                params.setVolume(volume, at: clip.timelinePosition.cmTime)
                volumes.append(volume)
            }
            applyFades(params, first: volumes.first ?? base, last: volumes.last ?? base)
            parameters.append(params)
        }
        linkedParameters(micTrack, kind: .microphone)
        linkedParameters(systemTrack, kind: .systemAudio)

        for track in timeline.tracks where track.type == .audio && !track.audioClips.isEmpty {
            guard let compositionTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let params = AVMutableAudioMixInputParameters(track: compositionTrack)
            let base = track.isMuted ? 0 : Float(track.volume)
            for clip in track.audioClips.sorted(by: { $0.timelinePosition < $1.timelinePosition }) {
                guard let source = project.source(clip.sourceID), let file = source.screen ?? source.microphone,
                      let audio = try await load(file).audio else { continue }
                let available = MediaTime(try await load(file).audioDuration)
                let start = max(clip.sourceStart, .zero)
                let end = min(clip.sourceEnd, available)
                guard end > start else { continue }
                do {
                    try compositionTrack.insertTimeRange(CMTimeRange(start: start.cmTime, duration: (end - start).cmTime),
                                                         of: audio, at: clip.timelinePosition.cmTime)
                } catch {
                    throw CompositionError.insertFailed(error.localizedDescription)
                }
                let volume = clip.isMuted ? 0 : base * Float(clip.volume)
                params.setVolume(volume, at: clip.timelinePosition.cmTime)
                if clip.fadeIn > 0 {
                    params.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume,
                                         timeRange: CMTimeRange(start: clip.timelinePosition.cmTime,
                                                                duration: MediaTime(seconds: clip.fadeIn).cmTime))
                }
                if clip.fadeOut > 0 {
                    let fade = MediaTime(seconds: clip.fadeOut)
                    params.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0,
                                         timeRange: CMTimeRange(start: (clip.timelineEnd - fade).cmTime, duration: fade.cmTime))
                }
            }
            parameters.append(params)
        }

        var mix: AVMutableAudioMix?
        if !parameters.isEmpty {
            mix = AVMutableAudioMix()
            mix?.inputParameters = parameters
        }
        guard let immutable = composition.copy() as? AVComposition else {
            throw CompositionError.insertFailed("could not finalise the composition")
        }
        return BuiltComposition(composition: immutable, audioMix: mix, screenTrackID: screenTrack.trackID,
                                cameraTrackID: cameraTrack?.trackID ?? kCMPersistentTrackID_Invalid,
                                hasAudio: !parameters.isEmpty, duration: duration)
    }
}
