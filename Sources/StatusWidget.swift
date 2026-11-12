import AppKit
import IOKit.ps
import CoreLocation

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

    /// iOS-style battery: the percentage sits inside the battery, the fill shows the level,
    /// and a bolt sits next to it while on power.
    static func image(percent: Int, charging: Bool, onAC: Bool) -> NSImage {
        let powered = charging || onAC
        let size = NSSize(width: powered ? 50 : 40, height: 20)
        return NSImage(size: size, flipped: false) { _ in
            let body = NSRect(x: 1, y: 2, width: 34, height: 16)
            let low = percent <= 15 && !onAC
            let fill: NSColor = powered ? NSColor.systemGreen.withAlphaComponent(0.75)
                : low ? NSColor.systemRed.withAlphaComponent(0.85) : NSColor(white: 1, alpha: 0.32)
            NSColor(white: 1, alpha: 0.6).setStroke()
            let outline = NSBezierPath(roundedRect: body, xRadius: 4.5, yRadius: 4.5); outline.lineWidth = 1.5; outline.stroke()
            NSColor(white: 1, alpha: 0.6).setFill()
            NSBezierPath(roundedRect: NSRect(x: 36.5, y: 7, width: 2.5, height: 6), xRadius: 1.2, yRadius: 1.2).fill()
            let inner = body.insetBy(dx: 2, dy: 2)
            let w = max(2, inner.width * CGFloat(min(100, max(0, percent))) / 100)
            fill.setFill()
            NSBezierPath(roundedRect: NSRect(x: inner.minX, y: inner.minY, width: w, height: inner.height), xRadius: 2.5, yRadius: 2.5).fill()
            let text = "\(percent)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .heavy), .foregroundColor: NSColor.white]
            let ts = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: body.midX - ts.width / 2, y: body.midY - ts.height / 2 + 0.5), withAttributes: attrs)
            if powered {
                let bolt = NSBezierPath()
                let x: CGFloat = 42
                bolt.move(to: NSPoint(x: x + 5, y: 19)); bolt.line(to: NSPoint(x: x, y: 9)); bolt.line(to: NSPoint(x: x + 3.5, y: 9))
                bolt.line(to: NSPoint(x: x + 2, y: 1)); bolt.line(to: NSPoint(x: x + 7.5, y: 11.5)); bolt.line(to: NSPoint(x: x + 4, y: 11.5)); bolt.close()
                NSColor.white.setFill(); bolt.fill()
            }
            return true
        }
    }
}

/// Where the weather is for: the Mac's own location when allowed, otherwise the city from Settings.
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()
    private let manager = CLLocationManager()
    private(set) var coordinate: CLLocationCoordinate2D?
    private(set) var place: String?
    private var lastRequest = Date.distantPast
    var onChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func refreshIfNeeded() {
        guard Settings.shared.weatherAuto, Date().timeIntervalSince(lastRequest) > 30 * 60 else { return }
        lastRequest = Date()
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorized: manager.requestLocation()
        default: break
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        if m.authorizationStatus == .authorizedAlways || m.authorizationStatus == .authorized { m.requestLocation() }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        // City-level is plenty for weather; don't keep more precision than that.
        coordinate = CLLocationCoordinate2D(latitude: (loc.coordinate.latitude * 100).rounded() / 100,
                                            longitude: (loc.coordinate.longitude * 100).rounded() / 100)
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] marks, _ in
            self?.place = marks?.first?.locality
            DispatchQueue.main.async { self?.onChange?() }
        }
        onChange?()
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        log("location unavailable: \(error.localizedDescription)")
    }
}

/// Current conditions from Open-Meteo (free, no API key). City-level coordinates only.
final class Weather {
    static let shared = Weather()
    private(set) var temp: Int?
    private(set) var symbol = "cloud.fill"
    private var lastFetch = Date.distantPast
    private var lastCoord: (Double, Double)?
    var onChange: (() -> Void)?

    var coordinate: (Double, Double) {
        if Settings.shared.weatherAuto, let c = LocationProvider.shared.coordinate { return (c.latitude, c.longitude) }
        return (Settings.shared.weatherLat, Settings.shared.weatherLon)
    }
    var placeName: String {
        if Settings.shared.weatherAuto, let p = LocationProvider.shared.place { return p }
        return Settings.shared.weatherCity
    }

    func refreshIfNeeded(force: Bool = false) {
        let c = coordinate
        let moved = lastCoord.map { abs($0.0 - c.0) > 0.05 || abs($0.1 - c.1) > 0.05 } ?? true
        guard force || moved || Date().timeIntervalSince(lastFetch) > 20 * 60 else { return }
        lastFetch = Date(); lastCoord = c
        let url = URL(string: "https://api.open-meteo.com/v1/forecast?latitude=\(c.0)&longitude=\(c.1)&current=temperature_2m,weather_code,is_day")!
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
    private let batteryView = NSImageView()
    private let clockButton = NSButton()
    private var timer: Timer?
    private let clockFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

    func makeItem() -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: Self.id)
        let s = Settings.shared
        for b in [weatherButton, clockButton] {
            b.isBordered = false
            b.imagePosition = .imageLeading
            b.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
            b.contentTintColor = .white
        }
        weatherButton.target = self; weatherButton.action = #selector(openWeather)
        clockButton.target = self; clockButton.action = #selector(openCalendar)
        var views: [NSView] = []
        if s.statusWeather { views.append(weatherButton) }
        if s.statusBattery { views.append(batteryView) }
        if s.statusClock { views.append(clockButton) }
        let row = NSStackView(views: views)
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 4)
        item.view = row
        item.visibilityPriority = .high

        Weather.shared.onChange = { [weak self] in self?.render() }
        LocationProvider.shared.onChange = { Weather.shared.refreshIfNeeded() }
        LocationProvider.shared.refreshIfNeeded()
        Weather.shared.refreshIfNeeded()
        render()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            LocationProvider.shared.refreshIfNeeded()
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
        weatherButton.toolTip = w.placeName

        if let b = Battery.read() {
            batteryView.image = Battery.image(percent: b.percent, charging: b.charging, onAC: b.onAC)
            batteryView.isHidden = false
        } else { batteryView.isHidden = true }

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
