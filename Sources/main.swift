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

    private func buildBar() -> NSTouchBar {
        let s = Settings.shared
        let bar = NSTouchBar()
        bar.delegate = self
        var ids: [NSTouchBarItem.Identifier] = []
        dock = nil; media = nil; status = nil; appKeys = nil
        if s.showDock { dock = DockWidget(); ids.append(DockWidget.id) }
        if s.showAppKeys { appKeys = AppKeys(); ids.append(AppKeys.id) }
        ids.append(.flexibleSpace)
        if s.showMedia { media = MediaWidget(); ids.append(MediaWidget.id) }
        if s.showVolume { ids.append(QuickControls.volumeID) }
        if s.showBrightness { ids.append(QuickControls.brightnessID) }
        if s.showScreenshot { ids.append(QuickControls.screenshotID) }
        if s.showStatus { status = StatusWidget(); ids.append(StatusWidget.id) }
        ids.append(QuickControls.moreID)
        bar.defaultItemIdentifiers = ids
        // Touch Bar is ~1004 pt wide (full width) or ~685 pt next to the Control Strip.
        let total: CGFloat = TouchBarHost.useFullWidth ? 1000 : 680
        var others: CGFloat = 0
        if s.showMedia { others += 260 }
        if s.showVolume { others += 60 }
        if s.showBrightness { others += 60 }
        if s.showScreenshot { others += 60 }
        if s.showStatus { others += 215 }
        others += 50   // the ‹ key
        DockWidget.maxWidth = max(140, total - others)
        DockWidget.mediaTitleRoom = s.showMedia ? 90 : 0
        return bar
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch id {
        case DockWidget.id: return dock?.makeItem()
        case MediaWidget.id: return media?.makeItem()
        case StatusWidget.id: return status?.makeItem()
        case AppKeys.id: return appKeys?.makeItem()
        default: return quick.item(for: id)
        }
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
