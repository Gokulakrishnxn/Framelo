import Foundation

/// Where the virtual camera looks: `scale` ≥ 1, centre normalised to the screen content (top-left origin).
public struct CameraState: Sendable, Equatable {
    public var scale: Double
    public var centerX: Double
    public var centerY: Double

    public init(scale: Double = 1, centerX: Double = 0.5, centerY: Double = 0.5) {
        self.scale = scale; self.centerX = centerX; self.centerY = centerY
    }

    public static let identity = CameraState()

    /// Width (= height) of the visible part of the content, as a fraction of the whole.
    public var viewport: Double { 1 / max(scale, 1) }

    /// Interpolates the visible rectangle rather than the scale, which is what makes a zoom look like a
    /// straight push-in instead of a curve. The centre is clamped so the view never leaves the content.
    public static func interpolate(_ a: CameraState, _ b: CameraState, _ p: Double) -> CameraState {
        let width = lerp(a.viewport, b.viewport, p)
        return CameraState(scale: 1 / width, centerX: lerp(a.centerX, b.centerX, p), centerY: lerp(a.centerY, b.centerY, p))
            .clamped()
    }

    /// Keeps the viewport inside the content (no empty edges) and the scale in range.
    public func clamped() -> CameraState {
        let s = min(max(scale, 1), TimelineValidator.zoomScaleRange.upperBound)
        let half = 0.5 / s
        return CameraState(scale: s, centerX: min(max(centerX, half), 1 - half), centerY: min(max(centerY, half), 1 - half))
    }
}

/// A zoom event prepared for evaluation: clamped times and transitions, plus the path the camera follows while zoomed.
public struct ResolvedZoom: Sendable, Equatable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var scale: Double
    public var transitionIn: Double
    public var transitionOut: Double
    public var easing: Easing
    /// Camera target sampled at `CameraPath.followRate` from `start`. One entry when the target is fixed.
    public var targets: [SIMD2<Double>]

    func target(at time: Double) -> SIMD2<Double> {
        guard targets.count > 1 else { return targets.first ?? SIMD2(0.5, 0.5) }
        let position = max(0, (time - start) * CameraPath.followRate)
        let index = min(Int(position), targets.count - 2)
        let fraction = min(max(position - Double(index), 0), 1)
        return targets[index] + (targets[index + 1] - targets[index]) * fraction
    }

    /// 0 = fully zoomed out, 1 = fully zoomed in.
    func amount(at time: Double) -> Double {
        if time <= start || time >= end { return 0 }
        if time < start + transitionIn { return easing.value((time - start) / transitionIn) }
        if time > end - transitionOut { return 1 - easing.value((time - (end - transitionOut)) / transitionOut) }
        return 1
    }
}

/// A keyframe prepared for evaluation.
public struct ResolvedKeyframe: Sendable, Equatable {
    public var time: Double
    public var state: CameraState
    public var easing: Easing
}

/// The complete camera move for a timeline: random-access, deterministic, continuous.
public struct CameraPath: Sendable, Equatable {
    public static let followRate = 60.0
    /// Shortest transition allowed, so a zoom can never be an instant cut.
    public static let minimumTransition = 0.15
    /// Seconds of transition required per unit of zoom beyond 1×.
    public static let transitionPerScale = 0.25

    /// Shortest transition allowed for a zoom of the given scale: larger zooms must take longer.
    public static func minimumTransition(forScale scale: Double) -> Double {
        max(minimumTransition, transitionPerScale * (scale - 1))
    }

    /// Largest zoom whose minimum transition fits in `duration`.
    public static func maximumScale(forTransition duration: Double) -> Double {
        1 + max(duration, 0) / transitionPerScale
    }

    /// Lead-in / lead-out around a keyframed span.
    public static let keyframeLead = 0.6

    public var zooms: [ResolvedZoom]
    public var keyframes: [ResolvedKeyframe]

    public init(zooms: [ResolvedZoom] = [], keyframes: [ResolvedKeyframe] = []) {
        self.zooms = zooms
        self.keyframes = keyframes
    }

    public static let empty = CameraPath()

    /// Time span governed by keyframes (including lead-in and lead-out), if any.
    public var keyframeSpan: ClosedRange<Double>? {
        guard let first = keyframes.first, let last = keyframes.last else { return nil }
        return (first.time - Self.keyframeLead)...(last.time + Self.keyframeLead)
    }

    public func state(at time: Double) -> CameraState {
        if let span = keyframeSpan, span.contains(time) { return keyframeState(at: time) }
        guard let zoom = zoom(at: time) else { return .identity }
        let amount = zoom.amount(at: time)
        guard amount > 0 else { return .identity }
        let target = zoom.target(at: time)
        let zoomed = CameraState(scale: zoom.scale, centerX: target.x, centerY: target.y)
        return CameraState.interpolate(.identity, zoomed, amount)
    }

    private func zoom(at time: Double) -> ResolvedZoom? {
        var lo = 0
        var hi = zooms.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if time < zooms[mid].start {
                hi = mid - 1
            } else if time >= zooms[mid].end {
                lo = mid + 1
            } else {
                return zooms[mid]
            }
        }
        return nil
    }

    private func keyframeState(at time: Double) -> CameraState {
        guard let first = keyframes.first, let last = keyframes.last else { return .identity }
        if time < first.time {
            let p = Easing.easeInOut.value((time - (first.time - Self.keyframeLead)) / Self.keyframeLead)
            return CameraState.interpolate(.identity, first.state.clamped(), p)
        }
        if time >= last.time {
            let p = Easing.easeInOut.value((time - last.time) / Self.keyframeLead)
            return CameraState.interpolate(last.state.clamped(), .identity, p)
        }
        let next = keyframes.firstIndex { $0.time > time } ?? keyframes.count - 1
        let a = keyframes[max(0, next - 1)]
        let b = keyframes[next]
        let span = b.time - a.time
        let p = span > 0 ? b.easing.value((time - a.time) / span) : 1
        return CameraState.interpolate(a.state.clamped(), b.state.clamped(), p)
    }

    /// Camera velocity (per second) by central difference — drives motion blur.
    public func velocity(at time: Double, delta: Double = 1.0 / 120) -> (centerX: Double, centerY: Double, scale: Double) {
        let a = state(at: time - delta)
        let b = state(at: time + delta)
        let span = 2 * delta
        return ((b.centerX - a.centerX) / span, (b.centerY - a.centerY) / span, (b.scale - a.scale) / span)
    }
}
