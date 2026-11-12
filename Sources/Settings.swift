import Foundation
import Combine

func log(_ s: String) {
    FileHandle.standardError.write("\(Date()) \(s)\n".data(using: .utf8)!)
}

/// All user-facing settings, persisted in UserDefaults. Changing anything posts
/// `Settings.changed`, and the app rebuilds the Touch Bar.
final class Settings: ObservableObject {
    static let shared = Settings()
    static let changed = Notification.Name("SeritSettingsChanged")
    private let d = UserDefaults.standard
    private var bag = Set<AnyCancellable>()

    // General
    @Published var enabled: Bool
    @Published var fullWidth: Bool
    @Published var showTrayButton: Bool
    // Widgets
    @Published var showDock: Bool
    @Published var showMedia: Bool
    @Published var showVolume: Bool
    @Published var showBrightness: Bool
    @Published var showStatus: Bool
    @Published var showScreenshot: Bool
    @Published var showAppKeys: Bool
    // Dock
    @Published var dockPinned: Bool
    @Published var dockBadges: Bool
    @Published var dockHideFinder: Bool
    @Published var dockTapFrontmostHides: Bool
    // Status
    @Published var statusWeather: Bool
    @Published var statusBattery: Bool
    @Published var statusClock: Bool
    @Published var weatherAuto: Bool
    @Published var weatherCity: String
    @Published var weatherLat: Double
    @Published var weatherLon: Double

    private init() {
        let defaults = UserDefaults.standard
        func b(_ k: String, _ def: Bool) -> Bool { defaults.object(forKey: k) as? Bool ?? def }
        enabled = b("enabled", true)
        fullWidth = b("fullWidth", false)
        showTrayButton = b("showTrayButton", true)
        showDock = b("showDock", true)
        showMedia = b("showMedia", true)
        showVolume = b("showVolume", true)
        showBrightness = b("showBrightness", true)
        showStatus = b("showStatus", true)
        showScreenshot = b("showScreenshot", true)
        showAppKeys = b("showAppKeys", true)
        dockPinned = b("dockPinned", false)
        dockBadges = b("dockBadges", true)
        dockHideFinder = b("dockHideFinder", false)
        dockTapFrontmostHides = b("dockTapFrontmostHides", true)
        statusWeather = b("statusWeather", true)
        statusBattery = b("statusBattery", true)
        statusClock = b("statusClock", true)
        weatherAuto = b("weatherAuto", true)
        weatherCity = defaults.string(forKey: "weatherCity") ?? "Karlsruhe"
        weatherLat = defaults.object(forKey: "weatherLat") as? Double ?? 49.0094
        weatherLon = defaults.object(forKey: "weatherLon") as? Double ?? 8.4044

        // Persist + notify on every change (debounced so a burst of edits rebuilds once).
        let mirror: [(String, AnyPublisher<Any, Never>)] = [
            ("enabled", $enabled.map { $0 as Any }.eraseToAnyPublisher()),
            ("fullWidth", $fullWidth.map { $0 as Any }.eraseToAnyPublisher()),
            ("showTrayButton", $showTrayButton.map { $0 as Any }.eraseToAnyPublisher()),
            ("showDock", $showDock.map { $0 as Any }.eraseToAnyPublisher()),
            ("showMedia", $showMedia.map { $0 as Any }.eraseToAnyPublisher()),
            ("showVolume", $showVolume.map { $0 as Any }.eraseToAnyPublisher()),
            ("showBrightness", $showBrightness.map { $0 as Any }.eraseToAnyPublisher()),
            ("showStatus", $showStatus.map { $0 as Any }.eraseToAnyPublisher()),
            ("showScreenshot", $showScreenshot.map { $0 as Any }.eraseToAnyPublisher()),
            ("showAppKeys", $showAppKeys.map { $0 as Any }.eraseToAnyPublisher()),
            ("dockPinned", $dockPinned.map { $0 as Any }.eraseToAnyPublisher()),
            ("dockBadges", $dockBadges.map { $0 as Any }.eraseToAnyPublisher()),
            ("dockHideFinder", $dockHideFinder.map { $0 as Any }.eraseToAnyPublisher()),
            ("dockTapFrontmostHides", $dockTapFrontmostHides.map { $0 as Any }.eraseToAnyPublisher()),
            ("statusWeather", $statusWeather.map { $0 as Any }.eraseToAnyPublisher()),
            ("statusBattery", $statusBattery.map { $0 as Any }.eraseToAnyPublisher()),
            ("statusClock", $statusClock.map { $0 as Any }.eraseToAnyPublisher()),
            ("weatherAuto", $weatherAuto.map { $0 as Any }.eraseToAnyPublisher()),
            ("weatherCity", $weatherCity.map { $0 as Any }.eraseToAnyPublisher()),
            ("weatherLat", $weatherLat.map { $0 as Any }.eraseToAnyPublisher()),
            ("weatherLon", $weatherLon.map { $0 as Any }.eraseToAnyPublisher()),
        ]
        for (key, pub) in mirror {
            pub.dropFirst().sink { [d] v in d.set(v, forKey: key) }.store(in: &bag)
        }
        Publishers.MergeMany(mirror.map { $0.1.dropFirst().map { _ in () }.eraseToAnyPublisher() })
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { NotificationCenter.default.post(name: Settings.changed, object: nil) }
            .store(in: &bag)
    }
}
