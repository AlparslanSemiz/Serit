import AppKit
import CoreAudio
import AudioToolbox

// MARK: - System controls

enum SystemVolume {
    private static func device() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }
    private static var volAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    private static var muteAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                             mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    static var level: Float {
        get {
            var v: Float32 = 0; var size = UInt32(MemoryLayout<Float32>.size)
            AudioObjectGetPropertyData(device(), &volAddr, 0, nil, &size, &v)
            return v
        }
        set {
            var v = Float32(max(0, min(1, newValue)))
            AudioObjectSetPropertyData(device(), &volAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
            if v > 0 && muted { muted = false }
        }
    }
    static var muted: Bool {
        get {
            var m: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(device(), &muteAddr, 0, nil, &size, &m)
            return m != 0
        }
        set {
            var m: UInt32 = newValue ? 1 : 0
            AudioObjectSetPropertyData(device(), &muteAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        }
    }
    static var effective: Float { muted ? 0 : level }
    static var symbol: String {
        let v = effective
        return v <= 0.001 ? "speaker.slash.fill" : v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

/// Built-in display brightness via the private DisplayServices framework.
enum DisplayBrightness {
    private static let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    private static var display: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8); var n: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &n)
        return ids.prefix(Int(n)).first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? CGMainDisplayID()
    }
    static var level: Float {
        get {
            guard let ds, let s = dlsym(ds, "DisplayServicesGetBrightness") else { return 0.5 }
            typealias F = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
            var v: Float = 0.5
            _ = unsafeBitCast(s, to: F.self)(display, &v)
            return v
        }
        set {
            guard let ds, let s = dlsym(ds, "DisplayServicesSetBrightness") else { return }
            typealias F = @convention(c) (CGDirectDisplayID, Float) -> Int32
            _ = unsafeBitCast(s, to: F.self)(display, max(0, min(1, newValue)))
        }
    }
    static var symbol: String { level < 0.5 ? "sun.min.fill" : "sun.max.fill" }
}

enum SystemActions {
    /// The same toolbar as ⇧⌘5.
    static func screenshot() {
        for path in ["/System/Applications/Utilities/Screenshot.app", "/Applications/Utilities/Screenshot.app"]
        where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init()); return
        }
        run("/usr/sbin/screencapture", ["-iUc"])
    }
    static func missionControl() {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.exposelauncher") {
            NSWorkspace.shared.openApplication(at: u, configuration: .init())
        }
    }
    static func lockScreen() {
        let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW)
        if let h, let s = dlsym(h, "SACLockScreenImmediate") {
            typealias F = @convention(c) () -> Int32
            _ = unsafeBitCast(s, to: F.self)()
        } else {
            run("/usr/bin/pmset", ["displaysleepnow"])
        }
    }
    static func displaySleep() { run("/usr/bin/pmset", ["displaysleepnow"]) }

    private static func run(_ path: String, _ args: [String]) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        try? p.run()
    }
}

// MARK: - Building blocks

enum TB {
    /// A rounded Touch Bar key. `bright` makes it stand out on the black bar.
    static func button(_ symbol: String, width: CGFloat = 52, bright: Bool = true, target: AnyObject, action: Selector) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
        let b = NSButton(image: img, target: target, action: action)
        b.bezelColor = bright ? NSColor(white: 0.38, alpha: 1) : NSColor(white: 0.22, alpha: 1)
        b.contentTintColor = .white
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: width).isActive = true
        return b
    }

    static func item(_ id: String, _ view: NSView) -> NSCustomTouchBarItem {
        let i = NSCustomTouchBarItem(identifier: NSTouchBarItem.Identifier(id))
        i.view = view
        return i
    }
}

/// A bar made of ready-made items (used for panels).
final class PanelBar: NSTouchBar, NSTouchBarDelegate {
    private var items: [NSTouchBarItem.Identifier: NSTouchBarItem] = [:]
    /// `trailing` items are pushed to the right edge (that's where the close key lives,
    /// right under the finger that opened the panel).
    init(_ list: [NSTouchBarItem?], trailing: [NSTouchBarItem?] = []) {
        super.init()
        delegate = self
        var ids: [NSTouchBarItem.Identifier] = []
        for case let i? in list { items[i.identifier] = i; ids.append(i.identifier) }
        if !trailing.isEmpty {
            ids.append(.flexibleSpace)
            for case let i? in trailing { items[i.identifier] = i; ids.append(i.identifier) }
        }
        defaultItemIdentifiers = ids
    }
    required init?(coder: NSCoder) { fatalError() }
    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? { items[identifier] }
}

