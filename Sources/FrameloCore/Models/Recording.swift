import Foundation

/// One media file on disk that belongs to a source. Paths are relative to the project package.
public struct MediaFile: Codable, Hashable, Sendable {
    public var relativePath: String
    /// Seconds between the session's time zero and this file's first sample (common host-clock timebase).
    public var startOffset: Double
    public var duration: Double
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var hasAudio: Bool
    /// Rate applied to this file to cancel measured clock drift against the screen video (1 = none).
    public var rateCorrection: Double

    public init(relativePath: String, startOffset: Double = 0, duration: Double = 0,
                pixelWidth: Int = 0, pixelHeight: Int = 0, hasAudio: Bool = false, rateCorrection: Double = 1) {
        self.relativePath = relativePath
        self.startOffset = startOffset
        self.duration = duration
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.hasAudio = hasAudio
        self.rateCorrection = rateCorrection
    }
}

/// Geometry of what was captured, needed to map cursor positions onto the video.
public struct CaptureInfo: Codable, Hashable, Sendable {
    /// Captured rectangle in global screen points, top-left origin.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var scale: Double

    public init(x: Double, y: Double, width: Double, height: Double, scale: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height; self.scale = scale
    }
}

/// A recording session (screen + optional camera, mic, system audio, cursor) or an imported file.
/// All files of one source share a single session timebase.
public struct MediaSource: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case recording, importedVideo, importedAudio }

    public var id: UUID
    public var kind: Kind
    public var name: String
    public var screen: MediaFile?
    public var camera: MediaFile?
    public var microphone: MediaFile?
    public var systemAudio: MediaFile?
    public var cursorPath: String?
    public var capture: CaptureInfo?
    /// Usable duration of the session in seconds.
    public var duration: Double
    public var createdAt: Date

    public init(id: UUID = UUID(), kind: Kind, name: String, screen: MediaFile? = nil, camera: MediaFile? = nil,
                microphone: MediaFile? = nil, systemAudio: MediaFile? = nil, cursorPath: String? = nil,
                capture: CaptureInfo? = nil, duration: Double, createdAt: Date = Date()) {
        self.id = id; self.kind = kind; self.name = name
        self.screen = screen; self.camera = camera; self.microphone = microphone; self.systemAudio = systemAudio
        self.cursorPath = cursorPath; self.capture = capture; self.duration = duration; self.createdAt = createdAt
    }
}

/// What the user asked to record.
public struct RecordingConfig: Codable, Hashable, Sendable {
    public enum Target: Codable, Hashable, Sendable {
        case display(id: UInt32)
        case window(id: UInt32)
        /// Region in the display's point coordinates, top-left origin.
        case region(displayID: UInt32, x: Double, y: Double, width: Double, height: Double)
    }

    public enum Resolution: String, Codable, Sendable, CaseIterable, Identifiable {
        case native, p1080, p720
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .native: "Native"
            case .p1080: "1080p"
            case .p720: "720p"
            }
        }
        public var maxHeight: Int? {
            switch self {
            case .native: nil
            case .p1080: 1080
            case .p720: 720
            }
        }
    }

    public var target: Target
    public var frameRate: Int
    public var resolution: Resolution
    public var captureSystemAudio: Bool
    public var captureMicrophone: Bool
    public var microphoneID: String?
    public var noiseReduction: Bool
    public var captureCamera: Bool
    public var cameraID: String?
    public var countdownSeconds: Int

    public init(target: Target, frameRate: Int = 60, resolution: Resolution = .native,
                captureSystemAudio: Bool = true, captureMicrophone: Bool = true, microphoneID: String? = nil,
                noiseReduction: Bool = false, captureCamera: Bool = false, cameraID: String? = nil,
                countdownSeconds: Int = 3) {
        self.target = target; self.frameRate = frameRate; self.resolution = resolution
        self.captureSystemAudio = captureSystemAudio; self.captureMicrophone = captureMicrophone
        self.microphoneID = microphoneID; self.noiseReduction = noiseReduction
        self.captureCamera = captureCamera; self.cameraID = cameraID; self.countdownSeconds = countdownSeconds
    }
}
