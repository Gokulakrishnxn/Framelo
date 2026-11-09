import Foundation

/// A camera zoom on the timeline. Targets are normalised to the screen content (0…1, top-left origin).
public struct ZoomEvent: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var startTime: MediaTime
    public var endTime: MediaTime
    public var scale: Double
    public var targetX: Double
    public var targetY: Double
    public var easing: Easing
    /// `true` while the event is an untouched automatic suggestion. Any user edit makes it manual.
    public var isAutomatic: Bool
    /// When on, the camera follows the smoothed cursor while zoomed in.
    public var followsCursor: Bool
    public var transitionIn: Double
    public var transitionOut: Double

    public init(id: UUID = UUID(), startTime: MediaTime, endTime: MediaTime, scale: Double = 2,
                targetX: Double = 0.5, targetY: Double = 0.5, easing: Easing = .easeInOut,
                isAutomatic: Bool = false, followsCursor: Bool = true,
                transitionIn: Double = 0.7, transitionOut: Double = 0.8) {
        self.id = id; self.startTime = startTime; self.endTime = endTime
        self.scale = scale; self.targetX = targetX; self.targetY = targetY
        self.easing = easing; self.isAutomatic = isAutomatic; self.followsCursor = followsCursor
        self.transitionIn = transitionIn; self.transitionOut = transitionOut
    }

    public var range: MediaRange { MediaRange(start: startTime, end: endTime) }
    public var duration: MediaTime { endTime - startTime }
}
