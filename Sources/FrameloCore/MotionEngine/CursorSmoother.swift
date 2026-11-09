import Foundation

/// Zero-phase cursor smoothing: a Gaussian-weighted average of the raw path around the requested time.
/// Being symmetric in time it adds no lag, so the smoothed cursor still rests exactly on click targets,
/// and being a pure function of time it gives identical results in preview and export.
public enum CursorSmoother {
    /// Widest smoothing window (standard deviation, seconds) at `smoothing == 1`.
    static let maxSigma = 0.09
    static let step = 1.0 / 120

    public static func position(in track: CursorTrack, at time: Double, smoothing: Double) -> (x: Double, y: Double)? {
        guard let raw = track.position(at: time) else { return nil }
        let sigma = min(max(smoothing, 0), 1) * maxSigma
        guard sigma > 0.002 else { return raw }
        let radius = Int((sigma * 2.5 / step).rounded(.up))
        var sumX = 0.0
        var sumY = 0.0
        var total = 0.0
        for k in -radius...radius {
            let offset = Double(k) * step
            guard let p = track.position(at: time + offset) else { continue }
            let weight = exp(-(offset * offset) / (2 * sigma * sigma))
            sumX += p.x * weight
            sumY += p.y * weight
            total += weight
        }
        return total > 0 ? (sumX / total, sumY / total) : raw
    }

    /// Time since the pointer last moved noticeably, looking back at most `limit` seconds.
    public static func idleTime(in track: CursorTrack, at time: Double, limit: Double) -> Double {
        guard let now = track.position(at: time) else { return 0 }
        var back = 0.1
        while back <= limit {
            guard let then = track.position(at: time - back) else { break }
            if abs(then.x - now.x) > 0.002 || abs(then.y - now.y) > 0.002 { return back - 0.1 }
            back += 0.1
        }
        return limit
    }
}
