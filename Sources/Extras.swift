// Press-and-slide keys, keyboard backlight, and keys that follow the app in front.
import AppKit

// MARK: - Press and slide

/// A key for volume or brightness. A quick tap opens the full slider panel; holding it
/// (or starting to move) turns the key itself into a slider: slide left or right to adjust.
final class HoldSlideKey: NSView {
    private let symbol: () -> String
    private let get: () -> Float
    private let set: (Float) -> Void
    private let onTap: () -> Void
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let fill = NSView()
    private var startX: CGFloat = 0
    private var startValue: Float = 0
    private var sliding = false
    private var holdTimer: Timer?
    private var refresh: Timer?
    /// Points of finger travel for the full 0–100 % range.
    private let travel: CGFloat = 240

    init(symbol: @escaping () -> String, get: @escaping () -> Float, set: @escaping (Float) -> Void, onTap: @escaping () -> Void) {
        self.symbol = symbol; self.get = get; self.set = set; self.onTap = onTap
        super.init(frame: NSRect(x: 0, y: 0, width: 60, height: 30))
        allowedTouchTypes = [.direct]
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.38, alpha: 1).cgColor
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 60).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true

        fill.wantsLayer = true
        fill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.28).cgColor
        fill.isHidden = true
        addSubview(fill)

        icon.contentTintColor = .white
        icon.imageScaling = .scaleProportionallyDown
        icon.frame = NSRect(x: 16, y: 3, width: 28, height: 24)
        addSubview(icon)

        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 6, width: 60, height: 18)
        label.isHidden = true
        addSubview(label)

        updateIcon()
        refresh = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self, !self.sliding else { return }
            self.updateIcon()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { refresh?.invalidate(); holdTimer?.invalidate() }

    private func updateIcon() {
        icon.image = NSImage(systemSymbolName: symbol(), accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium).applying(.init(paletteColors: [.white])))
    }

    private func show(_ v: Float) {
        label.stringValue = "\(Int((v * 100).rounded()))%"
        fill.frame = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(v), height: bounds.height)
    }

    private func beginSlide() {
        guard !sliding else { return }
        sliding = true
        holdTimer?.invalidate()
        icon.isHidden = true; label.isHidden = false; fill.isHidden = false
        show(startValue)
    }

    private func endSlide() {
        sliding = false
        icon.isHidden = false; label.isHidden = true; fill.isHidden = true
        updateIcon()
    }

    override func touchesBegan(with event: NSEvent) {
        guard let t = event.touches(matching: .began, in: self).first else { return }
        startX = t.location(in: self).x
        startValue = get()
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in self?.beginSlide() }
    }

    override func touchesMoved(with event: NSEvent) {
        guard let t = event.touches(matching: .moved, in: self).first else { return }
        let dx = t.location(in: self).x - startX
        if !sliding && abs(dx) > 6 { beginSlide() }
        guard sliding else { return }
        let v = max(0, min(1, startValue + Float(dx / travel)))
        set(v); show(v)
    }

    override func touchesEnded(with event: NSEvent) {
        holdTimer?.invalidate()
        if sliding { endSlide() } else { onTap() }
    }

    override func touchesCancelled(with event: NSEvent) {
        holdTimer?.invalidate()
        if sliding { endSlide() }
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
