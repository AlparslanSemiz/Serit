import AppKit

/// The whole bar as one item.
///
/// macOS lays out separate Touch Bar items by their fitting widths and silently drops
/// items once they add up to more than the bar. That is how the bar used to "shrink":
/// a longer title, an event or the browser keys pushed it over, an item vanished and the
/// rest slid left. As one fixed-width view nothing can be dropped; Auto Layout squeezes
/// the parts that can give (dock scrolls, title scrolls, event title truncates) instead.
///
/// Panels (the ‹ controls, volume, brightness) open inside the same view with our own
/// slide, so they line up with the home row and the animation is ours to tune.
final class MainBarView: NSView {
    static let id = NSTouchBarItem.Identifier("local.serit.main")

    let barWidth: CGFloat
    private let home = NSView()
    private let rightStack = NSStackView()
    private var appKeysView: NSView?
    private var appKeysHiddenForSpace = false
    private(set) var panel: NSView?
    private var panelTimeout: DispatchWorkItem?
    private var lastLayoutReport = ""

    /// Slide timing: unhurried and soft at both ends.
    static let duration: TimeInterval = 0.45
    static let timing = CAMediaTimingFunction(controlPoints: 0.32, 0.0, 0.18, 1.0)
    /// Gap between groups, also used by panels so both rows share one rhythm.
    static let groupSpacing: CGFloat = 12

