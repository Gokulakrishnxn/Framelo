import Foundation

public enum CursorKind: String, Codable, Sendable, CaseIterable {
    case arrow, iBeam, pointingHand
}

/// Cursor position, normalised to the captured area (0…1, top-left origin). Time is session time in seconds.
public struct CursorSample: Codable, Hashable, Sendable {
    public var t: Double
    public var x: Double
    public var y: Double

    public init(t: Double, x: Double, y: Double) {
        self.t = t; self.x = x; self.y = y
    }
}

public struct ClickEvent: Codable, Hashable, Sendable {
    public var t: Double
    public var x: Double
    public var y: Double
    /// Time the button was released; equals `t` when unknown.
    public var releaseTime: Double

    public init(t: Double, x: Double, y: Double, releaseTime: Double? = nil) {
        self.t = t; self.x = x; self.y = y; self.releaseTime = releaseTime ?? t
    }
}

public struct CursorKindChange: Codable, Hashable, Sendable {
    public var t: Double
    public var kind: CursorKind

    public init(t: Double, kind: CursorKind) {
        self.t = t; self.kind = kind
    }
}

/// Everything recorded about the pointer during a session.
public struct CursorTrack: Codable, Hashable, Sendable {
    public var samples: [CursorSample]
    public var clicks: [ClickEvent]
    public var kinds: [CursorKindChange]

    public init(samples: [CursorSample] = [], clicks: [ClickEvent] = [], kinds: [CursorKindChange] = []) {
        self.samples = samples; self.clicks = clicks; self.kinds = kinds
    }

    public static let empty = CursorTrack()
    public var isEmpty: Bool { samples.isEmpty }

    /// Linear interpolation of the raw position at a session time.
    public func position(at time: Double) -> (x: Double, y: Double)? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if time <= first.t { return (first.x, first.y) }
        if time >= last.t { return (last.x, last.y) }
        var lo = 0
        var hi = samples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].t <= time { lo = mid } else { hi = mid }
        }
        let a = samples[lo]
        let b = samples[hi]
        let span = b.t - a.t
        let f = span > 0 ? (time - a.t) / span : 0
        return (lerp(a.x, b.x, f), lerp(a.y, b.y, f))
    }

    public func kind(at time: Double) -> CursorKind {
        var result = CursorKind.arrow
        for change in kinds {
            if change.t <= time { result = change.kind } else { break }
        }
        return result
    }

    // MARK: Line-delimited storage (append-only while recording, tolerant of a truncated last line)

    private struct Line: Codable {
        var k: String
        var t: Double
        var x: Double?
        var y: Double?
        var c: String?
    }

    public static func encodeMove(_ s: CursorSample) -> String { line(Line(k: "m", t: s.t, x: s.x, y: s.y)) }
    public static func encodeDown(t: Double, x: Double, y: Double) -> String { line(Line(k: "d", t: t, x: x, y: y)) }
    public static func encodeUp(t: Double) -> String { line(Line(k: "u", t: t)) }
    public static func encodeKind(t: Double, kind: CursorKind) -> String { line(Line(k: "c", t: t, c: kind.rawValue)) }

    private static func line(_ value: Line) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    public static func parse(jsonLines text: String) -> CursorTrack {
        var track = CursorTrack()
        let decoder = JSONDecoder()
        for raw in text.split(separator: "\n") {
            guard let line = try? decoder.decode(Line.self, from: Data(raw.utf8)) else { continue }
            switch line.k {
            case "m":
                if let x = line.x, let y = line.y { track.samples.append(CursorSample(t: line.t, x: x, y: y)) }
            case "d":
                if let x = line.x, let y = line.y { track.clicks.append(ClickEvent(t: line.t, x: x, y: y)) }
            case "u":
                if let last = track.clicks.indices.last, track.clicks[last].releaseTime == track.clicks[last].t {
                    track.clicks[last].releaseTime = max(line.t, track.clicks[last].t)
                }
            case "c":
                if let c = line.c, let kind = CursorKind(rawValue: c) {
                    track.kinds.append(CursorKindChange(t: line.t, kind: kind))
                }
            default:
                break
            }
        }
        track.samples.sort { $0.t < $1.t }
        track.clicks.sort { $0.t < $1.t }
        track.kinds.sort { $0.t < $1.t }
        return track
    }

    public static func load(from url: URL) -> CursorTrack {
        guard let data = try? Data(contentsOf: url) else { return .empty }
        return parse(jsonLines: String(decoding: data, as: UTF8.self))
    }
}
