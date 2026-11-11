// Draws the Framelo app icon at every size macOS needs and writes an .iconset folder.
// Usage: swift Scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func draw(_ pixels: Int) -> Data? {
    let s = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // macOS icon grid: the tile fills ~80 % of the canvas.
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let t = tile.width
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    NSColor(srgbRed: 0.0, green: 0.82, blue: 0.75, alpha: 1).setFill()
    NSBezierPath(roundedRect: tile, xRadius: t * 0.225, yRadius: t * 0.225).fill()
    NSShadow().set()
    // The Framelo mark: a bold, outlined screen on a stand.
    func outlined(_ path: NSBezierPath, _ width: CGFloat) {
        NSColor.white.setFill(); path.fill()
        NSColor.black.setStroke(); path.lineWidth = width; path.lineJoinStyle = .round; path.stroke()
    }
    let screen = NSRect(x: tile.minX + t * 0.19, y: tile.minY + t * 0.27, width: t * 0.62, height: t * 0.46)
    outlined(NSBezierPath(roundedRect: screen, xRadius: t * 0.1, yRadius: t * 0.1), t * 0.035)
    let stand = NSRect(x: tile.midX - t * 0.12, y: tile.minY + t * 0.13, width: t * 0.24, height: t * 0.075)
    outlined(NSBezierPath(roundedRect: stand, xRadius: t * 0.0375, yRadius: t * 0.0375), t * 0.03)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(base * scale)?.write(to: output.appendingPathComponent(name))
    }
}
