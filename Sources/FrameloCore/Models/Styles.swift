import Foundation

public struct RGBAColor: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public init(hex: UInt32, alpha: Double = 1) {
        self.r = Double((hex >> 16) & 0xFF) / 255
        self.g = Double((hex >> 8) & 0xFF) / 255
        self.b = Double(hex & 0xFF) / 255
        self.a = alpha
    }

    public static let white = RGBAColor(r: 1, g: 1, b: 1)
    public static let black = RGBAColor(r: 0, g: 0, b: 0)
    public static let clear = RGBAColor(r: 0, g: 0, b: 0, a: 0)
}

public struct AspectRatio: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case auto, wide, standard, square, vertical, custom
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .auto: "Auto"
            case .wide: "16:9"
            case .standard: "4:3"
            case .square: "1:1"
            case .vertical: "9:16"
            case .custom: "Custom"
            }
        }
    }

    public var kind: Kind
    public var customWidth: Double
    public var customHeight: Double

    public init(kind: Kind = .wide, customWidth: Double = 16, customHeight: Double = 10) {
        self.kind = kind; self.customWidth = customWidth; self.customHeight = customHeight
    }

    /// Width / height. `sourceRatio` is used for `.auto`.
    public func value(sourceRatio: Double) -> Double {
        switch kind {
        case .auto: sourceRatio > 0 ? sourceRatio : 16.0 / 9.0
        case .wide: 16.0 / 9.0
        case .standard: 4.0 / 3.0
        case .square: 1
        case .vertical: 9.0 / 16.0
        case .custom: customHeight > 0 && customWidth > 0 ? customWidth / customHeight : 16.0 / 9.0
        }
    }
}

public struct BackgroundStyle: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case none, solid, gradient, image, wallpaper
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .none: "None"
            case .solid: "Solid"
            case .gradient: "Gradient"
            case .image: "Image"
            case .wallpaper: "Desktop"
            }
        }
    }

    public var kind: Kind
    public var color: RGBAColor
    public var gradientStart: RGBAColor
    public var gradientEnd: RGBAColor
    /// Degrees, 0 = left→right, 90 = top→bottom.
    public var gradientAngle: Double
    /// Absolute path of a custom image, or the wallpaper captured when chosen.
    public var imagePath: String?

    public init(kind: Kind = .gradient, color: RGBAColor = RGBAColor(hex: 0x1B1B1F),
                gradientStart: RGBAColor = RGBAColor(hex: 0x4F46E5), gradientEnd: RGBAColor = RGBAColor(hex: 0xC026D3),
                gradientAngle: Double = 45, imagePath: String? = nil) {
        self.kind = kind; self.color = color
        self.gradientStart = gradientStart; self.gradientEnd = gradientEnd
        self.gradientAngle = gradientAngle; self.imagePath = imagePath
    }
}

public struct ScreenStyle: Codable, Hashable, Sendable {
    public enum Frame: String, Codable, Sendable, CaseIterable, Identifiable {
        case none, window
        public var id: String { rawValue }
        public var displayName: String { self == .none ? "None" : "Window" }
    }

    /// Fraction of the canvas' shorter side left empty around the screen (0…0.3).
    public var padding: Double
    /// Corner radius as a fraction of the canvas' shorter side (0…0.1).
    public var cornerRadius: Double
    public var shadowOpacity: Double
    /// Shadow blur as a fraction of the canvas' shorter side.
    public var shadowRadius: Double
    public var frame: Frame

    public init(padding: Double = 0.07, cornerRadius: Double = 0.018, shadowOpacity: Double = 0.45,
                shadowRadius: Double = 0.04, frame: Frame = .none) {
        self.padding = padding; self.cornerRadius = cornerRadius
        self.shadowOpacity = shadowOpacity; self.shadowRadius = shadowRadius; self.frame = frame
    }
}

public struct CursorStyle: Codable, Hashable, Sendable {
    public enum ClickEffect: String, Codable, Sendable, CaseIterable, Identifiable {
        case none, ripple, ring
        public var id: String { rawValue }
        public var displayName: String { rawValue.capitalized }
    }

    public var isVisible: Bool
    public var size: Double
    /// 0 = raw recorded motion, 1 = heavily smoothed.
    public var smoothing: Double
    public var clickEffect: ClickEffect
    public var clickColor: RGBAColor
    /// Cursor shrinks slightly while a button is held.
    public var pressScale: Double
    public var hidesWhenIdle: Bool
    public var idleDelay: Double

    public init(isVisible: Bool = true, size: Double = 1.6, smoothing: Double = 0.55,
                clickEffect: ClickEffect = .ripple, clickColor: RGBAColor = RGBAColor(r: 1, g: 1, b: 1, a: 0.9),
                pressScale: Double = 0.85, hidesWhenIdle: Bool = false, idleDelay: Double = 3) {
        self.isVisible = isVisible; self.size = size; self.smoothing = smoothing
        self.clickEffect = clickEffect; self.clickColor = clickColor; self.pressScale = pressScale
        self.hidesWhenIdle = hidesWhenIdle; self.idleDelay = idleDelay
    }
}

public struct CameraStyle: Codable, Hashable, Sendable {
    public enum Shape: String, Codable, Sendable, CaseIterable, Identifiable {
        case circle, roundedRect
        public var id: String { rawValue }
        public var displayName: String { self == .circle ? "Circle" : "Rounded" }
    }

