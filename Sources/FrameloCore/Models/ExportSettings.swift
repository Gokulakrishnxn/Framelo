import Foundation

public struct ExportSettings: Codable, Hashable, Sendable {
    public enum Container: String, Codable, Sendable, CaseIterable, Identifiable {
        case mp4, mov
        public var id: String { rawValue }
        public var displayName: String { rawValue.uppercased() }
        public var fileExtension: String { rawValue }
    }

    public enum Codec: String, Codable, Sendable, CaseIterable, Identifiable {
        case h264, hevc
        public var id: String { rawValue }
        public var displayName: String { self == .h264 ? "H.264" : "HEVC" }
    }

    public enum Resolution: String, Codable, Sendable, CaseIterable, Identifiable {
        case p720, p1080, p2160
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .p720: "720p"
            case .p1080: "1080p"
            case .p2160: "4K"
            }
        }
        /// Length of the canvas' shorter side in pixels.
        public var shortSide: Int {
            switch self {
            case .p720: 720
            case .p1080: 1080
            case .p2160: 2160
            }
        }
    }

    public enum Quality: String, Codable, Sendable, CaseIterable, Identifiable {
        case standard, high, maximum
        public var id: String { rawValue }
        public var displayName: String { rawValue.capitalized }
        /// Bits per pixel per frame for H.264; HEVC uses ~60 % of this.
        var bitsPerPixel: Double {
            switch self {
            case .standard: 0.07
            case .high: 0.12
            case .maximum: 0.2
            }
        }
    }

    public var container: Container
    public var codec: Codec
    public var resolution: Resolution
    public var frameRate: Int
    public var quality: Quality

    public init(container: Container = .mp4, codec: Codec = .h264, resolution: Resolution = .p1080,
                frameRate: Int = 60, quality: Quality = .high) {
        self.container = container; self.codec = codec; self.resolution = resolution
        self.frameRate = frameRate; self.quality = quality
    }

    /// Even-sized pixel dimensions for a canvas of the given aspect ratio (width / height).
    public func canvasSize(aspect: Double) -> (width: Int, height: Int) {
        Self.canvasSize(shortSide: resolution.shortSide, aspect: aspect)
    }

    public static func canvasSize(shortSide: Int, aspect: Double) -> (width: Int, height: Int) {
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        let a = aspect > 0 ? aspect : 16.0 / 9.0
        if a >= 1 {
            return (even(Double(shortSide) * a), even(Double(shortSide)))
        }
        return (even(Double(shortSide)), even(Double(shortSide) / a))
    }

    public func videoBitRate(width: Int, height: Int) -> Int {
        let codecFactor = codec == .hevc ? 0.6 : 1.0
        let bits = Double(width * height) * Double(frameRate) * quality.bitsPerPixel * codecFactor
        return max(1_000_000, Int(bits))
    }

    public static let audioBitRate = 192_000

    /// Estimated output size in bytes.
    public func estimatedFileSize(width: Int, height: Int, duration: Double, hasAudio: Bool) -> Int64 {
        let bits = Double(videoBitRate(width: width, height: height)) + (hasAudio ? Double(Self.audioBitRate) : 0)
        return Int64(bits * max(duration, 0) / 8)
    }
}
