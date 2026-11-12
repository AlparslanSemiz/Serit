// Private Touch Bar plumbing. Everything here is resolved at runtime (ObjC runtime +
// dlsym), so nothing links against private frameworks and a missing symbol just
// degrades instead of crashing.
import AppKit
import ObjectiveC

enum PrivateTouchBar {
    private static let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW)

    private static func dfrSymbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let dfr else { return nil }
        return dlsym(dfr, name)
    }

    /// Show/hide our item in the Control Strip (the right-hand system area).
    static func setControlStripPresence(_ identifier: NSTouchBarItem.Identifier, _ present: Bool) {
        guard let s = dfrSymbol("DFRElementSetControlStripPresenceForIdentifier") else { return }
        typealias F = @convention(c) (CFString, Bool) -> Void
        unsafeBitCast(s, to: F.self)(identifier.rawValue as CFString, present)
    }

    /// The little "x" macOS draws on system-modal bars. We never want it.
    static func setShowsCloseBox(_ shows: Bool) {
        guard let s = dfrSymbol("DFRSystemModalShowsCloseBoxWhenFrontMost") else { return }
        typealias F = @convention(c) (Bool) -> Void
        unsafeBitCast(s, to: F.self)(shows)
    }

    private static func classMethod(_ cls: AnyClass, _ names: [String]) -> (Selector, IMP)? {
        for n in names {
            let sel = NSSelectorFromString(n)
            if let m = class_getClassMethod(cls, sel) { return (sel, method_getImplementation(m)) }
        }
        return nil
    }

    /// placement 0 = next to the Control Strip, 1 = full width.
    @discardableResult
    static func present(_ bar: NSTouchBar, placement: Int64, trayIdentifier: NSTouchBarItem.Identifier?) -> Bool {
        guard let (sel, imp) = classMethod(NSTouchBar.self, ["presentSystemModalTouchBar:placement:systemTrayItemIdentifier:",
                                                             "presentSystemModalFunctionBar:placement:systemTrayItemIdentifier:"]) else {
            log("present selector missing"); return false
        }
        typealias F = @convention(c) (AnyClass, Selector, NSTouchBar, Int64, NSString?) -> Void
        unsafeBitCast(imp, to: F.self)(NSTouchBar.self, sel, bar, placement, trayIdentifier?.rawValue as NSString?)
        return true
    }

    static func dismiss(_ bar: NSTouchBar) {
        guard let (sel, imp) = classMethod(NSTouchBar.self, ["dismissSystemModalTouchBar:", "dismissSystemModalFunctionBar:"]) else { return }
        typealias F = @convention(c) (AnyClass, Selector, NSTouchBar) -> Void
        unsafeBitCast(imp, to: F.self)(NSTouchBar.self, sel, bar)
    }

    static func minimize(_ bar: NSTouchBar) {
        guard let (sel, imp) = classMethod(NSTouchBar.self, ["minimizeSystemModalTouchBar:", "minimizeSystemModalFunctionBar:"]) else { return }
        typealias F = @convention(c) (AnyClass, Selector, NSTouchBar) -> Void
        unsafeBitCast(imp, to: F.self)(NSTouchBar.self, sel, bar)
    }

    static func addSystemTrayItem(_ item: NSTouchBarItem) {
        guard let (sel, imp) = classMethod(NSTouchBarItem.self, ["addSystemTrayItem:"]) else { return }
        typealias F = @convention(c) (AnyClass, Selector, NSTouchBarItem) -> Void
        unsafeBitCast(imp, to: F.self)(NSTouchBarItem.self, sel, item)
    }

    static func removeSystemTrayItem(_ item: NSTouchBarItem) {
        guard let (sel, imp) = classMethod(NSTouchBarItem.self, ["removeSystemTrayItem:"]) else { return }
        typealias F = @convention(c) (AnyClass, Selector, NSTouchBarItem) -> Void
        unsafeBitCast(imp, to: F.self)(NSTouchBarItem.self, sel, item)
    }
}

/// Owns the system-modal bar and keeps it on screen. Pock's "blank Touch Bar"
/// problem is macOS silently handing the bar back to the system (app switches,
/// sleep, screen lock, TouchBarServer restarts); we simply re-present on all of them.
final class TouchBarHost: NSObject {
    static let trayID = NSTouchBarItem.Identifier("local.serit.tray")

    private(set) var bar: NSTouchBar?
    private var trayItem: NSCustomTouchBarItem?
    private var isMinimized = false
    private var watchdog: Timer?
    private var lastServerPID: pid_t = 0
    var makeBar: () -> NSTouchBar = { NSTouchBar() }