    public var isVisible: Bool
    public var shape: Shape
    /// Height as a fraction of the canvas height.
    public var size: Double
    /// Centre of the camera, normalised to the canvas (top-left origin).
    public var positionX: Double
    public var positionY: Double
    /// Corner radius as a fraction of the camera's height (rounded rectangle only).
    public var cornerRadius: Double
    public var borderWidth: Double
    public var borderColor: RGBAColor
    public var shadowOpacity: Double
    public var isMirrored: Bool
    /// Shown behind the camera picture where it does not cover its frame.
    public var backgroundColor: RGBAColor
    /// Camera shrinks to this factor while the screen is zoomed in (1 = no change).
    public var zoomedScale: Double

    public init(isVisible: Bool = true, shape: Shape = .circle, size: Double = 0.24,
                positionX: Double = 0.88, positionY: Double = 0.82, cornerRadius: Double = 0.2,
                borderWidth: Double = 0.012, borderColor: RGBAColor = RGBAColor(r: 1, g: 1, b: 1, a: 0.9),
                shadowOpacity: Double = 0.4, isMirrored: Bool = true,
                backgroundColor: RGBAColor = .black, zoomedScale: Double = 0.8) {
        self.isVisible = isVisible; self.shape = shape; self.size = size
        self.positionX = positionX; self.positionY = positionY; self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth; self.borderColor = borderColor; self.shadowOpacity = shadowOpacity
        self.isMirrored = isMirrored; self.backgroundColor = backgroundColor; self.zoomedScale = zoomedScale
    }
}

public struct MotionSettings: Codable, Hashable, Sendable {
    public var autoZoomEnabled: Bool
    public var defaultZoomScale: Double
    /// 0 = off, 1 = strong.
    public var motionBlur: Double
    public var zoomInDuration: Double
    public var zoomOutDuration: Double
    public var easing: Easing

    public init(autoZoomEnabled: Bool = true, defaultZoomScale: Double = 2, motionBlur: Double = 0.5,
                zoomInDuration: Double = 0.7, zoomOutDuration: Double = 0.8, easing: Easing = .easeInOut) {
        self.autoZoomEnabled = autoZoomEnabled; self.defaultZoomScale = defaultZoomScale
        self.motionBlur = motionBlur; self.zoomInDuration = zoomInDuration
        self.zoomOutDuration = zoomOutDuration; self.easing = easing
    }
}

public struct AudioSettings: Codable, Hashable, Sendable {
    /// Fades applied to the whole mix at the start and end of the timeline, in seconds.
    public var fadeIn: Double
    public var fadeOut: Double

    public init(fadeIn: Double = 0, fadeOut: Double = 0) {
        self.fadeIn = fadeIn; self.fadeOut = fadeOut
    }
}

public struct CaptionStyle: Codable, Hashable, Sendable {
    public var isVisible: Bool
    /// Font size as a fraction of the canvas height.
    public var fontSize: Double
    public var color: RGBAColor
    public var backgroundColor: RGBAColor
    /// Vertical centre of the caption, normalised to the canvas.
    public var positionY: Double

    public init(isVisible: Bool = true, fontSize: Double = 0.038, color: RGBAColor = .white,
                backgroundColor: RGBAColor = RGBAColor(r: 0, g: 0, b: 0, a: 0.65), positionY: Double = 0.9) {
        self.isVisible = isVisible; self.fontSize = fontSize; self.color = color
        self.backgroundColor = backgroundColor; self.positionY = positionY
    }
}

/// A named look: background + screen styling.
public struct StylePreset: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var background: BackgroundStyle
    public var screen: ScreenStyle

    public static let all: [StylePreset] = [
        StylePreset(id: "aurora", name: "Aurora",
                    background: BackgroundStyle(kind: .gradient, gradientStart: RGBAColor(hex: 0x4F46E5), gradientEnd: RGBAColor(hex: 0xC026D3), gradientAngle: 45),
                    screen: ScreenStyle()),
        StylePreset(id: "ocean", name: "Ocean",
                    background: BackgroundStyle(kind: .gradient, gradientStart: RGBAColor(hex: 0x0EA5E9), gradientEnd: RGBAColor(hex: 0x1E3A8A), gradientAngle: 60),
                    screen: ScreenStyle()),
        StylePreset(id: "sunset", name: "Sunset",
                    background: BackgroundStyle(kind: .gradient, gradientStart: RGBAColor(hex: 0xF97316), gradientEnd: RGBAColor(hex: 0xDB2777), gradientAngle: 30),
                    screen: ScreenStyle()),
        StylePreset(id: "forest", name: "Forest",
                    background: BackgroundStyle(kind: .gradient, gradientStart: RGBAColor(hex: 0x10B981), gradientEnd: RGBAColor(hex: 0x064E3B), gradientAngle: 70),
                    screen: ScreenStyle()),
        StylePreset(id: "graphite", name: "Graphite",
                    background: BackgroundStyle(kind: .solid, color: RGBAColor(hex: 0x18181B)),
                    screen: ScreenStyle(padding: 0.06, cornerRadius: 0.014, shadowOpacity: 0.6)),
        StylePreset(id: "paper", name: "Paper",
                    background: BackgroundStyle(kind: .solid, color: RGBAColor(hex: 0xF4F4F5)),
                    screen: ScreenStyle(padding: 0.08, cornerRadius: 0.02, shadowOpacity: 0.25)),
        StylePreset(id: "window", name: "Window",
                    background: BackgroundStyle(kind: .gradient, gradientStart: RGBAColor(hex: 0x334155), gradientEnd: RGBAColor(hex: 0x0F172A), gradientAngle: 90),
                    screen: ScreenStyle(padding: 0.08, frame: .window)),
        StylePreset(id: "clean", name: "Full Frame",
                    background: BackgroundStyle(kind: .none, color: .black),
                    screen: ScreenStyle(padding: 0, cornerRadius: 0, shadowOpacity: 0)),
    ]
}
