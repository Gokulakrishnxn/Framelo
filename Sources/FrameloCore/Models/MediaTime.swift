import CoreMedia
import Foundation

/// Exact, integer-based time used everywhere in the project model.
/// 60 000 ticks per second divides evenly by 24, 25, 30, 50, 60, 120 fps and by milliseconds,
/// so timeline arithmetic is deterministic and free of floating-point drift.
public struct MediaTime: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public static let timescale: Int64 = 60_000
    public static let zero = MediaTime(ticks: 0)

    public var ticks: Int64

    public init(ticks: Int64) { self.ticks = ticks }

    public init(seconds: Double) {
        self.ticks = seconds.isFinite ? Int64((seconds * Double(Self.timescale)).rounded()) : 0
    }

    public init(_ time: CMTime) {
        guard time.isNumeric else { self.ticks = 0; return }
        let converted = CMTimeConvertScale(time, timescale: CMTimeScale(Self.timescale), method: .roundHalfAwayFromZero)
        self.ticks = converted.value
    }

    public init(from decoder: Decoder) throws {
        self.ticks = try decoder.singleValueContainer().decode(Int64.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(ticks)
    }

    public var seconds: Double { Double(ticks) / Double(Self.timescale) }
    public var cmTime: CMTime { CMTime(value: ticks, timescale: CMTimeScale(Self.timescale)) }
    public var description: String { String(format: "%.4fs", seconds) }

    /// Divides by a speed factor, rounding to the nearest tick. The single place where rounding happens.
    public func divided(by factor: Double) -> MediaTime {
        MediaTime(ticks: Int64((Double(ticks) / factor).rounded()))
    }

    public func multiplied(by factor: Double) -> MediaTime {
        MediaTime(ticks: Int64((Double(ticks) * factor).rounded()))
    }

    public static func < (a: MediaTime, b: MediaTime) -> Bool { a.ticks < b.ticks }
    public static func + (a: MediaTime, b: MediaTime) -> MediaTime { MediaTime(ticks: a.ticks + b.ticks) }
    public static func - (a: MediaTime, b: MediaTime) -> MediaTime { MediaTime(ticks: a.ticks - b.ticks) }
    public static func += (a: inout MediaTime, b: MediaTime) { a.ticks += b.ticks }
    public static func -= (a: inout MediaTime, b: MediaTime) { a.ticks -= b.ticks }
}

/// Half-open time range `[start, end)`.
public struct MediaRange: Hashable, Sendable, Codable {
    public var start: MediaTime
    public var duration: MediaTime

    public init(start: MediaTime, duration: MediaTime) {
        self.start = start
        self.duration = duration
    }

    public init(start: MediaTime, end: MediaTime) {
        self.start = start
        self.duration = end - start
    }

    public var end: MediaTime { start + duration }
    public var isEmpty: Bool { duration.ticks <= 0 }
    public var cmRange: CMTimeRange { CMTimeRange(start: start.cmTime, duration: duration.cmTime) }

    public func contains(_ time: MediaTime) -> Bool { time >= start && time < end }

    public func overlaps(_ other: MediaRange) -> Bool {
        start < other.end && other.start < end && !isEmpty && !other.isEmpty
    }

    public func intersection(_ other: MediaRange) -> MediaRange? {
        let s = max(start, other.start)
        let e = min(end, other.end)
        return e > s ? MediaRange(start: s, end: e) : nil
    }
}
