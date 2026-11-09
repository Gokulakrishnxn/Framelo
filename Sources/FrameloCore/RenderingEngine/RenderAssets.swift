import AppKit
import CoreGraphics
import CoreText
import Foundation
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

    static func file(_ path: String) -> Bitmap? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return Bitmap.image(image)
    }
}

/// Vector-drawn pointer sprites, so the cursor stays sharp at any size.
enum CursorSprites {
    static let side = 256

    /// Hot spot of each sprite, normalised to the sprite box.
    static func hotspot(_ kind: CursorKind) -> CGPoint {
        switch kind {
        case .arrow: CGPoint(x: 0.18, y: 0.12)
        case .iBeam: CGPoint(x: 0.5, y: 0.5)
        case .pointingHand: CGPoint(x: 0.36, y: 0.12)
        }
    }

    static func bitmap(_ kind: CursorKind) -> Bitmap? {
        Bitmap.draw(width: side, height: side) { context in
            let s = CGFloat(side)
            context.setShadow(offset: CGSize(width: 0, height: -s * 0.02), blur: s * 0.05,
                              color: CGColor(gray: 0, alpha: 0.45))
            let path = CGMutablePath()
            switch kind {
            case .arrow:
                // Classic arrow, tip at the hot spot.
                let points: [(CGFloat, CGFloat)] = [(0.18, 0.12), (0.18, 0.76), (0.33, 0.62), (0.44, 0.87),
                                                    (0.55, 0.82), (0.44, 0.58), (0.65, 0.58)]
                path.addLines(between: points.map { CGPoint(x: $0.0 * s, y: $0.1 * s) })
                path.closeSubpath()
            case .iBeam:
                let cx = s * 0.5
                let top = s * 0.2, bottom = s * 0.8, serif = s * 0.1, stem = s * 0.025
                path.addRect(CGRect(x: cx - stem, y: top, width: stem * 2, height: bottom - top))
                path.addRect(CGRect(x: cx - serif, y: top - stem, width: serif * 2, height: stem * 2))
                path.addRect(CGRect(x: cx - serif, y: bottom - stem, width: serif * 2, height: stem * 2))
            case .pointingHand:
                // Simplified hand: an index finger above a rounded palm.
                path.addRoundedRect(in: CGRect(x: s * 0.30, y: s * 0.12, width: s * 0.12, height: s * 0.46),
                                    cornerWidth: s * 0.06, cornerHeight: s * 0.06)
                path.addRoundedRect(in: CGRect(x: s * 0.22, y: s * 0.44, width: s * 0.48, height: s * 0.40),
                                    cornerWidth: s * 0.12, cornerHeight: s * 0.12)
            }
            context.addPath(path)
            context.setLineJoin(.round)
            context.setLineWidth(s * 0.07)
            context.setStrokeColor(CGColor(gray: 1, alpha: 1))
            context.strokePath()
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.addPath(path)
            context.setFillColor(CGColor(gray: kind == .pointingHand ? 0.08 : 0, alpha: 1))
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
