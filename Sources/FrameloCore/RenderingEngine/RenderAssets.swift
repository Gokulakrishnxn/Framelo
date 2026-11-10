import AppKit
import CoreGraphics
import CoreText
import Foundation
import CoreImage
import ImageIO

/// A bitmap with premultiplied alpha, ready to upload as a BGRA texture.
struct Bitmap {
    var width: Int
    var height: Int
    var bytes: [UInt8]

    /// Draws into a BGRA premultiplied context whose origin is at the top-left.
    static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> Bitmap? {
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ok = bytes.withUnsafeMutableBytes { pointer -> Bool in
            guard let context = CGContext(data: pointer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: info) else { return false }
            // Flip so drawing code can use top-left coordinates like the rest of the renderer.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            body(context)
            return true
        }
        return ok ? Bitmap(width: width, height: height, bytes: bytes) : nil
    }

    static func image(_ image: CGImage, maxSide: Int = 4096) -> Bitmap? {
        let scale = min(1, CGFloat(maxSide) / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        return draw(width: width, height: height) { context in
            // Images are bottom-up in Core Graphics: undo the flip for the draw call.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Loads an image file, downscaled to at most 2560 px, optionally blurred (`blur` 0…1).
    static func file(_ path: String, blur: Double = 0) -> Bitmap? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 2560,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              var image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        if blur > 0 {
            let input = CIImage(cgImage: image)
            let radius = blur * Double(max(image.width, image.height)) * 0.02
            let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: input.extent)
            if let output = CIContext().createCGImage(blurred, from: input.extent) { image = output }
        }
        return Bitmap.image(image)
    }
}

/// Pointer sprites drawn from the system's own cursor artwork (vector/high-resolution representations),
/// rendered large so they stay sharp at any zoom. Falls back to a drawn arrow if a cursor image is unavailable.
enum CursorSprites {
    static let side = 256

    private struct Sprite {
        var bitmap: Bitmap
        var hotspot: CGPoint
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [CursorKind: Sprite] = [:]

    private static func systemCursor(_ kind: CursorKind) -> NSCursor {
        switch kind {
        case .arrow: .arrow
        case .iBeam: .iBeam
        case .pointingHand: .pointingHand
        }
    }

    private static func sprite(_ kind: CursorKind) -> Sprite? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[kind] { return cached }
        let cursor = systemCursor(kind)
        let image = cursor.image
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        // The sprite box is square; the cursor image is scaled to fill it by its longer side.
        let scale = CGFloat(side) / max(size.width, size.height)
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        guard let bitmap = Bitmap.draw(width: side, height: side, { context in
            // Undo the top-left flip: AppKit draws images bottom-up.
            context.translateBy(x: 0, y: CGFloat(side))
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: CGRect(x: 0, y: CGFloat(side) - drawn.height, width: drawn.width, height: drawn.height))
            NSGraphicsContext.restoreGraphicsState()
        }) else { return nil }
        let hotspot = CGPoint(x: cursor.hotSpot.x * scale / CGFloat(side), y: cursor.hotSpot.y * scale / CGFloat(side))
        let sprite = Sprite(bitmap: bitmap, hotspot: hotspot)
        cache[kind] = sprite
        return sprite
    }

    /// Hot spot of each sprite, normalised to the sprite box (top-left origin).
    static func hotspot(_ kind: CursorKind) -> CGPoint {
        sprite(kind)?.hotspot ?? CGPoint(x: 0.18, y: 0.12)
    }

    static func bitmap(_ kind: CursorKind) -> Bitmap? {
        sprite(kind)?.bitmap ?? fallbackArrow()
    }

    private static func fallbackArrow() -> Bitmap? {
        Bitmap.draw(width: side, height: side) { context in
            let s = CGFloat(side)
            let points: [(CGFloat, CGFloat)] = [(0.18, 0.12), (0.18, 0.76), (0.33, 0.62), (0.44, 0.87),
                                                (0.55, 0.82), (0.44, 0.58), (0.65, 0.58)]
            let path = CGMutablePath()
            path.addLines(between: points.map { CGPoint(x: $0.0 * s, y: $0.1 * s) })
            path.closeSubpath()
            context.addPath(path)
            context.setLineWidth(s * 0.07)
            context.setStrokeColor(CGColor(gray: 1, alpha: 1))
            context.strokePath()
            context.addPath(path)
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fillPath()
        }
    }
}

/// Rasterises text overlays and captions.
enum TextRasterizer {
    struct Spec: Hashable {
        var text: String
        var fontSize: CGFloat          // pixels
        var weight: TextOverlay.Weight
        var color: RGBAColor
        var background: RGBAColor
        var maxWidth: CGFloat          // pixels
    }

    static func bitmap(_ spec: Spec) -> Bitmap? {
        guard !spec.text.isEmpty, spec.fontSize >= 1 else { return nil }
        let weight: NSFont.Weight = switch spec.weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
        let font = NSFont.systemFont(ofSize: spec.fontSize, weight: weight) as CTFont
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(srgbRed: spec.color.r, green: spec.color.g, blue: spec.color.b, alpha: spec.color.a),
            .paragraphStyle: paragraph,
        ]
        let string = NSAttributedString(string: spec.text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let padX = spec.background.a > 0 ? spec.fontSize * 0.55 : spec.fontSize * 0.1
        let padY = spec.background.a > 0 ? spec.fontSize * 0.32 : spec.fontSize * 0.1
        let limit = CGSize(width: max(spec.maxWidth - padX * 2, spec.fontSize), height: .greatestFiniteMagnitude)
        let textSize = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, limit, nil)
        let width = Int((textSize.width + padX * 2).rounded(.up))
        let height = Int((textSize.height + padY * 2).rounded(.up))

        return Bitmap.draw(width: width, height: height) { context in
            if spec.background.a > 0 {
                let rect = CGRect(x: 0, y: 0, width: width, height: height)
                let radius = min(spec.fontSize * 0.4, CGFloat(height) / 2)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.setFillColor(CGColor(srgbRed: spec.background.r, green: spec.background.g,
                                             blue: spec.background.b, alpha: spec.background.a))
                context.fillPath()
            }
            // Core Text draws bottom-up: flip back for the text frame.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            let frameRect = CGRect(x: padX, y: padY, width: CGFloat(width) - padX * 2, height: CGFloat(height) - padY * 2)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: frameRect, transform: nil), nil)
            CTFrameDraw(frame, context)
        }
    }
}
