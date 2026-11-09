import Foundation

/// Interpolation curves for camera and keyframe motion. All map 0→0 and 1→1.
public enum Easing: String, Codable, Sendable, CaseIterable, Identifiable {
    case linear, easeIn, easeOut, easeInOut, spring

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .linear: "Linear"
        case .easeIn: "Ease In"
        case .easeOut: "Ease Out"
        case .easeInOut: "Ease In Out"
        case .spring: "Spring"
        }
    }

    public func value(_ t: Double) -> Double {
        let x = min(max(t, 0), 1)
        switch self {
        case .linear:
            return x
        case .easeIn:
            return x * x * x
        case .easeOut:
            let inv = 1 - x
            return 1 - inv * inv * inv
        case .easeInOut:
            // Quintic smootherstep: zero velocity and zero acceleration at both ends.
            return x * x * x * (x * (x * 6 - 15) + 10)
        case .spring:
            return Self.springValue(x) / Self.springEnd
        }
    }

    // Under-damped spring (ζ = 0.82): a small, quick overshoot that settles before t = 1.
    private static let zeta = 0.82
    private static let omega = 11.0
    private static let springEnd = springValue(1)

    private static func springValue(_ t: Double) -> Double {
        let wd = omega * (1 - zeta * zeta).squareRoot()
        let envelope = exp(-zeta * omega * t)
        return 1 - envelope * (cos(wd * t) + (zeta * omega / wd) * sin(wd * t))
    }
}

public func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
