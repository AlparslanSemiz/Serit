// Press-and-slide keys, keyboard backlight, and keys that follow the app in front.
import AppKit

// MARK: - Press and slide

/// A key for volume or brightness. A quick tap opens the full slider panel. Holding it
/// (or starting to move) grows the key into a compact slider right where it is: slide left
/// or right to adjust, lift to let it shrink back.
final class HoldSlideKey: NSView {
    private let symbol: () -> String
    private let get: () -> Float
    private let set: (Float) -> Void
    private let onTap: () -> Void

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let track = CALayer()
    private let trackFill = CALayer()
    private let knob = CALayer()
    private var width: NSLayoutConstraint!

    private var startX: CGFloat = 0
    private var startValue: Float = 0
    private var value: Float = 0
    private var sliding = false
    private var holdTimer: Timer?
    private var refresh: Timer?

    private let restWidth: CGFloat = 60
    private let openWidth: CGFloat = 230
    /// Points of finger travel for the full 0–100 % range.
    private let travel: CGFloat = 200

    init(symbol: @escaping () -> String, get: @escaping () -> Float, set: @escaping (Float) -> Void, onTap: @escaping () -> Void) {
        self.symbol = symbol; self.get = get; self.set = set; self.onTap = onTap
        super.init(frame: NSRect(x: 0, y: 0, width: 60, height: 30))
        allowedTouchTypes = [.direct]
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.36, alpha: 1).cgColor
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        width = widthAnchor.constraint(equalToConstant: restWidth); width.isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true

        track.backgroundColor = NSColor(white: 1, alpha: 0.22).cgColor
        track.cornerRadius = 2.5
        trackFill.backgroundColor = NSColor.white.cgColor
        trackFill.cornerRadius = 2.5
        knob.backgroundColor = NSColor.white.cgColor
        knob.cornerRadius = 8
        knob.shadowOpacity = 0.35; knob.shadowRadius = 2; knob.shadowOffset = CGSize(width: 0, height: -1)
        for l in [track, trackFill, knob] { l.opacity = 0; layer?.addSublayer(l) }

        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)

        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.alignment = .right
        label.alphaValue = 0
        addSubview(label)

        updateIcon()
        refresh = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, !self.sliding else { return }
            self.updateIcon()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { refresh?.invalidate(); holdTimer?.invalidate() }

    override func layout() {
        super.layout()
        let w = bounds.width
        // Icon slides from the centre (at rest) to the left edge (open).
        let iconW: CGFloat = 26
        icon.frame = NSRect(x: sliding ? 8 : (w - iconW) / 2, y: 3, width: iconW, height: 24)
        label.frame = NSRect(x: w - 50, y: 6, width: 42, height: 18)
        placeTrack(animated: false)
    }

    private func placeTrack(animated: Bool) {
        let w = bounds.width
        let x0: CGFloat = 42, x1 = w - 56
        let tw = max(0, x1 - x0)
        let y = bounds.midY - 2.5
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.08)
        track.frame = CGRect(x: x0, y: y, width: tw, height: 5)
        trackFill.frame = CGRect(x: x0, y: y, width: tw * CGFloat(value), height: 5)
        knob.frame = CGRect(x: x0 + tw * CGFloat(value) - 8, y: bounds.midY - 8, width: 16, height: 16)
        CATransaction.commit()
    }

    private func updateIcon() {
        icon.image = NSImage(systemSymbolName: symbol(), accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium).applying(.init(paletteColors: [.white])))
    }

    private func show(_ v: Float, animated: Bool = true) {
        value = v
        label.stringValue = "\(Int((v * 100).rounded()))%"
        updateIcon()
        placeTrack(animated: animated)
    }

    private func setOpen(_ open: Bool) {
        sliding = open
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = open ? 0.18 : 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)   // quick out, soft settle
            ctx.allowsImplicitAnimation = true
            width.animator().constant = open ? openWidth : restWidth
            label.animator().alphaValue = open ? 1 : 0
            superview?.layoutSubtreeIfNeeded()
            layoutSubtreeIfNeeded()
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(open ? 0.18 : 0.12)
        for l in [track, trackFill, knob] { l.opacity = open ? 1 : 0 }
        layer?.backgroundColor = NSColor(white: open ? 0.30 : 0.36, alpha: 1).cgColor
        CATransaction.commit()
    }

    /// Test hook: show the open state without a finger.
    func debugHold(_ on: Bool) { if on { startValue = get(); beginSlide() } else { setOpen(false) } }

    private func beginSlide() {
        guard !sliding else { return }
        holdTimer?.invalidate()
        value = startValue
        setOpen(true)
        show(startValue, animated: false)
    }

    override func touchesBegan(with event: NSEvent) {
        guard let t = event.touches(matching: .began, in: self).first else { return }
        startX = t.location(in: self).x
        startValue = get()
        // Press feedback before anything else happens.
        CATransaction.begin(); CATransaction.setAnimationDuration(0.08)
        layer?.backgroundColor = NSColor(white: 0.46, alpha: 1).cgColor
        CATransaction.commit()
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: false) { [weak self] _ in self?.beginSlide() }
    }

    override func touchesMoved(with event: NSEvent) {
        guard let t = event.touches(matching: .moved, in: self).first else { return }
        let dx = t.location(in: self).x - startX
        if !sliding && abs(dx) > 5 { beginSlide() }
        guard sliding else { return }
        let v = max(0, min(1, startValue + Float(dx / travel)))
        set(v); show(v)
    }

    override func touchesEnded(with event: NSEvent) {
        holdTimer?.invalidate()
        if sliding {
            // Linger a moment on the final value, then fold back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.setOpen(false) }
        } else {
            CATransaction.begin(); CATransaction.setAnimationDuration(0.15)
            layer?.backgroundColor = NSColor(white: 0.36, alpha: 1).cgColor
            CATransaction.commit()
            onTap()
        }
    }

    override func touchesCancelled(with event: NSEvent) {
        holdTimer?.invalidate()
        if sliding { setOpen(false) }
        layer?.backgroundColor = NSColor(white: 0.36, alpha: 1).cgColor
    }
}

