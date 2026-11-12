import AppKit
import CoreAudio
import AudioToolbox

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
}

/// A compact icon that opens a slider on tap, or adjusts directly on press-and-slide.
final class SliderWidget: NSObject {
    let identifier: NSTouchBarItem.Identifier
    private let get: () -> Float
    private let set: (Float) -> Void
    private let icon: (Float) -> String
    private let minIcon: String, maxIcon: String
    private var popover: NSPopoverTouchBarItem?
    private var slider: NSSliderTouchBarItem?
    private var refresh: Timer?

    init(id: String, get: @escaping () -> Float, set: @escaping (Float) -> Void,
         icon: @escaping (Float) -> String, minIcon: String, maxIcon: String) {
        identifier = NSTouchBarItem.Identifier(id)
        self.get = get; self.set = set; self.icon = icon; self.minIcon = minIcon; self.maxIcon = maxIcon
    }

    func makeItem() -> NSTouchBarItem {
        let pop = NSPopoverTouchBarItem(identifier: identifier)
        let sliderID = NSTouchBarItem.Identifier(identifier.rawValue + ".slider")
        let s = NSSliderTouchBarItem(identifier: sliderID)
        s.slider.minValue = 0; s.slider.maxValue = 1
        s.slider.doubleValue = Double(get())
        s.minimumValueAccessory = NSSliderAccessory(image: NSImage(systemSymbolName: minIcon, accessibilityDescription: nil)!)
        s.maximumValueAccessory = NSSliderAccessory(image: NSImage(systemSymbolName: maxIcon, accessibilityDescription: nil)!)
        s.target = self; s.action = #selector(changed(_:))
        s.slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 380).isActive = true
        slider = s

        let inner = PopoverBar(item: s)
        pop.popoverTouchBar = inner
        pop.pressAndHoldTouchBar = inner
        pop.showsCloseButton = true
        pop.collapsedRepresentationImage = NSImage(systemSymbolName: icon(get()), accessibilityDescription: nil)
        popover = pop
        refresh = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sync() }
        return pop
    }
    deinit { refresh?.invalidate() }

    /// Values also change from the keyboard / Control Center; keep the icon honest.
    private func sync() {
        let v = get()
        slider?.slider.doubleValue = Double(v)
        popover?.collapsedRepresentationImage = NSImage(systemSymbolName: icon(v), accessibilityDescription: nil)
    }

    @objc private func changed(_ s: NSSliderTouchBarItem) {
        set(Float(s.slider.doubleValue))
        popover?.collapsedRepresentationImage = NSImage(systemSymbolName: icon(Float(s.slider.doubleValue)), accessibilityDescription: nil)
    }
}

/// A one-item bar used for the popover contents.
final class PopoverBar: NSTouchBar, NSTouchBarDelegate {
    private let item: NSTouchBarItem
    init(item: NSTouchBarItem) {
        self.item = item
        super.init()
        delegate = self
        defaultItemIdentifiers = [item.identifier]
    }
    required init?(coder: NSCoder) { fatalError() }
    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        identifier == item.identifier ? item : nil
    }
}

enum Controls {
    static func volume() -> SliderWidget {
        SliderWidget(id: "local.serit.volume",
                     get: { SystemVolume.muted ? 0 : SystemVolume.level },
                     set: { SystemVolume.level = $0 },
                     icon: { v in v <= 0.001 ? "speaker.slash.fill" : v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill" },
                     minIcon: "speaker.fill", maxIcon: "speaker.wave.3.fill")
    }
    static func brightness() -> SliderWidget {
        SliderWidget(id: "local.serit.brightness",
                     get: { DisplayBrightness.level },
                     set: { DisplayBrightness.level = $0 },
                     icon: { v in v < 0.5 ? "sun.min.fill" : "sun.max.fill" },
                     minIcon: "sun.min", maxIcon: "sun.max.fill")
    }
}