    init(width: CGFloat, left: [NSView], appKeys: NSView?, right: [NSView]) {
        barWidth = width
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true

        home.frame = bounds
        home.autoresizingMask = [.width, .height]
        home.wantsLayer = true
        addSubview(home)

        appKeysView = appKeys
        leftViews = left
        rightStack.orientation = .horizontal
        rightStack.spacing = Self.groupSpacing
        rightStack.alignment = .centerY
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        right.forEach { rightStack.addArrangedSubview($0) }
        home.addSubview(rightStack)
        rightStack.setHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            rightStack.trailingAnchor.constraint(equalTo: home.trailingAnchor),
            rightStack.centerYAnchor.constraint(equalTo: home.centerYAnchor),
        ])
        arrangeLeft(showKeys: true)
    }

    /// The left side is chained by hand (no stack view): dock at the edge, then the app keys,
    /// and the last one must end before the right group. The dock gives way (it scrolls).
    private var leftViews: [NSView] = []
    private var leftConstraints: [NSLayoutConstraint] = []
    private var keysShown = false
    private func arrangeLeft(showKeys: Bool) {
        NSLayoutConstraint.deactivate(leftConstraints)
        leftConstraints = []
        var views = leftViews
        if let k = appKeysView {
            if showKeys { views.append(k) } else { k.removeFromSuperview() }
        }
        keysShown = showKeys && appKeysView != nil
        var previous: NSView?
        for v in views {
            if v.superview !== home { v.translatesAutoresizingMaskIntoConstraints = false; home.addSubview(v) }
            leftConstraints.append(v.centerYAnchor.constraint(equalTo: home.centerYAnchor))
            leftConstraints.append(previous.map { v.leadingAnchor.constraint(equalTo: $0.trailingAnchor, constant: Self.groupSpacing) }
                                   ?? v.leadingAnchor.constraint(equalTo: home.leadingAnchor))
            previous = v
        }
        if let last = previous {
            leftConstraints.append(last.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -Self.groupSpacing))
        }
        NSLayoutConstraint.activate(leftConstraints)
    }
    private var leftMaxX: CGFloat { ([leftViews.last, keysShown ? appKeysView : nil].compactMap { $0 }.map(\.frame.maxX)).max() ?? 0 }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: barWidth, height: 30) }

    override func layout() {
        super.layout()
        balanceAppKeys()
        reportLayout()
    }

    /// The per-app keys are the first thing to go when the bar is full, and come back
    /// once there is room again. Half a key is worse than none.
    private func balanceAppKeys() {
        guard let win = window, win.frame.width > 0, panel == nil,
              let keys = appKeysView, let dock = leftViews.first else { return }
        let keysWidth = keys.fittingSize.width
        var show: Bool?
        if keysShown {
            if keysWidth > 0, dock.frame.width < 140 { show = false }   // the dock was squeezed below three icons
        } else if appKeysHiddenForSpace {
            let free = rightStack.frame.minX - leftMaxX - Self.groupSpacing
            if free > keysWidth + Self.groupSpacing || keysWidth == 0 { show = true }
        }
        guard let show else { return }
        // Not inside layout(): rearranging mid-pass leaves the Touch Bar with a stale picture.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.keysShown != show else { return }
            self.arrangeLeft(showKeys: show)
            self.appKeysHiddenForSpace = !show
            log("layout: browser keys \(show ? "back" : "hidden, no room")")
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }
    }

    /// One log line whenever the arrangement changes, so a broken bar can be read back later.
    private func reportLayout() {
        func w(_ v: NSView) -> String { v.isHidden ? "hidden" : "\(Int(v.frame.width))" }
        var parts = ["bar=\(Int(barWidth))", "window=\(window.map { "\(Int($0.frame.width))" } ?? "none")"]
        let keys = appKeysView.map { ",keys=" + (keysShown ? "\(Int($0.frame.width))" : "hidden") } ?? ""
        parts.append("left=[" + leftViews.map(w).joined(separator: ",") + keys + "]")
        parts.append("right=[" + rightStack.arrangedSubviews.map(w).joined(separator: ",") + "]")
        parts.append("free=\(Int(rightStack.frame.minX - leftMaxX))")
        if let p = panel { parts.append("panel=\(Int(p.frame.width))") }
        let report = parts.joined(separator: " ")
        if report != lastLayoutReport {
            lastLayoutReport = report
            log("layout: \(report)")
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        log("layout: main bar \(window == nil ? "left the Touch Bar" : "on the Touch Bar, window \(Int(window!.frame.width)) pt")")
        // The first layout happens before the Touch Bar has sized its window; report again once it has.
        if window != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                self.needsLayout = true
                self.layoutSubtreeIfNeeded()
                self.lastLayoutReport = ""
                self.reportLayout()
            }
        }
    }

    // MARK: panels

    func show(_ view: NSView, autoClose: TimeInterval? = nil) {
        panelTimeout?.cancel()
        if let old = panel {
            old.removeFromSuperview()
        }
        panel = view
        view.frame = bounds.offsetBy(dx: bounds.width * 0.3, dy: 0)
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.alphaValue = 0
        addSubview(view)
        home.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.duration
            ctx.timingFunction = Self.timing
            ctx.allowsImplicitAnimation = true
            view.animator().frame = bounds
            view.animator().alphaValue = 1
            home.animator().frame = bounds.offsetBy(dx: -bounds.width * 0.3, dy: 0)
            home.animator().alphaValue = 0
        } completionHandler: { [weak self, weak view] in
            guard let self, let view, self.panel === view else { return }
            self.home.isHidden = true
        }
        if let autoClose { touch(autoClose: autoClose) }
    }

    /// Keeps an auto-closing panel open while it's being used.
    func touch(autoClose: TimeInterval) {
        guard panel != nil else { return }
        panelTimeout?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.closePanel() }
        panelTimeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + autoClose, execute: w)
    }

    func closePanel(animated: Bool = true) {
        panelTimeout?.cancel()
        guard let view = panel else { return }
        panel = nil
        home.isHidden = false
        guard animated else {
            view.removeFromSuperview(); home.frame = bounds; home.alphaValue = 1; return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Self.duration
            ctx.timingFunction = Self.timing
            ctx.allowsImplicitAnimation = true
            view.animator().frame = bounds.offsetBy(dx: bounds.width * 0.3, dy: 0)
            view.animator().alphaValue = 0
            home.animator().frame = bounds
            home.animator().alphaValue = 1
        } completionHandler: { [weak view] in
            view?.removeFromSuperview()
        }
    }

    /// A panel row laid out like the home row: groups spread evenly from the left edge,
    /// and the close key exactly where the ‹ key sits, same size, same look.
    static func panelRow(_ groups: [NSView], close: NSButton) -> NSView {
        let row = NSView()
        let content = NSStackView(views: groups)
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = groupSpacing
        content.distribution = groups.count > 1 ? .equalSpacing : .fill
        content.translatesAutoresizingMaskIntoConstraints = false
        close.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(content); row.addSubview(close)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
            content.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            content.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -groupSpacing * 2),
            close.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            close.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }
}
