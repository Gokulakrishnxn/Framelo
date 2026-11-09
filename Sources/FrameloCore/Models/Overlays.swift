import Foundation

public struct TextOverlay: Codable, Hashable, Sendable, Identifiable {
    public enum Weight: String, Codable, Sendable, CaseIterable, Identifiable {
        case regular, medium, semibold, bold
        public var id: String { rawValue }
    }

    public var id: UUID
    public var text: String
    public var startTime: MediaTime
    public var endTime: MediaTime
    /// Centre, normalised to the canvas (top-left origin).
    public var positionX: Double
    public var positionY: Double
    /// Font size as a fraction of the canvas height.
    public var fontSize: Double
    public var weight: Weight
    public var color: RGBAColor
    public var backgroundColor: RGBAColor
    public var fadeDuration: Double

    public init(id: UUID = UUID(), text: String = "Text", startTime: MediaTime, endTime: MediaTime,
                positionX: Double = 0.5, positionY: Double = 0.14, fontSize: Double = 0.06,
                weight: Weight = .semibold, color: RGBAColor = .white,
                backgroundColor: RGBAColor = .clear, fadeDuration: Double = 0.25) {
        self.id = id; self.text = text; self.startTime = startTime; self.endTime = endTime
        self.positionX = positionX; self.positionY = positionY; self.fontSize = fontSize
        self.weight = weight; self.color = color; self.backgroundColor = backgroundColor
        self.fadeDuration = fadeDuration
    }

    public var range: MediaRange { MediaRange(start: startTime, end: endTime) }
}

public struct Caption: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var startTime: MediaTime
    public var endTime: MediaTime

    public init(id: UUID = UUID(), text: String, startTime: MediaTime, endTime: MediaTime) {
        self.id = id; self.text = text; self.startTime = startTime; self.endTime = endTime
    }

    public var range: MediaRange { MediaRange(start: startTime, end: endTime) }
}
