import Foundation

/// A manual camera keyframe. Between the first and last keyframe the camera follows keyframes
/// instead of zoom events. `easing` shapes the move that arrives at this keyframe.
public struct MotionKeyframe: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var timestamp: MediaTime
    public var scale: Double
    public var positionX: Double
    public var positionY: Double
    public var easing: Easing

    public init(id: UUID = UUID(), timestamp: MediaTime, scale: Double = 1,
                positionX: Double = 0.5, positionY: Double = 0.5, easing: Easing = .easeInOut) {
        self.id = id; self.timestamp = timestamp; self.scale = scale
        self.positionX = positionX; self.positionY = positionY; self.easing = easing
    }
}
