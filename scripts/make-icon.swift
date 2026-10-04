// Draws Relay's app icon into an .iconset folder. Usage: swift make-icon.swift <out.iconset>
import AppKit

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(white: 0.16, alpha: 1), NSColor(white: 0.05, alpha: 1)])!.draw(in: bg, angle: -90)
    NSColor(white: 1, alpha: 0.12).setStroke()
    bg.lineWidth = s * 0.006
    bg.stroke()
    // White speech bubble with two eyes.
    let bw = rect.width * 0.56, bh = rect.width * 0.44
    let bubble = NSRect(x: rect.midX - bw / 2, y: rect.midY - bh / 2 + rect.width * 0.03, width: bw, height: bh)
    let path = NSBezierPath(roundedRect: bubble, xRadius: bh * 0.42, yRadius: bh * 0.42)
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: bubble.minX + bw * 0.22, y: bubble.minY + bh * 0.1))
    tail.line(to: NSPoint(x: bubble.minX + bw * 0.12, y: bubble.minY - bh * 0.22))
    tail.line(to: NSPoint(x: bubble.minX + bw * 0.42, y: bubble.minY + bh * 0.05))
    tail.close()
    NSColor.white.setFill()
    path.fill()
    tail.fill()
    NSColor(white: 0.08, alpha: 1).setFill()
    let eye = bh * 0.17
    for dx in [-0.16, 0.16] {
        let c = NSPoint(x: bubble.midX + bw * dx, y: bubble.midY + bh * 0.02)
        NSBezierPath(ovalIn: NSRect(x: c.x - eye / 2, y: c.y - eye / 2, width: eye, height: eye * 1.25)).fill()
    }
    // Amber "asking" dot.
    let d = rect.width * 0.17
    let dot = NSRect(x: bubble.maxX - d * 0.55, y: bubble.maxY - d * 0.55, width: d, height: d)
    NSColor(red: 0.91, green: 0.69, blue: 0.29, alpha: 1).setFill()
    NSBezierPath(ovalIn: dot).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
