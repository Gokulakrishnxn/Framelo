import Foundation

/// Durable record of a recording session, rewritten atomically as the session progresses.
/// If the app dies, this file plus the fragmented media files are enough to rebuild the project.
public struct RecordingJournal: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case preparing, recording, paused, finalizing, complete, failed
    }

    public enum TrackKind: String, Codable, Sendable, CaseIterable {
        case screen, systemAudio, microphone, camera

        public var fileName: String {
            switch self {
            case .screen: "screen.mov"
            case .systemAudio: "system-audio.mov"
            case .microphone: "microphone.mov"
            case .camera: "camera.mov"
            }
        }

        public var relativePath: String { "\(ProjectPackage.mediaDirectory)/\(fileName)" }
    }

    public struct Track: Codable, Sendable, Equatable {
        public var kind: TrackKind
        public var relativePath: String
        /// Session time of the first sample; `nil` until the first sample is written.
        public var startOffset: Double?
        /// Measured clock drift correction for this track (1 = none).
        public var rateCorrection: Double?
    }

    public var id: UUID
    public var name: String
    public var state: State
    public var config: RecordingConfig
    public var capture: CaptureInfo?
    public var startedAt: Date
    public var heartbeat: Date
    public var tracks: [Track]
    public var failureReason: String?

    public init(id: UUID, name: String, config: RecordingConfig, startedAt: Date = Date()) {
        self.id = id; self.name = name; self.state = .preparing; self.config = config
        self.capture = nil; self.startedAt = startedAt; self.heartbeat = startedAt
        self.tracks = []; self.failureReason = nil
    }

    public mutating func setOffset(_ offset: Double, for kind: TrackKind) {
        if let index = tracks.firstIndex(where: { $0.kind == kind }) {
            tracks[index].startOffset = offset
        } else {
            tracks.append(Track(kind: kind, relativePath: kind.relativePath, startOffset: offset, rateCorrection: nil))
        }
    }

    public func track(_ kind: TrackKind) -> Track? { tracks.first { $0.kind == kind } }

    // MARK: Disk

    public static func url(in package: URL) -> URL { package.appendingPathComponent(ProjectPackage.sessionFile) }

    public func write(to package: URL) throws {
        let data = try ProjectStore.makeEncoder().encode(self)
        try data.write(to: Self.url(in: package), options: .atomic)
    }

    public static func read(from package: URL) throws -> RecordingJournal {
        try ProjectStore.makeDecoder().decode(RecordingJournal.self, from: Data(contentsOf: url(in: package)))
    }
}
