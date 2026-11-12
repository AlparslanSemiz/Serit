import AppKit
import IOKit.ps

enum Battery {
    static func read() -> (percent: Int, charging: Bool, onAC: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            return (Int((Double(cur) / Double(Swift.max(max, 1)) * 100).rounded()),
                    d[kIOPSIsChargingKey] as? Bool ?? false,
                    (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
        }
        return nil
    }
}

/// Current conditions from Open-Meteo (free, no API key). City-level coordinates only.
final class Weather {
    static let shared = Weather()
    private(set) var temp: Int?
    private(set) var symbol = "cloud.fill"
    private var lastFetch = Date.distantPast
    var onChange: (() -> Void)?

    func refreshIfNeeded(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastFetch) > 20 * 60 else { return }
        lastFetch = Date()
        let s = Settings.shared
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(s.weatherLat)&longitude=\(s.weatherLon)&current=temperature_2m,weather_code,is_day")!
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cur = j["current"] as? [String: Any] else {
                DispatchQueue.main.async { self.lastFetch = Date().addingTimeInterval(-18 * 60) }   // retry in ~2 min
                return
            }
            let t = (cur["temperature_2m"] as? Double).map { Int($0.rounded()) }
            let code = cur["weather_code"] as? Int ?? 3
            let day = (cur["is_day"] as? Int ?? 1) == 1
            DispatchQueue.main.async {
                self.temp = t
                self.symbol = Self.symbol(code, day: day)
                self.onChange?()
            }
        }.resume()
    }

    static func symbol(_ code: Int, day: Bool) -> String {
        switch code {
        case 0: return day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }
}

final class StatusWidget: NSObject {
    static let id = NSTouchBarItem.Identifier("local.serit.status")
    private let weatherButton = NSButton()
    private let batteryButton = NSButton()
    private let clockButton = NSButton()
    private var timer: Timer?
    private let clockFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    func makeItem() -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: Self.id)
        let s = Settings.shared
        for b in [weatherButton, batteryButton, clockButton] {
            b.isBordered = false
            b.imagePosition = .imageLeading
            b.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
            b.contentTintColor = .white
        }
        weatherButton.target = self; weatherButton.action = #selector(openWeather)
        clockButton.target = self; clockButton.action = #selector(openCalendar)
        var views: [NSView] = []
        if s.statusWeather { views.append(weatherButton) }
        if s.statusBattery { views.append(batteryButton) }
        if s.statusClock { views.append(clockButton) }
        let row = NSStackView(views: views)
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        item.view = row
        item.visibilityPriority = .high

        Weather.shared.onChange = { [weak self] in self?.render() }
        Weather.shared.refreshIfNeeded()
        render()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Weather.shared.refreshIfNeeded()
            self?.render()
        }
        return item
    }
    deinit { timer?.invalidate() }

    private func render() {
        let w = Weather.shared
        weatherButton.image = NSImage(systemSymbolName: w.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [.white, .systemYellow]))
        weatherButton.title = w.temp.map { " \($0)°" } ?? " –"

        if let b = Battery.read() {
            let level = b.percent >= 88 ? 100 : b.percent >= 63 ? 75 : b.percent >= 38 ? 50 : b.percent >= 13 ? 25 : 0
            let name = (b.charging || b.onAC) ? "battery.100percent.bolt" : "battery.\(level)percent"
            let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            batteryButton.image = img
            batteryButton.contentTintColor = (b.percent <= 15 && !b.onAC) ? .systemRed : .white
            batteryButton.title = " \(b.percent)%"
            batteryButton.isHidden = false
        } else { batteryButton.isHidden = true }

        clockButton.title = clockFmt.string(from: Date())
    }

    @objc private func openWeather() {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.weather") {
            NSWorkspace.shared.openApplication(at: u, configuration: .init())
        }
    }
    @objc private func openCalendar() {
        if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: u, configuration: .init())
        }
    }
}
