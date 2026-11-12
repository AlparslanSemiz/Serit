// `Serit --selftest`: exercises every action the Touch Bar buttons trigger and checks
// the result, restoring whatever it changed. Touches themselves can't be simulated,
// but each button only calls one of these functions.
import AppKit
import ApplicationServices

enum SelfTest {
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        if !ok { failures += 1 }
    }

    private static func spin(_ seconds: Double, until: () -> Bool = { false }) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end && !until() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    static func run() -> Int32 {
        print("Şerit öz-test\n")

        // Touch Bar plumbing
        let tbMethods = ["presentSystemModalTouchBar:placement:systemTrayItemIdentifier:", "dismissSystemModalTouchBar:", "minimizeSystemModalTouchBar:"]
            .allSatisfy { class_getClassMethod(NSTouchBar.self, NSSelectorFromString($0)) != nil }
        check("Touch Bar gizli API'leri", tbMethods)
        check("Touch Bar yerleşimi", true, TouchBarHost.useFullWidth ? "tam genişlik (macOS Control Strip modunda)" : "Control Strip'in yanında")

        // Volume: nudge, read back, restore
        let v0 = SystemVolume.level, m0 = SystemVolume.muted
        let target: Float = v0 > 0.5 ? v0 - 0.1 : v0 + 0.1
        SystemVolume.level = target
        let v1 = SystemVolume.level
        SystemVolume.level = v0; SystemVolume.muted = m0
        check("Ses ayarı", abs(v1 - target) < 0.02, String(format: "%.0f%% → %.0f%% → geri %.0f%%", v0 * 100, v1 * 100, SystemVolume.level * 100))

        // Brightness: same
        let b0 = DisplayBrightness.level
        let bt: Float = b0 > 0.5 ? b0 - 0.15 : b0 + 0.15
        DisplayBrightness.level = bt
        spin(0.4)
        let b1 = DisplayBrightness.level
        DisplayBrightness.level = b0
        spin(0.4)
        check("Parlaklık ayarı", abs(b1 - bt) < 0.03, String(format: "%.0f%% → %.0f%% → geri %.0f%%", b0 * 100, b1 * 100, DisplayBrightness.level * 100))

        // Battery
        if let b = Battery.read() { check("Pil", (0...100).contains(b.percent), "\(b.percent)%\(b.charging ? ", şarj oluyor" : "")\(b.onAC ? ", adaptör takılı" : "")") }
        else { check("Pil", false, "okunamadı") }

        // Weather
        var gotWeather = false
        Weather.shared.onChange = { gotWeather = true }
        Weather.shared.refreshIfNeeded(force: true)
        spin(8) { gotWeather }
        check("Hava durumu (\(Settings.shared.weatherCity))", gotWeather && Weather.shared.temp != nil,
              Weather.shared.temp.map { "\($0)° \(Weather.shared.symbol)" } ?? "cevap yok")

        // Dock
        let dock = DockWidget()
        _ = dock.makeItem()
        let (count, pinned) = dock.debugCounts()
        check("Dock", count > 0, "\(count) uygulama (\(pinned) sabitlenmiş)")
        check("Erişilebilirlik izni (rozetler, medya tuşları)", AXIsProcessTrusted())
        let badges = dock.debugBadges()
        check("Dock rozetleri okunabiliyor", AXIsProcessTrusted(), badges.isEmpty ? "şu an rozet yok" : badges.map { "\($0.key.split(separator: ".").last ?? ""): \($0.value)" }.joined(separator: ", "))

        // Dock tap action (open + bring forward) on a harmless app
        let calc = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.calculator").isEmpty
        dock.debugTap(bundleID: "com.apple.calculator", url: calc)
        spin(4) { NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.calculator" }
        check("Dock'a dokununca uygulama açılıyor", NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.calculator")
        dock.debugTap(bundleID: "com.apple.calculator", url: calc)   // frontmost → hide
        spin(2) { NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.calculator").first?.isHidden == true }
        check("Öndeki uygulamaya dokununca gizleniyor", NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.calculator").first?.isHidden == true)
        if !wasRunning { NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.calculator").first?.terminate() }

        // Now playing
        var np: NowPlaying?; var done = false
        NowPlayingSource.fetch { np = $0; done = true }
        spin(6) { done }
        check("Şu an çalan", done, np.map { "\($0.title)\($0.artist.isEmpty ? "" : " · \($0.artist)") [\($0.appBundleID ?? "sistem")]" } ?? "şu an çalan bir şey yok")

        print(failures == 0 ? "\nHepsi geçti." : "\n\(failures) kontrol başarısız.")
        return failures == 0 ? 0 : 1
    }
}
