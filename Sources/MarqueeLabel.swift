import AppKit

/// A one-line label that scrolls when its text doesn't fit: it waits a moment at the
/// start, glides left at a reading pace, and loops seamlessly. Short text just sits still.
final class MarqueeLabel: NSView {
    var maxWidth: CGFloat = 170 { didSet { invalidateIntrinsicContentSize() } }
    var font = NSFont.systemFont(ofSize: 12, weight: .medium) { didSet { rebuild() } }
    var textColor: NSColor = .white { didSet { for l in [first, second] { l.foregroundColor = textColor.cgColor } } }
    var text = "" { didSet { if text != oldValue { rebuild() } } }
    /// True while the text is wider than the label and scrolling.
    private(set) var isScrolling = false

    private let strip = CALayer()
    private let first = CATextLayer()
    private let second = CATextLayer()
    private let fade = CAGradientLayer()
    private var textWidth: CGFloat = 0
    private let gap: CGFloat = 36
    private let speed: CGFloat = 28      // points per second
    private let pause: CFTimeInterval = 1.8

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(strip)
        for l in [first, second] {
            l.contentsScale = 2
            l.alignmentMode = .left
            l.truncationMode = .none
            l.isWrapped = false
            strip.addSublayer(l)
        }
        fade.startPoint = CGPoint(x: 0, y: 0.5); fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: min(ceil(textWidth), maxWidth), height: 16) }

    private func rebuild() {
        textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        for l in [first, second] {
            l.string = text
            l.font = font
            l.fontSize = font.pointSize
            l.foregroundColor = textColor.cgColor
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let h = ceil(font.ascender - font.descender) + 1
        let y = (bounds.height - h) / 2
        first.frame = CGRect(x: 0, y: y, width: ceil(textWidth) + 2, height: h)
        second.frame = CGRect(x: ceil(textWidth) + gap, y: y, width: ceil(textWidth) + 2, height: h)
        strip.frame = CGRect(x: 0, y: 0, width: (ceil(textWidth) + gap) * 2, height: bounds.height)
        CATransaction.commit()

        let needs = textWidth > bounds.width + 0.5 && bounds.width > 0
        second.isHidden = !needs
        if needs != isScrolling || (needs && strip.animation(forKey: "marquee") == nil) {
            isScrolling = needs
            strip.removeAnimation(forKey: "marquee")
            if needs { startScrolling() } else { layer?.mask = nil }
        }
        if needs {
            fade.frame = bounds
            let edge = NSNumber(value: Double(min(0.12, 10 / max(bounds.width, 1))))
            fade.locations = [0, edge, NSNumber(value: 1 - edge.doubleValue), 1]
            layer?.mask = fade
        }
    }

    private func startScrolling() {
        let distance = ceil(textWidth) + gap
        let travel = CFTimeInterval(distance / speed)
        let total = pause + travel
        let a = CAKeyframeAnimation(keyPath: "position.x")
        let x0 = strip.position.x
        a.values = [x0, x0, x0 - distance]
        a.keyTimes = [0, NSNumber(value: pause / total), 1]
        a.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .linear)]
        a.duration = total
        a.repeatCount = .infinity
        strip.add(a, forKey: "marquee")
    }
}
