import Foundation

public struct Timeline: Codable, Hashable, Sendable {
    public var tracks: [TimelineTrack]
    public var zoomEvents: [ZoomEvent]
    public var keyframes: [MotionKeyframe]
    public var textOverlays: [TextOverlay]
    public var captions: [Caption]
    /// Timeline ranges where the user removed an automatic zoom; regeneration will not put one back.
    public var suppressedAutoZoomRanges: [MediaRange]

    public init(tracks: [TimelineTrack] = [], zoomEvents: [ZoomEvent] = [], keyframes: [MotionKeyframe] = [],
                textOverlays: [TextOverlay] = [], captions: [Caption] = [],
                suppressedAutoZoomRanges: [MediaRange] = []) {
        self.tracks = tracks; self.zoomEvents = zoomEvents; self.keyframes = keyframes
        self.textOverlays = textOverlays; self.captions = captions
        self.suppressedAutoZoomRanges = suppressedAutoZoomRanges
    }

    public var videoTrackIndex: Int? { tracks.firstIndex { $0.type == .video } }

    public var videoClips: [VideoClip] {
        get { videoTrackIndex.map { tracks[$0].clips } ?? [] }
        set {
            if let index = videoTrackIndex {
                tracks[index].clips = newValue
            } else {
                tracks.insert(TimelineTrack(name: "Screen", type: .video, clips: newValue), at: 0)
            }
        }
    }

    public func track(_ kind: TimelineTrack.Kind) -> TimelineTrack? { tracks.first { $0.type == kind } }

    /// End of the last clip on any track.
    public var duration: MediaTime {
        var end = MediaTime.zero
        for track in tracks {
            for clip in track.clips { end = max(end, clip.timelineEnd) }
            for clip in track.audioClips { end = max(end, clip.timelineEnd) }
        }
        return end
    }
}

public struct ProjectSettings: Codable, Hashable, Sendable {
    public var aspect: AspectRatio
    public var background: BackgroundStyle
    public var screen: ScreenStyle
    public var cursor: CursorStyle
    public var camera: CameraStyle
    public var motion: MotionSettings
    public var audio: AudioSettings
    public var captions: CaptionStyle
    public var export: ExportSettings

    public init(aspect: AspectRatio = AspectRatio(), background: BackgroundStyle = BackgroundStyle(),
                screen: ScreenStyle = ScreenStyle(), cursor: CursorStyle = CursorStyle(),
                camera: CameraStyle = CameraStyle(), motion: MotionSettings = MotionSettings(),
                audio: AudioSettings = AudioSettings(), captions: CaptionStyle = CaptionStyle(),
                export: ExportSettings = ExportSettings()) {
        self.aspect = aspect; self.background = background; self.screen = screen
        self.cursor = cursor; self.camera = camera; self.motion = motion
        self.audio = audio; self.captions = captions; self.export = export
    }
}

/// The complete, non-destructive description of an edit. Source media is referenced, never modified.
public struct Project: Codable, Hashable, Sendable, Identifiable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var sources: [MediaSource]
    public var timeline: Timeline
    public var settings: ProjectSettings
    public var exportURL: URL?
    /// Set when the project was rebuilt from an interrupted recording.
    public var isRecovered: Bool

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), updatedAt: Date = Date(),
                sources: [MediaSource] = [], timeline: Timeline = Timeline(),
                settings: ProjectSettings = ProjectSettings(), exportURL: URL? = nil, isRecovered: Bool = false) {
        self.formatVersion = Self.currentFormatVersion
        self.id = id; self.name = name; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.sources = sources; self.timeline = timeline; self.settings = settings
        self.exportURL = exportURL; self.isRecovered = isRecovered
    }

    public func source(_ id: UUID) -> MediaSource? { sources.first { $0.id == id } }

    /// The file a project was first made from (the screen recording or imported video).
    public var originalMediaPath: String? { sources.first?.screen?.relativePath }

    public var duration: MediaTime { timeline.duration }

    /// Width / height of the primary source's picture.
    public var sourceAspect: Double {
        guard let file = sources.first(where: { $0.screen != nil })?.screen, file.pixelHeight > 0 else { return 16.0 / 9.0 }
        let crop = settings.screen.effectiveCrop
        return Double(file.pixelWidth) * crop.width / (Double(file.pixelHeight) * crop.height)
    }

    public var canvasAspect: Double { settings.aspect.value(sourceRatio: sourceAspect) }

    /// Builds a fresh project around one source: one clip covering it, plus linked tracks for what was recorded.
    public static func make(name: String, source: MediaSource, id: UUID = UUID()) -> Project {
        var tracks: [TimelineTrack] = []
        let clip = VideoClip(sourceID: source.id, sourceStart: .zero,
                             sourceEnd: MediaTime(seconds: source.duration), timelinePosition: .zero)
        tracks.append(TimelineTrack(name: "Screen", type: .video, clips: [clip]))
        if source.camera != nil { tracks.append(TimelineTrack(name: "Camera", type: .camera)) }
        if source.microphone != nil { tracks.append(TimelineTrack(name: "Microphone", type: .microphone)) }
        if source.systemAudio != nil || (source.screen?.hasAudio ?? false) {
            tracks.append(TimelineTrack(name: source.kind == .recording ? "System Audio" : "Audio", type: .systemAudio))
        }
        var settings = ProjectSettings()
        settings.aspect = AspectRatio(kind: .auto)
        settings.camera.isVisible = source.camera != nil
        if source.kind != .recording {
            settings.motion.autoZoomEnabled = false
            settings.cursor.isVisible = false
        }
        return Project(id: id, name: name, sources: [source], timeline: Timeline(tracks: tracks), settings: settings)
    }
}
