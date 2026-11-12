// Press-and-slide keys, keyboard backlight, and keys that follow the app in front.
import AppKit

// MARK: - Press and slide

/// A key for volume or brightness, modelled on Pock's sliders. A quick tap opens the full
/// panel. Holding the key opens a slider right on top of it, centred on the key, without
/// moving anything else on the strip; the knob follows the finger one to one and the
/// slider folds back into the key shortly after the finger lifts.
final class HoldSlideKey: NSView {
    private let symbol: () -> String
    private let get: () -> Float
    private let set: (Float) -> Void
    private let onTap: () -> Void

    private let background = CALayer()
    private let icon = NSImageView()
    // the slider that floats over the key
    private let overlay = NSView()
    private let minIcon = NSImageView()
    private let maxIcon = NSImageView()
    private let track = CALayer()
    private let trackFill = CALayer()
    private let knob = CALayer()

    /// The view the slider spreads over (the whole control group). Falls back to the key.
    weak var overlayHost: NSView?

    private var startX: CGFloat = 0
    private var startValue: Float = 0
    private var value: Float = 0
    private(set) var sliding = false
    private var holdTimer: Timer?
    private var refresh: Timer?
    private var closeWork: DispatchWorkItem?

    private let keyWidth: CGFloat = 70
    private let inset: CGFloat = 36
    private var sliderWidth: CGFloat { overlay.bounds.width > 0 ? overlay.bounds.width : 240 }
    private var trackWidth: CGFloat { max(40, sliderWidth - 2 * inset) }

