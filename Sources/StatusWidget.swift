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

    /// iOS-style battery: a soft rounded body, the level as a fill, the percentage inside,
    /// and a small bolt inside the body while it's on power.
    static func image(percent: Int, charging: Bool, onAC: Bool) -> NSImage {
        let powered = charging || onAC
        let p = CGFloat(min(100, max(0, percent))) / 100
        return NSImage(size: NSSize(width: 42, height: 20), flipped: false) { _ in
            let body = NSRect(x: 1, y: 2.5, width: 35, height: 15)
            let low = percent <= 20 && !powered
            // body
            NSColor(white: 1, alpha: 0.18).setFill()
            NSBezierPath(roundedRect: body, xRadius: 5, yRadius: 5).fill()
            // level
            let top: NSColor = powered ? NSColor(srgbRed: 0.33, green: 0.86, blue: 0.47, alpha: 1)
                : low ? NSColor(srgbRed: 1.0, green: 0.36, blue: 0.33, alpha: 1) : NSColor(white: 1, alpha: 0.58)
            let bottom: NSColor = powered ? NSColor(srgbRed: 0.20, green: 0.72, blue: 0.35, alpha: 1)
                : low ? NSColor(srgbRed: 0.88, green: 0.22, blue: 0.22, alpha: 1) : NSColor(white: 1, alpha: 0.42)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: body, xRadius: 5, yRadius: 5).addClip()
            NSGradient(colors: [top, bottom])!.draw(in: NSRect(x: body.minX, y: body.minY, width: body.width * max(p, 0.06), height: body.height), angle: -90)
            NSGraphicsContext.restoreGraphicsState()
            // nub
            NSColor(white: 1, alpha: 0.45).setFill()
            let nub = NSBezierPath()
            nub.move(to: NSPoint(x: 37.2, y: 7)); nub.line(to: NSPoint(x: 37.2, y: 13))
            nub.curve(to: NSPoint(x: 37.2, y: 7), controlPoint1: NSPoint(x: 40.3, y: 12.5), controlPoint2: NSPoint(x: 40.3, y: 7.5))
            nub.fill()
            // Percentage: white over the empty part, dark over the fill, split exactly at the
            // fill edge so it reads at any level.
            let fillRect = NSRect(x: body.minX, y: body.minY, width: body.width * max(p, 0.06), height: body.height)
            let font = NSFont.systemFont(ofSize: 11, weight: .bold)
            let rounded = font.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 11) } ?? font
            let text = "\(percent)" as NSString
            let ts = text.size(withAttributes: [.font: rounded])
            let boltW: CGFloat = powered ? 7 : 0
            let x = body.midX - (ts.width + boltW) / 2
            let textPoint = NSPoint(x: x + boltW, y: body.midY - ts.height / 2 + 0.5)
            // White digits over a translucent fill read at every level; a faint shadow lifts them.
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = NSColor(white: 0, alpha: 0.55); shadow.shadowBlurRadius = 1.2; shadow.shadowOffset = .zero
            shadow.set()
            text.draw(at: textPoint, withAttributes: [.font: rounded, .foregroundColor: NSColor.white])
            NSGraphicsContext.restoreGraphicsState()
            if powered {
                let bx = x - 1, by = body.minY + 2.5
                let bolt = NSBezierPath()
                bolt.move(to: NSPoint(x: bx + 5, y: by + 10)); bolt.line(to: NSPoint(x: bx + 1, y: by + 4.5)); bolt.line(to: NSPoint(x: bx + 3.6, y: by + 4.5))
                bolt.line(to: NSPoint(x: bx + 2.6, y: by)); bolt.line(to: NSPoint(x: bx + 6.4, y: by + 5.6)); bolt.line(to: NSPoint(x: bx + 3.8, y: by + 5.6)); bolt.close()
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