    func start() {
        PrivateTouchBar.setShowsCloseBox(false)
        installTray()
        rebuild()

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.activeSpaceDidChangeNotification] {
            ws.addObserver(self, selector: #selector(reassert), name: name, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reassert),
                                                            name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
        // TouchBarServer / ControlStrip restarts drop every system-modal bar and tray item.
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.checkServer() }
        lastServerPID = Self.serverPID()
    }

    private static func serverPID() -> pid_t {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-x", "TouchBarServer"]
        let pipe = Pipe(); p.standardOutput = pipe
        try? p.run(); p.waitUntilExit()
        let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return pid_t(s.split(separator: "\n").first.flatMap { Int32($0) } ?? 0)
    }

    private func checkServer() {
        let pid = Self.serverPID()
        if pid != 0 && pid != lastServerPID {
            log("TouchBarServer restarted (\(lastServerPID) → \(pid)), re-installing")
            lastServerPID = pid
            installTray()
            reassert()
        }
    }

    private func installTray() {
        if let t = trayItem { PrivateTouchBar.removeSystemTrayItem(t) }
        let item = NSCustomTouchBarItem(identifier: Self.trayID)
        let b = NSButton(image: Self.trayIcon(), target: self, action: #selector(trayTapped))
        b.isBordered = false
        item.view = b
        trayItem = item
        PrivateTouchBar.addSystemTrayItem(item)
        PrivateTouchBar.setControlStripPresence(Self.trayID, Settings.shared.showTrayButton)
    }

    static func trayIcon() -> NSImage {
        let img = NSImage(systemSymbolName: "rectangle.split.3x1.fill", accessibilityDescription: "Şerit")
            ?? NSImage(named: NSImage.touchBarListViewTemplateName)!
        return img
    }

    @objc private func trayTapped() {
        if isMinimized || bar == nil { isMinimized = false; reassert() }
        else if let shown = panel ?? bar { PrivateTouchBar.minimize(shown); isMinimized = true }
    }

    /// Build a fresh bar from current settings and show it.
    func rebuild() {
        if let p = panel { PrivateTouchBar.dismiss(p); panel = nil }
        if let old = bar { PrivateTouchBar.dismiss(old) }
        bar = makeBar()
        isMinimized = false
        reassert()
    }

    /// A panel (slider, "more" controls) replaces the main bar until it is closed.
    /// Popovers don't open inside a system-modal bar, so panels are whole bars of their own.
    private(set) var panel: NSTouchBar?
    private var panelTimeout: DispatchWorkItem?

    func open(_ p: NSTouchBar, autoClose: TimeInterval? = nil) {
        if let old = panel { PrivateTouchBar.dismiss(old) }
        panel = p
        isMinimized = false
        PrivateTouchBar.present(p, placement: Self.useFullWidth ? 1 : 0, trayIdentifier: Self.trayID)
        panelTimeout?.cancel()
        if let autoClose {
            let w = DispatchWorkItem { [weak self] in self?.closePanel() }
            panelTimeout = w
            DispatchQueue.main.asyncAfter(deadline: .now() + autoClose, execute: w)
        }
    }

    /// Keeps an auto-closing panel open while the user is still touching it.
    func touchPanel(autoClose: TimeInterval) {
        guard panel != nil else { return }
        panelTimeout?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.closePanel() }
        panelTimeout = w
        DispatchQueue.main.asyncAfter(deadline: .now() + autoClose, execute: w)
    }

    func closePanel() {
        panelTimeout?.cancel()
        guard let p = panel else { return }
        panel = nil
        PrivateTouchBar.dismiss(p)
        reassert()
    }

    @objc func reassert() {
        guard bar != nil, !isMinimized, Settings.shared.enabled else { return }
        // A tiny delay lets the system finish its own bar swap after app activation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let shown = self.panel ?? self.bar else { return }
            PrivateTouchBar.present(shown, placement: Self.useFullWidth ? 1 : 0, trayIdentifier: Self.trayID)
        }
    }

    /// Sharing the bar with the Control Strip (placement 0) only works when macOS is set to
    /// "App Controls + Control Strip". In any other mode there is no app area, so go full width.
    static var canShareWithControlStrip: Bool {
        UserDefaults(suiteName: "com.apple.touchbar.agent")?.string(forKey: "PresentationModeGlobal") == "appWithControlStrip"
    }
    static var useFullWidth: Bool {
        let mode = UserDefaults(suiteName: "com.apple.touchbar.agent")?.string(forKey: "PresentationModeGlobal")
        return Settings.shared.fullWidth || mode != "appWithControlStrip"
    }

    func hide() {
        panelTimeout?.cancel()
        if let p = panel { PrivateTouchBar.dismiss(p); panel = nil }
        if let bar { PrivateTouchBar.dismiss(bar) }
    }

    func stop() {
        hide()
        if let t = trayItem { PrivateTouchBar.removeSystemTrayItem(t) }
        PrivateTouchBar.setControlStripPresence(Self.trayID, false)
    }
}