    static let curve = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)

    init(symbol: @escaping () -> String, minSymbol: String, maxSymbol: String,
         get: @escaping () -> Float, set: @escaping (Float) -> Void, onTap: @escaping () -> Void) {
        self.symbol = symbol; self.get = get; self.set = set; self.onTap = onTap
        super.init(frame: NSRect(x: 0, y: 0, width: 70, height: 30))
        allowedTouchTypes = [.direct]
        wantsLayer = true
        layer?.masksToBounds = false                    // the slider is drawn beyond the key
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: keyWidth).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true

        background.backgroundColor = NSColor(white: 0.36, alpha: 1).cgColor
        background.cornerRadius = 7
        layer?.addSublayer(background)

        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)

        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor(white: 0.22, alpha: 1).cgColor
        overlay.layer?.cornerRadius = 8
        overlay.layer?.borderWidth = 1
        overlay.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        overlay.alphaValue = 0
        overlay.isHidden = true

        track.backgroundColor = NSColor(white: 1, alpha: 0.22).cgColor
        track.cornerRadius = 3
        trackFill.backgroundColor = NSColor.white.cgColor
        trackFill.cornerRadius = 3
        knob.backgroundColor = NSColor.white.cgColor
        knob.cornerRadius = 11
        knob.shadowOpacity = 0.4; knob.shadowRadius = 3; knob.shadowOffset = CGSize(width: 0, height: -1)
        for l in [track, trackFill, knob] { overlay.layer?.addSublayer(l) }
        for (v, name) in [(minIcon, minSymbol), (maxIcon, maxSymbol)] {
            v.imageScaling = .scaleProportionallyDown
            v.image = Self.white(name, size: 14)
            overlay.addSubview(v)
        }

        updateIcon()
        refresh = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, !self.sliding else { return }
            self.updateIcon()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { refresh?.invalidate(); holdTimer?.invalidate() }

    private static func white(_ name: String, size: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .medium).applying(.init(paletteColors: [.white])))
    }
    private func updateIcon() { icon.image = Self.white(symbol(), size: 17) }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        background.frame = bounds
        CATransaction.commit()
        icon.frame = NSRect(x: (bounds.width - 26) / 2, y: 3, width: 26, height: 24)
    }

    private func layoutOverlay() {
        let host = overlayHost ?? self
        if overlay.superview !== host { host.addSubview(overlay, positioned: .above, relativeTo: nil) }
        overlay.frame = host.bounds
        minIcon.frame = NSRect(x: 8, y: 5, width: 22, height: 20)
        maxIcon.frame = NSRect(x: overlay.bounds.width - 32, y: 5, width: 24, height: 20)
        placeTrack()
    }

    private func placeTrack() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)        // the knob sticks to the finger, no lag
        let y = bounds.midY - 3
        track.frame = CGRect(x: inset, y: y, width: trackWidth, height: 6)
        trackFill.frame = CGRect(x: inset, y: y, width: trackWidth * CGFloat(value), height: 6)
        knob.frame = CGRect(x: inset + trackWidth * CGFloat(value) - 11, y: bounds.midY - 11, width: 22, height: 22)
        CATransaction.commit()
    }

    private func setOpen(_ open: Bool) {
        sliding = open
        closeWork?.cancel()
        guard let ol = overlay.layer else { return }
        if open { layoutOverlay(); overlay.isHidden = false }
        // Grow out of the pressed key, then settle over the whole group.
        let host = overlay.superview ?? self
        let keyCenter = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: host)
        let scale = CATransform3DMakeScale(bounds.width / max(1, overlay.bounds.width), 1, 1)
        let shift = CATransform3DMakeTranslation(keyCenter.x - overlay.frame.midX, 0, 0)
        let from = CATransform3DConcat(scale, shift)
        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = open ? from : CATransform3DIdentity
        anim.toValue = open ? CATransform3DIdentity : from
        anim.duration = open ? 0.32 : 0.26
        anim.timingFunction = Self.curve
        ol.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ol.position = CGPoint(x: overlay.frame.midX, y: overlay.frame.midY)
        ol.transform = open ? CATransform3DIdentity : from
        ol.add(anim, forKey: "grow")
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = open ? 0.22 : 0.26
            ctx.timingFunction = Self.curve
            overlay.animator().alphaValue = open ? 1 : 0
            icon.animator().alphaValue = open ? 0 : 1
        }, completionHandler: { [weak self] in
            guard let self, !self.sliding else { return }
            self.overlay.isHidden = true
            self.overlay.layer?.transform = CATransform3DIdentity
        })
        CATransaction.begin(); CATransaction.setAnimationDuration(0.2)
        background.backgroundColor = NSColor(white: 0.36, alpha: 1).cgColor
        CATransaction.commit()
    }

    /// Test hook: show the open state without a finger.
    func debugHold(_ on: Bool) { if on { startValue = get(); beginSlide() } else { setOpen(false) } }

    private func beginSlide() {
        guard !sliding else { return }
        holdTimer?.invalidate()
        value = startValue
        layoutOverlay()
        setOpen(true)
    }

    override func touchesBegan(with event: NSEvent) {
        guard let t = event.touches(matching: .began, in: self).first else { return }
        closeWork?.cancel()
        startX = t.location(in: self).x
        startValue = sliding ? value : get()
        if !sliding {
            CATransaction.begin(); CATransaction.setAnimationDuration(0.1)
            background.backgroundColor = NSColor(white: 0.48, alpha: 1).cgColor
            CATransaction.commit()
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in self?.beginSlide() }
        }
    }

    override func touchesMoved(with event: NSEvent) {
        guard let t = event.touches(matching: .moved, in: self).first else { return }
        let dx = t.location(in: self).x - startX
        if !sliding && abs(dx) > 4 { beginSlide() }
        guard sliding else { return }
        value = max(0, min(1, startValue + Float(dx / trackWidth)))
        set(value)
        placeTrack()
    }

    override func touchesEnded(with event: NSEvent) {
        holdTimer?.invalidate()
        if sliding {
            let w = DispatchWorkItem { [weak self] in self?.setOpen(false); self?.updateIcon() }
            closeWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: w)
        } else {
            CATransaction.begin(); CATransaction.setAnimationDuration(0.2)
            background.backgroundColor = NSColor(white: 0.36, alpha: 1).cgColor
            CATransaction.commit()
            onTap()
        }
    }

    override func touchesCancelled(with event: NSEvent) {
        holdTimer?.invalidate()
        if sliding { setOpen(false) }
        background.backgroundColor = NSColor(white: 0.36, alpha: 1).cgColor
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
