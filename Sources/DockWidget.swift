import AppKit
import ApplicationServices

/// One app in the Touch Bar dock: icon, running dot, active highlight, badge.
final class DockTile: NSButton {
    let bundleID: String
    let appURL: URL
    private let dot = NSView()
    private let badge = NSTextField(labelWithString: "")
    private let badgeBG = NSView()

    init(bundleID: String, url: URL, icon: NSImage) {
        self.bundleID = bundleID; self.appURL = url
        super.init(frame: NSRect(x: 0, y: 0, width: 44, height: 30))
        let img = icon.copy() as! NSImage
        img.size = NSSize(width: 24, height: 24)
        image = img
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 44).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        dot.layer?.cornerRadius = 1.5
        dot.frame = NSRect(x: 20.5, y: 0.5, width: 3, height: 3)
        addSubview(dot)

        badgeBG.wantsLayer = true
        badgeBG.layer?.backgroundColor = NSColor.systemRed.cgColor
        badgeBG.layer?.cornerRadius = 6.5
        addSubview(badgeBG)
        badge.font = .systemFont(ofSize: 9, weight: .bold)
        badge.textColor = .white
        badge.alignment = .center
        badgeBG.addSubview(badge)
        setBadge(nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setRunning(_ running: Bool, active: Bool) {
        // Fade the dot and the active highlight instead of snapping.
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        dot.layer?.opacity = running ? 1 : 0
        layer?.backgroundColor = active ? NSColor.white.withAlphaComponent(0.18).cgColor : NSColor.clear.cgColor
        CATransaction.commit()
    }

    func setBadge(_ text: String?) {
        guard let text, !text.isEmpty else { badgeBG.isHidden = true; return }
        badgeBG.isHidden = false
        let shown = text.count > 3 ? "99+" : text
        badge.stringValue = shown
        let w = max(13, CGFloat(shown.count) * 6 + 6)
        badgeBG.frame = NSRect(x: 44 - w - 2, y: 30 - 13 - 0.5, width: w, height: 13)
        badge.frame = NSRect(x: 0, y: -1, width: w, height: 13)
    }
}

/// Pinned Dock apps first (in Dock order), then any other running app.
final class DockWidget: NSObject {
    static let id = NSTouchBarItem.Identifier("local.serit.dock")
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var tiles: [String: DockTile] = [:]
    private var badgeTimer: Timer?
    private var widthConstraint: NSLayoutConstraint?
    private var maxConstraint: NSLayoutConstraint?

    func makeItem() -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: Self.id)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.heightAnchor.constraint(equalToConstant: 30).isActive = true
        // Pin the icons to the start of the scroll area; unpinned, they drifted out of view
        // whenever the dock was resized and the dock looked empty.
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 30),
        ])
        // As wide as its icons when there is room. The main bar squeezes it (and it scrolls)
        // when the other widgets need the space, down to two icons.
        widthConstraint = scroll.widthAnchor.constraint(equalToConstant: 200)
        widthConstraint?.priority = NSLayoutConstraint.Priority(250)
        widthConstraint?.isActive = true
        maxConstraint = scroll.widthAnchor.constraint(lessThanOrEqualToConstant: 200)
        maxConstraint?.isActive = true
        let minimum = scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 96)
        minimum.priority = NSLayoutConstraint.Priority(750)
        minimum.isActive = true
        item.view = scroll
        item.visibilityPriority = .high

        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                  NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                  NSWorkspace.didUnhideApplicationNotification] {
            nc.addObserver(self, selector: #selector(reload), name: n, object: nil)
        }
        reload()
        if Settings.shared.dockBadges {
            badgeTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.refreshBadges() }
            refreshBadges()
        }
        return item
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        badgeTimer?.invalidate()
    }

    private func pinnedApps() -> [(String, URL)] {
        guard Settings.shared.dockPinned,
              let dock = UserDefaults(suiteName: "com.apple.dock"),
              let apps = dock.array(forKey: "persistent-apps") as? [[String: Any]] else { return [] }
        return apps.compactMap { tile in
            guard let data = tile["tile-data"] as? [String: Any],
                  let bid = data["bundle-identifier"] as? String,
                  let fd = data["file-data"] as? [String: Any],
                  let s = fd["_CFURLString"] as? String else { return nil }
            let url = s.hasPrefix("file://") ? URL(string: s) : URL(fileURLWithPath: s)
            return url.map { (bid, $0) }
        }
    }

    @objc func reload() {
        let s = Settings.shared
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var order: [(String, URL)] = pinnedApps()
        var seen = Set(order.map { $0.0 })
        for app in running {
            guard let bid = app.bundleIdentifier, let url = app.bundleURL, !seen.contains(bid) else { continue }
            order.append((bid, url)); seen.insert(bid)
        }
        if s.dockHideFinder { order.removeAll { $0.0 == "com.apple.finder" } }
        else if !order.contains(where: { $0.0 == "com.apple.finder" }) {
            order.insert(("com.apple.finder", URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")), at: 0)
        }

        let runningIDs = Set(running.compactMap { $0.bundleIdentifier })
        var newTiles: [String: DockTile] = [:]
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (bid, url) in order {
            let tile = tiles[bid] ?? {
                let t = DockTile(bundleID: bid, url: url, icon: NSWorkspace.shared.icon(forFile: url.path))
                t.target = self; t.action = #selector(tap(_:))
                return t
            }()
            tile.setRunning(runningIDs.contains(bid), active: bid == front)
            newTiles[bid] = tile
            stack.addArrangedSubview(tile)
        }
        tiles = newTiles
        let content = CGFloat(order.count) * 46 + 4
        widthConstraint?.constant = content
        maxConstraint?.constant = content
    }

    @objc private func tap(_ t: DockTile) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: t.bundleID)
        if let app = apps.first {
            if app.isActive && Settings.shared.dockTapFrontmostHides && t.bundleID != "com.apple.finder" {
                app.hide()
            } else {
                app.unhide()
                app.activate()
                // An app with no windows (e.g. after closing them) needs a reopen event to show one.
                NSWorkspace.shared.openApplication(at: t.appURL, configuration: .init())
            }
        } else {
            NSWorkspace.shared.openApplication(at: t.appURL, configuration: .init())
        }
    }

    /// Badges live in the Dock's accessibility tree (AXStatusLabel on each dock item).
    private func refreshBadges() {
        let badges = readBadges()
        for (bid, tile) in tiles { tile.setBadge(badges[bid]) }
    }

    private func readBadges() -> [String: String] {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [:] }
        let ax = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.3)
        var badges: [String: String] = [:]
        func children(_ e: AXUIElement) -> [AXUIElement] {
            var v: CFTypeRef?
            AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &v)
            return v as? [AXUIElement] ?? []
        }
        for list in children(ax) {
            for item in children(list) {
                var url: CFTypeRef?, label: CFTypeRef?
                AXUIElementCopyAttributeValue(item, kAXURLAttribute as CFString, &url)
                AXUIElementCopyAttributeValue(item, "AXStatusLabel" as CFString, &label)
                guard let u = url as? URL ?? (url as? String).flatMap(URL.init(string:)),
                      let l = label as? String, !l.isEmpty,
                      let bid = Bundle(url: u)?.bundleIdentifier else { continue }
                badges[bid] = l
            }
        }
        return badges
    }

    // Self-test hooks
    func debugCounts() -> (Int, Int) { (tiles.count, pinnedApps().count) }
    func debugBadges() -> [String: String] { readBadges() }
    func debugTap(bundleID: String, url: URL) { tap(DockTile(bundleID: bundleID, url: url, icon: NSImage())) }
}
