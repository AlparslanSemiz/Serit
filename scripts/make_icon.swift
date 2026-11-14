// Renders Şerit's app icon (1024px PNG) to argv[1]. Original artwork, no SF Symbols:
// a glowing strip of colored segments on a dark keyboard-like tile.
import Cocoa

// swiftlint:disable:next identifier_name
let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor { NSColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a) }

let r = CGRect(x: 100, y: 100, width: S - 200, height: S - 200)
let shape = NSBezierPath(roundedRect: r, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor.black.setFill(); shape.fill()
ctx.restoreGState()
shape.addClip()
NSGradient(colors: [c(44, 46, 56), c(22, 23, 29)])!.draw(in: r, angle: -90)

// faint key caps below the strip
for row in 0..<2 {
    for col in 0..<5 {
        let k = CGRect(x: 168 + CGFloat(col) * 140, y: 230 + CGFloat(row) * 130, width: 118, height: 104)
        c(255, 255, 255, 0.06).setFill(); NSBezierPath(roundedRect: k, xRadius: 22, yRadius: 22).fill()
    }
}

// the strip
let strip = CGRect(x: 160, y: 600, width: 704, height: 130)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 70, color: c(120, 160, 255, 0.55).cgColor)
c(8, 8, 12).setFill(); NSBezierPath(roundedRect: strip, xRadius: 34, yRadius: 34).fill()
ctx.restoreGState()
c(255, 255, 255, 0.10).setStroke()
let border = NSBezierPath(roundedRect: strip, xRadius: 34, yRadius: 34); border.lineWidth = 4; border.stroke()

// segments: dock icons, a media pill, status
let segs: [(CGFloat, CGFloat, NSColor)] = [
    (188, 70, c(255, 112, 89)), (272, 70, c(255, 196, 77)), (356, 70, c(72, 214, 190)), (440, 70, c(130, 170, 255)),
    (548, 160, c(190, 120, 255)), (726, 110, c(240, 240, 245, 0.85)),
]
for (x, w, col) in segs {
    let seg = CGRect(x: x, y: strip.minY + 30, width: w, height: 70)
    col.setFill(); NSBezierPath(roundedRect: seg, xRadius: 18, yRadius: 18).fill()
}

// swiftlint:disable:next force_try
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
