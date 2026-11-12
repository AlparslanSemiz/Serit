import SwiftUI
import AppKit

final class CitySearch: ObservableObject {
    @Published var query = ""
    @Published var results: [(String, Double, Double)] = []
    @Published var searching = false
}

struct SettingsView: View {
    @ObservedObject var s = Settings.shared
    @ObservedObject var cs: CitySearch
    var onRefresh: () -> Void

    var body: some View {
        Form {
            Section {
                Toggle("Şerit açık", isOn: $s.enabled)
                Toggle("Tam genişlik (Control Strip'i gizle)", isOn: $s.fullWidth)
                    .disabled(!TouchBarHost.canShareWithControlStrip)
                if !TouchBarHost.canShareWithControlStrip {
                    Text("macOS Touch Bar ayarın \"Control Strip\" modunda; Şerit tam genişlikte gösteriliyor. Control Strip'i yanında istersen: Sistem Ayarları → Klavye → Touch Bar Ayarları → Touch Bar'da gösterilen: Uygulama Denetimleri, ve \"Control Strip'i göster\" açık.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Control Strip'te Şerit düğmesi", isOn: $s.showTrayButton)
            } header: { Text("Genel") }

            Section {
                Toggle(isOn: $s.showDock) { Label("Dock", systemImage: "dock.rectangle") }
                Toggle(isOn: $s.showMedia) { Label("Şu an çalan", systemImage: "music.note") }
                Toggle(isOn: $s.showVolume) { Label("Ses", systemImage: "speaker.wave.2.fill") }
                Toggle(isOn: $s.showBrightness) { Label("Parlaklık", systemImage: "sun.max.fill") }
                Toggle(isOn: $s.showStatus) { Label("Durum", systemImage: "clock") }
            } header: { Text("Widget'lar") } footer: {
                Text("Ses ve parlaklık: dokun → kaydırıcı açılır. Basılı tutup kaydır → doğrudan ayarlar.").foregroundStyle(.secondary)
            }

            Section {
                Toggle("Dock'ta sabitlenmiş uygulamaları göster", isOn: $s.dockPinned)
                Toggle("Bildirim rozetleri", isOn: $s.dockBadges)
                Toggle("Öndeki uygulamaya dokununca gizle", isOn: $s.dockTapFrontmostHides)
                Toggle("Finder'ı gizle", isOn: $s.dockHideFinder)
            } header: { Text("Dock") }

            Section {
                Toggle("Hava durumu", isOn: $s.statusWeather)
                Toggle("Pil", isOn: $s.statusBattery)
                Toggle("Saat", isOn: $s.statusClock)
                LabeledContent("Şehir", value: s.weatherCity)
                HStack {
                    TextField("Şehir ara", text: $cs.query).onSubmit(search)
                    Button(cs.searching ? "…" : "Ara", action: search).disabled(cs.query.isEmpty || cs.searching)
                }
                ForEach(cs.results.indices, id: \.self) { i in
                    Button(cs.results[i].0) {
                        s.weatherCity = cs.results[i].0.components(separatedBy: ",").first ?? cs.results[i].0
                        s.weatherLat = cs.results[i].1; s.weatherLon = cs.results[i].2
                        cs.results = []; cs.query = ""
                        Weather.shared.refreshIfNeeded(force: true)
                    }.buttonStyle(.link)
                }
            } header: { Text("Durum") }

            Section {
                HStack {
                    Button("Touch Bar'ı yenile", action: onRefresh)
                    Spacer()
                    Text(AXIsProcessTrusted() ? "Erişilebilirlik: açık ✓" : "Erişilebilirlik izni gerekli")
                        .foregroundStyle(AXIsProcessTrusted() ? Color.secondary : Color.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 640)
    }

    private func search() {
        guard !cs.query.isEmpty else { return }
        cs.searching = true
        let cs = self.cs
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: cs.query), .init(name: "count", value: "5"), .init(name: "language", value: "tr")]
        URLSession.shared.dataTask(with: c.url!) { data, _, _ in
            var out: [(String, Double, Double)] = []
            if let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let r = j["results"] as? [[String: Any]] {
                for x in r {
                    guard let n = x["name"] as? String, let la = x["latitude"] as? Double, let lo = x["longitude"] as? Double else { continue }
                    let extra = [x["admin1"] as? String, x["country"] as? String].compactMap { $0 }.joined(separator: ", ")
                    out.append((extra.isEmpty ? n : "\(n), \(extra)", la, lo))
                }
            }
            DispatchQueue.main.async { cs.results = out; cs.searching = false }
        }.resume()
    }
}

final class SettingsWindowController {
    private var window: NSWindow?
    func show(onRefresh: @escaping () -> Void) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(cs: CitySearch(), onRefresh: onRefresh)))
            w.title = "Şerit Ayarları"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
