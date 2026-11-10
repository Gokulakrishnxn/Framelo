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
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.set()
    let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(starting: NSColor(srgbRed: 0.55, green: 0.42, blue: 1, alpha: 1),
               ending: NSColor(srgbRed: 0.33, green: 0.2, blue: 0.93, alpha: 1))?.draw(in: shape, angle: -60)
    NSShadow().set()
    let frame = tile.insetBy(dx: tile.width * 0.22, dy: tile.width * 0.22)
    let ring = NSBezierPath(roundedRect: frame, xRadius: frame.width * 0.16, yRadius: frame.width * 0.16)
    ring.lineWidth = tile.width * 0.07
    NSColor.white.setStroke()
    ring.stroke()
    let dot = tile.width * 0.15
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: tile.midX - dot / 2, y: tile.midY - dot / 2, width: dot, height: dot)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try draw(base * scale)?.write(to: output.appendingPathComponent(name))
    }
}