// MARK: - Quick controls on the main bar, and the panels they open

final class QuickControls: NSObject {
    static let volumeID = NSTouchBarItem.Identifier("local.serit.volume")
    static let brightnessID = NSTouchBarItem.Identifier("local.serit.brightness")
    static let screenshotID = NSTouchBarItem.Identifier("local.serit.screenshot")
    static let moreID = NSTouchBarItem.Identifier("local.serit.more")
    /// Volume, brightness and screenshot live in one item so the hold-slider can spread over all three.
    static let clusterID = NSTouchBarItem.Identifier("local.serit.controls")

    private weak var host: TouchBarHost?
    /// Panels open inside the main bar (see MainBarView).
    weak var main: MainBarView?
    private weak var volumeKey: HoldSlideKey?
    private var volumeButton: NSButton?
    private var brightnessButton: NSButton?
    private var syncTimer: Timer?
    // panel state
    private var volumeSlider: NSSlider?
    private var brightnessSlider: NSSlider?
    private var muteButton: NSButton?
    private var volumeLabel: NSTextField?
    private var brightnessLabel: NSTextField?

    init(host: TouchBarHost) {
        self.host = host
        super.init()
        // Keys and Control Center change these too; keep the icons honest.
        syncTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.sync() }
    }
    deinit { syncTimer?.invalidate() }

    func item(for id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch id {
        case Self.volumeID:
            let k = HoldSlideKey(symbol: { SystemVolume.symbol }, minSymbol: "speaker.fill", maxSymbol: "speaker.wave.3.fill", get: { SystemVolume.effective },
                                                     set: { SystemVolume.level = $0; if $0 > 0 { SystemVolume.muted = false } },
                                                     onTap: { [weak self] in self?.openVolume() })
            volumeKey = k
            return TB.item(id.rawValue, k)
        case Self.brightnessID:
            return TB.item(id.rawValue, HoldSlideKey(symbol: { DisplayBrightness.symbol }, minSymbol: "sun.min.fill", maxSymbol: "sun.max.fill", get: { DisplayBrightness.level },
                                                     set: { DisplayBrightness.level = $0 },
                                                     onTap: { [weak self] in self?.openBrightness() }))
        case Self.clusterID:
            let s = Settings.shared
            let cluster = NSView()
            var views: [NSView] = []
            var keys: [HoldSlideKey] = []
            if s.showVolume, let v = (item(for: Self.volumeID) as? NSCustomTouchBarItem)?.view as? HoldSlideKey { views.append(v); keys.append(v) }
            if s.showBrightness, let b = (item(for: Self.brightnessID) as? NSCustomTouchBarItem)?.view as? HoldSlideKey { views.append(b); keys.append(b) }
            if s.showScreenshot { views.append(TB.button("camera.viewfinder", width: 70, target: self, action: #selector(screenshot))) }
            guard !views.isEmpty else { return nil }
            let stack = NSStackView(views: views); stack.spacing = 6
            stack.translatesAutoresizingMaskIntoConstraints = false
            cluster.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cluster.leadingAnchor), stack.trailingAnchor.constraint(equalTo: cluster.trailingAnchor),
                stack.topAnchor.constraint(equalTo: cluster.topAnchor), stack.bottomAnchor.constraint(equalTo: cluster.bottomAnchor),
            ])
            cluster.wantsLayer = true
            keys.forEach { $0.overlayHost = cluster }
            let clusterItem = TB.item(id.rawValue, cluster)
            clusterItem.visibilityPriority = .high
            return clusterItem
        case Self.screenshotID:
            return TB.item(id.rawValue, TB.button("camera.viewfinder", target: self, action: #selector(screenshot)))
        case Self.moreID:
            // High priority: if the bar is ever too full, macOS drops low-priority items first,
            // and the ‹ key is the only way into the other controls.
            let more = TB.item(id.rawValue, TB.button("chevron.left", width: 40, bright: false, target: self, action: #selector(openMore)))
            more.visibilityPriority = .high
            return more
        default: return nil
        }
    }

    private func sync() {
        volumeButton?.image = NSImage(systemSymbolName: SystemVolume.symbol, accessibilityDescription: nil)
        brightnessButton?.image = NSImage(systemSymbolName: DisplayBrightness.symbol, accessibilityDescription: nil)
        if let s = volumeSlider, !s.isHighlighted { s.floatValue = SystemVolume.effective; updateVolumeLabel() }
        if let s = brightnessSlider, !s.isHighlighted { s.floatValue = DisplayBrightness.level; updateBrightnessLabel() }
        muteButton?.image = NSImage(systemSymbolName: SystemVolume.muted ? "speaker.slash.fill" : "speaker.fill", accessibilityDescription: nil)
    }

    func debugOpen(_ which: String) {
        switch which {
        case "volume": openVolume()
        case "brightness": openBrightness()
        case "more": openMore()
        case "hold": volumeKey?.debugHold(true)
        case "release": volumeKey?.debugHold(false)
        default: close()
        }
    }

    // MARK: actions on the main bar
    @objc private func screenshot() { SystemActions.screenshot() }
    @objc private func openVolume() { main?.show(volumePanel(), autoClose: 4) }
    @objc private func openBrightness() { main?.show(brightnessPanel(), autoClose: 4) }
    @objc private func openMore() { main?.show(morePanel()) }
    @objc private func close() { clearPanelRefs(); main?.closePanel() }

    private func clearPanelRefs() { volumeSlider = nil; brightnessSlider = nil; muteButton = nil; volumeLabel = nil; brightnessLabel = nil }

    // MARK: building panels
    /// Same size, look and place as the ‹ key that opened the panel.
    private func closeKey(_ symbol: String = "chevron.right") -> NSButton {
        TB.button(symbol, width: 40, bright: false, target: self, action: #selector(close))
    }

    /// `flexible` sliders stretch to fill a panel (at least `width`).
    private func slider(value: Float, action: Selector, width: CGFloat, flexible: Bool = false) -> NSSlider {
        let s = NSSlider(value: Double(value), minValue: 0, maxValue: 1, target: self, action: action)
        s.isContinuous = true
        s.translatesAutoresizingMaskIntoConstraints = false
        if flexible {
            s.widthAnchor.constraint(greaterThanOrEqualToConstant: width).isActive = true
            s.setContentHuggingPriority(.defaultLow, for: .horizontal)
        } else {
            s.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        return s
    }

    private func label() -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        l.textColor = .white
        l.alignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 44).isActive = true
        return l
    }

    private func volumeRow(width: CGFloat) -> NSView {
        let mute = TB.button(SystemVolume.muted ? "speaker.slash.fill" : "speaker.fill", width: 52, target: self, action: #selector(toggleMute))
        muteButton = mute
        let down = TB.button("minus", width: 44, bright: false, target: self, action: #selector(volumeDown))
        let s = slider(value: SystemVolume.effective, action: #selector(volumeChanged(_:)), width: width, flexible: true); volumeSlider = s
        let up = TB.button("plus", width: 44, bright: false, target: self, action: #selector(volumeUp))
        let l = label(); volumeLabel = l; updateVolumeLabel()
        let row = NSStackView(views: [mute, down, s, up, l]); row.spacing = 8
        return row
    }

    private func brightnessRow(width: CGFloat) -> NSView {
        let icon = TB.button("sun.max.fill", width: 52, target: self, action: #selector(brightnessMax))
        let down = TB.button("minus", width: 44, bright: false, target: self, action: #selector(brightnessDown))
        let s = slider(value: DisplayBrightness.level, action: #selector(brightnessChanged(_:)), width: width, flexible: true); brightnessSlider = s
        let up = TB.button("plus", width: 44, bright: false, target: self, action: #selector(brightnessUp))
        let l = label(); brightnessLabel = l; updateBrightnessLabel()
        let row = NSStackView(views: [icon, down, s, up, l]); row.spacing = 8
        return row
    }

    private func volumePanel() -> NSView {
        clearPanelRefs()
        return MainBarView.panelRow([volumeRow(width: 300)], close: closeKey())
    }

    private func brightnessPanel() -> NSView {
        clearPanelRefs()
        return MainBarView.panelRow([brightnessRow(width: 300)], close: closeKey())
    }

    private func morePanel() -> NSView {
        clearPanelRefs()
        let media = NSStackView(views: [
            TB.button("backward.fill", width: 46, target: self, action: #selector(prevTrack)),
            TB.button("playpause.fill", width: 46, target: self, action: #selector(playPause)),
            TB.button("forward.fill", width: 46, target: self, action: #selector(nextTrack)),
        ]); media.spacing = 4
        let mute = TB.button(SystemVolume.muted ? "speaker.slash.fill" : "speaker.fill", width: 46, target: self, action: #selector(toggleMute))
        muteButton = mute
        let vol = slider(value: SystemVolume.effective, action: #selector(volumeChanged(_:)), width: 150); volumeSlider = vol
        let sun = TB.button("sun.max.fill", width: 46, target: self, action: #selector(brightnessMax))
        let bri = slider(value: DisplayBrightness.level, action: #selector(brightnessChanged(_:)), width: 150); brightnessSlider = bri
        let system = NSStackView(views: [
            TB.button("rectangle.3.group", width: 46, target: self, action: #selector(missionControl)),
            TB.button("camera.viewfinder", width: 46, target: self, action: #selector(screenshot)),
            TB.button("moon.zzz.fill", width: 46, target: self, action: #selector(displaySleep)),
            TB.button("lock.fill", width: 46, target: self, action: #selector(lock)),
        ]); system.spacing = 4
        let volRow = NSStackView(views: [mute, vol]); volRow.spacing = 6
        let briRow = NSStackView(views: [sun, bri]); briRow.spacing = 6
        var groups: [NSView] = [media, volRow, briRow]
        if KeyboardBacklight.available {
            let kb = TB.button("light.max", width: 46, target: self, action: #selector(keyboardToggle))
            let ks = slider(value: KeyboardBacklight.level, action: #selector(keyboardChanged(_:)), width: 110)
            let kbRow = NSStackView(views: [kb, ks]); kbRow.spacing = 6
            groups.append(kbRow)
            for s in [vol, bri] { s.constraints.filter { $0.firstAttribute == .width }.forEach { $0.constant = 110 } }
        }
        groups.append(system)
        return MainBarView.panelRow(groups, close: closeKey())
    }

    // MARK: panel actions
    private func updateVolumeLabel() { volumeLabel?.stringValue = "\(Int((SystemVolume.effective * 100).rounded()))%" }
    private func updateBrightnessLabel() { brightnessLabel?.stringValue = "\(Int((DisplayBrightness.level * 100).rounded()))%" }

    @objc private func volumeChanged(_ s: NSSlider) {
        SystemVolume.level = s.floatValue
        if s.floatValue > 0 { SystemVolume.muted = false }
        updateVolumeLabel(); sync(); keepOpenIfSliderPanel()
    }
    @objc private func brightnessChanged(_ s: NSSlider) {
        DisplayBrightness.level = s.floatValue
        updateBrightnessLabel(); sync(); keepOpenIfSliderPanel()
    }
    private func step(_ v: Float, _ d: Float) -> Float { max(0, min(1, (v / 0.0625).rounded() * 0.0625 + d)) }
    @objc private func volumeUp() { SystemVolume.level = step(SystemVolume.effective, 0.0625); SystemVolume.muted = false; sync(); updateVolumeLabel(); keepOpenIfSliderPanel() }
    @objc private func volumeDown() { SystemVolume.level = step(SystemVolume.effective, -0.0625); sync(); updateVolumeLabel(); keepOpenIfSliderPanel() }
    @objc private func toggleMute() { SystemVolume.muted.toggle(); sync(); updateVolumeLabel(); keepOpenIfSliderPanel() }
    @objc private func brightnessUp() { DisplayBrightness.level = step(DisplayBrightness.level, 0.0625); sync(); updateBrightnessLabel(); keepOpenIfSliderPanel() }
    @objc private func brightnessDown() { DisplayBrightness.level = step(DisplayBrightness.level, -0.0625); sync(); updateBrightnessLabel(); keepOpenIfSliderPanel() }
    @objc private func brightnessMax() { DisplayBrightness.level = 1; sync(); updateBrightnessLabel(); keepOpenIfSliderPanel() }
    @objc private func keyboardChanged(_ s: NSSlider) { KeyboardBacklight.level = s.floatValue }
    private var keyboardBeforeOff: Float = 0.5
    @objc private func keyboardToggle() {
        let v = KeyboardBacklight.level
        if v > 0.01 { keyboardBeforeOff = v; KeyboardBacklight.level = 0 } else { KeyboardBacklight.level = max(keyboardBeforeOff, 0.3) }
    }
    @objc private func prevTrack() { MediaKeys.press(MediaKeys.previous) }
    @objc private func playPause() { MediaKeys.press(MediaKeys.play) }
    @objc private func nextTrack() { MediaKeys.press(MediaKeys.next) }
    @objc private func missionControl() { close(); SystemActions.missionControl() }
    @objc private func displaySleep() { close(); SystemActions.displaySleep() }
    @objc private func lock() { close(); SystemActions.lockScreen() }

    /// Single-slider panels close themselves after a few idle seconds; the "more" panel stays.
    private func keepOpenIfSliderPanel() {
        if volumeLabel != nil || brightnessLabel != nil { main?.touch(autoClose: 4) }
    }
}