// MARK: - Keyboard backlight (private CoreBrightness)

enum KeyboardBacklight {
    private static let loaded: Bool = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil
    private static let client: NSObject? = {
        guard loaded, let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        return cls.init()
    }()
    private static var keyboardID: UInt64 {
        guard let c = client else { return 1 }
        let sel = NSSelectorFromString("copyKeyboardBacklightIDs")
        guard c.responds(to: sel), let ids = c.perform(sel)?.takeRetainedValue() as? [NSNumber], let first = ids.first else { return 1 }
        return first.uint64Value
    }
    static var available: Bool {
        guard let c = client else { return false }
        return c.responds(to: NSSelectorFromString("brightnessForKeyboard:"))
            && c.responds(to: NSSelectorFromString("setBrightness:forKeyboard:"))
    }
    static var level: Float {
        get {
            guard let c = client, available else { return 0 }
            let sel = NSSelectorFromString("brightnessForKeyboard:")
            typealias F = @convention(c) (AnyObject, Selector, UInt64) -> Float
            return unsafeBitCast(c.method(for: sel), to: F.self)(c, sel, keyboardID)
        }
        set {
            guard let c = client, available else { return }
            let sel = NSSelectorFromString("setBrightness:forKeyboard:")
            typealias F = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
            _ = unsafeBitCast(c.method(for: sel), to: F.self)(c, sel, max(0, min(1, newValue)), keyboardID)
        }
    }
}

// MARK: - Keys for the app in front

enum KeyPress {
    /// Sends a shortcut to the frontmost app (the Touch Bar never takes focus away from it).
    static func send(_ key: CGKeyCode, _ flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }
}

final class AppKeys: NSObject {
    static let id = NSTouchBarItem.Identifier("local.serit.appkeys")
    static let widthChanged = Notification.Name("SeritAppKeysWidth")

    struct Key { let symbol: String; let key: CGKeyCode; let flags: CGEventFlags }
    private static let browser: [Key] = [
        Key(symbol: "chevron.backward", key: 33, flags: .maskCommand),          // ⌘[
        Key(symbol: "chevron.forward", key: 30, flags: .maskCommand),           // ⌘]
        Key(symbol: "arrow.clockwise", key: 15, flags: .maskCommand),           // ⌘R
        Key(symbol: "plus", key: 17, flags: .maskCommand),                      // ⌘T
    ]
    private static let editor: [Key] = [
        Key(symbol: "play.fill", key: 96, flags: []),                           // F5
        Key(symbol: "stop.fill", key: 96, flags: .maskShift),                   // ⇧F5
        Key(symbol: "terminal", key: 50, flags: .maskControl),                  // ⌃`
        Key(symbol: "command", key: 35, flags: [.maskCommand, .maskShift]),     // ⇧⌘P
    ]
    static let profiles: [String: [Key]] = [
        "com.brave.Browser": browser, "com.google.Chrome": browser, "com.apple.Safari": browser,
        "company.thebrowser.Browser": browser, "org.mozilla.firefox": browser, "com.microsoft.edgemac": browser,
        "com.microsoft.VSCode": editor, "com.todesktop.230313mzl4w4u92": editor, "com.exafunction.windsurf": editor,
    ]

    private let stack = NSStackView()
    private var current: [Key] = []

    func makeItem() -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: Self.id)
        stack.spacing = 4
        item.view = stack
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(update),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
        update()
        return item
    }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    @objc private func update() {
        let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let keys = Self.profiles[bid] ?? []
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        current = keys
        for (i, k) in keys.enumerated() {
            let b = TB.button(k.symbol, width: 44, bright: false, target: self, action: #selector(press(_:)))
            b.tag = i
            stack.addArrangedSubview(b)
        }
        let width: CGFloat = keys.isEmpty ? 0 : CGFloat(keys.count) * 48 + 8
        NotificationCenter.default.post(name: Self.widthChanged, object: nil, userInfo: ["width": width])
    }

    @objc private func press(_ b: NSButton) {
        guard b.tag < current.count else { return }
        let k = current[b.tag]
        KeyPress.send(k.key, k.flags)
    }
}
