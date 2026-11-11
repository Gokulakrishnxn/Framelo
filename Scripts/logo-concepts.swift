// Renders the Framelo logo concepts side by side for review.
// Usage: swift Scripts/logo-concepts.swift <output.png>
import AppKit

let tile: CGFloat = 512
let canvas = NSImage(size: NSSize(width: tile * 3 + 80, height: tile + 140))

func squircle(_ r: NSRect) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: r.width * 0.225, yRadius: r.width * 0.225) }

func outlined(_ path: NSBezierPath, width: CGFloat) {
    NSColor.white.setFill(); path.fill()
    NSColor.black.setStroke(); path.lineWidth = width; path.lineJoinStyle = .round; path.stroke()
}

/// A · "Framey": a friendly frame-shaped mascot with soft feet, dot eyes and a red record-dot nose.
func conceptA(_ r: NSRect) {
    NSColor(srgbRed: 1.0, green: 0.84, blue: 0.0, alpha: 1).setFill(); squircle(r).fill()
    let s = r.width
    let b = r.insetBy(dx: s * 0.2, dy: s * 0.22)
    let body = NSBezierPath()
    body.move(to: NSPoint(x: b.minX, y: b.minY + s * 0.08))
    body.line(to: NSPoint(x: b.minX, y: b.maxY - s * 0.14))
    body.curve(to: NSPoint(x: b.minX + s * 0.14, y: b.maxY),
               controlPoint1: NSPoint(x: b.minX, y: b.maxY - s * 0.04), controlPoint2: NSPoint(x: b.minX + s * 0.04, y: b.maxY))
    body.line(to: NSPoint(x: b.maxX - s * 0.14, y: b.maxY))
    body.curve(to: NSPoint(x: b.maxX, y: b.maxY - s * 0.14),
               controlPoint1: NSPoint(x: b.maxX - s * 0.04, y: b.maxY), controlPoint2: NSPoint(x: b.maxX, y: b.maxY - s * 0.04))
    body.line(to: NSPoint(x: b.maxX, y: b.minY + s * 0.08))
    let w = b.width / 3
    for i in 0..<3 {
        let x0 = b.maxX - CGFloat(i) * w
        body.curve(to: NSPoint(x: x0 - w, y: b.minY + s * 0.08),
                   controlPoint1: NSPoint(x: x0 - w * 0.1, y: b.minY - s * 0.04),
                   controlPoint2: NSPoint(x: x0 - w * 0.9, y: b.minY - s * 0.04))
    }
    body.close()
    outlined(body, width: s * 0.03)
    NSColor.black.setFill()
    for dx in [-0.09, 0.09] {
        NSBezierPath(ovalIn: NSRect(x: r.midX + s * dx - s * 0.03, y: r.midY + s * 0.04, width: s * 0.06, height: s * 0.075)).fill()
    }
    NSColor(srgbRed: 0.95, green: 0.2, blue: 0.25, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: r.midX - s * 0.035, y: r.midY - s * 0.08, width: s * 0.07, height: s * 0.07)).fill()
}

/// B · "Viewfinder": four bold corner brackets framing a record dot.
func conceptB(_ r: NSRect) {
    NSColor(srgbRed: 0.49, green: 0.36, blue: 1.0, alpha: 1).setFill(); squircle(r).fill()
    let s = r.width, f = r.insetBy(dx: s * 0.22, dy: s * 0.22), len = s * 0.17, t = s * 0.075
    for (cx, cy, sx, sy) in [(f.minX, f.minY, 1.0, 1.0), (f.maxX, f.minY, -1.0, 1.0), (f.minX, f.maxY, 1.0, -1.0), (f.maxX, f.maxY, -1.0, -1.0)] {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: cx, y: cy + CGFloat(sy) * len))
        p.line(to: NSPoint(x: cx, y: cy))
        p.line(to: NSPoint(x: cx + CGFloat(sx) * len, y: cy))
        p.lineWidth = t; p.lineCapStyle = .round; p.lineJoinStyle = .round
        NSColor.white.setStroke(); p.stroke()
    }
    let dot = s * 0.2
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: r.midX - dot / 2, y: r.midY - dot / 2, width: dot, height: dot)).fill()
}

/// C · "Blink": a little screen character with eyes and a smile.
func conceptC(_ r: NSRect) {
    NSColor(srgbRed: 0.0, green: 0.82, blue: 0.75, alpha: 1).setFill(); squircle(r).fill()
    let s = r.width
    outlined(NSBezierPath(roundedRect: r.insetBy(dx: s * 0.19, dy: s * 0.25), xRadius: s * 0.1, yRadius: s * 0.1), width: s * 0.03)
    outlined(NSBezierPath(roundedRect: NSRect(x: r.midX - s * 0.12, y: r.minY + s * 0.13, width: s * 0.24, height: s * 0.07),
                          xRadius: s * 0.035, yRadius: s * 0.035), width: s * 0.025)
    NSColor.black.setFill()
    for dx in [-0.1, 0.1] {
        NSBezierPath(ovalIn: NSRect(x: r.midX + s * dx - s * 0.03, y: r.midY + s * 0.03, width: s * 0.06, height: s * 0.08)).fill()
    }
    let smile = NSBezierPath()
    smile.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY - s * 0.02), radius: s * 0.08, startAngle: 200, endAngle: 340)
    smile.lineWidth = s * 0.025; smile.lineCapStyle = .round
    NSColor.black.setStroke(); smile.stroke()
}

canvas.lockFocus()
NSColor(white: 0.07, alpha: 1).setFill()
NSRect(origin: .zero, size: canvas.size).fill()
let labels = ["A · Framey (mascot)", "B · Viewfinder", "C · Blink (screen buddy)"]
for (i, draw) in [conceptA, conceptB, conceptC].enumerated() {
    let r = NSRect(x: 20 + CGFloat(i) * (tile + 20), y: 100, width: tile, height: tile)
    draw(r)
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.white]
    let text = labels[i] as NSString
    let size = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: r.midX - size.width / 2, y: 40), withAttributes: attrs)
}
canvas.unlockFocus()
let rep = NSBitmapImageRep(data: canvas.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
