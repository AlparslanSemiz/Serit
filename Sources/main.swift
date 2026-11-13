// Şerit — a fast, self-healing Touch Bar: Dock, Now Playing, volume, brightness, status.
import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate, NSMenuDelegate {
    let host = TouchBarHost()
    let settingsWindow = SettingsWindowController()
    var statusItem: NSStatusItem!
    // Widgets live as long as the bar they belong to.
    var dock: DockWidget?, media: MediaWidget?, status: StatusWidget?, appKeys: AppKeys?
    lazy var quick = QuickControls(host: host)

    func applicationDidFinishLaunching(_ n: Notification) {
        if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) {
            log("Accessibility not granted yet (needed for badges and media keys)")
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let img = NSImage(systemSymbolName: "rectangle.split.3x1.fill", accessibilityDescription: "Şerit")
        img?.isTemplate = true
        statusItem.button?.image = img
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu

        host.makeBar = { [unowned self] in self.buildBar() }
        host.start()
        NotificationCenter.default.addObserver(forName: Settings.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            PrivateTouchBar.setControlStripPresence(TouchBarHost.trayID, Settings.shared.showTrayButton)
            if Settings.shared.enabled { self.host.rebuild() } else { self.host.hide() }
        }
        // Lets scripts (and the self-test) open panels without touching the bar:
        //   notifyutil-style: post "local.serit.panel" with object volume | brightness | more | close
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("local.serit.panel"), object: nil, queue: .main) { [weak self] n in
            self?.quick.debugOpen(n.object as? String ?? "")
        }
        log("Şerit started")
    }

    func applicationWillTerminate(_ n: Notification) { host.stop() }

    var main: MainBarView?
    private var shownCheck: DispatchWorkItem?

    /// Full-width Touch Bar is 1004 pt; next to the Control Strip there are about 685.
    static var barWidth: CGFloat { TouchBarHost.useFullWidth ? 1004 : 680 }

    private func buildBar() -> NSTouchBar {
        let s = Settings.shared
        let bar = NSTouchBar()
        bar.delegate = self
        dock = s.showDock ? DockWidget() : nil
        appKeys = s.showAppKeys ? AppKeys() : nil
        media = s.showMedia ? MediaWidget() : nil
        status = s.showStatus ? StatusWidget() : nil

        func view(_ item: NSTouchBarItem?) -> NSView? { item?.view }
        let left = [view(dock?.makeItem())].compactMap { $0 }
        let keys = view(appKeys?.makeItem())
        var right: [NSView] = []
        if let v = view(media?.makeItem()) { right.append(v) }
        if s.showVolume || s.showBrightness || s.showScreenshot, let v = view(quick.item(for: QuickControls.clusterID)) { right.append(v) }
        if let v = view(status?.makeItem()) { right.append(v) }
        if let v = view(quick.item(for: QuickControls.moreID)) { right.append(v) }

        let width = Self.barWidth - widthTrim
        let m = MainBarView(width: width, left: left, appKeys: keys, right: right)
        main = m
        quick.main = m
        bar.defaultItemIdentifiers = [MainBarView.id]
        log("bar built: \(Int(width)) pt, \(TouchBarHost.useFullWidth ? "full width" : "next to Control Strip")")
        checkShown(m)
        return bar
    }

    /// If macOS refuses the item (too wide for the space it has), it shows nothing at all.
    /// Notice that, shave a few points off and try again, and say so in the log.
    private var widthTrim: CGFloat = 0
    private func checkShown(_ m: MainBarView) {
        shownCheck?.cancel()
        let w = DispatchWorkItem { [weak self, weak m] in
            guard let self, let m, self.main === m, Settings.shared.enabled else { return }
            if m.window == nil {
                guard self.widthTrim < 40 else { log("layout: bar still not shown at \(Int(m.barWidth)) pt, giving up trimming"); return }
                self.widthTrim += 8
                log("layout: bar not shown at \(Int(m.barWidth)) pt, retrying narrower")
                self.host.rebuild()
            }
        }
        shownCheck = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard id == MainBarView.id, let main else { return nil }
        let item = NSCustomTouchBarItem(identifier: id)
        item.view = main
        return item
    }

    // MARK: menu bar
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let t = NSMenuItem(title: "Şerit", action: nil, keyEquivalent: ""); t.isEnabled = false
        menu.addItem(t)
        if !AXIsProcessTrusted() {
            let w = NSMenuItem(title: "⚠️ Erişilebilirlik izni gerekli…", action: #selector(openAX), keyEquivalent: ""); w.target = self
            menu.addItem(w)
        }
        let e = NSMenuItem(title: "Touch Bar'da göster", action: #selector(toggleEnabled), keyEquivalent: "e"); e.target = self
        e.state = Settings.shared.enabled ? .on : .off
        menu.addItem(e)
        let r = NSMenuItem(title: "Touch Bar'ı yenile", action: #selector(refresh), keyEquivalent: "r"); r.target = self
        menu.addItem(r)
        menu.addItem(.separator())
        let p = NSMenuItem(title: "Ayarlar…", action: #selector(openSettings), keyEquivalent: ","); p.target = self
        menu.addItem(p)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Şerit'ten çık", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func toggleEnabled() { Settings.shared.enabled.toggle() }
    @objc func refresh() { host.rebuild() }
    @objc func openSettings() { settingsWindow.show { [weak self] in self?.refresh() } }
    @objc func openAX() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

if CommandLine.arguments.contains("--selftest") {
    _ = NSApplication.shared
    exit(SelfTest.run())
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
