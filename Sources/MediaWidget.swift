import AppKit

struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var playing: Bool
    var appBundleID: String?
    var artwork: NSImage?
    static func == (a: NowPlaying, b: NowPlaying) -> Bool {
        a.title == b.title && a.artist == b.artist && a.playing == b.playing && a.appBundleID == b.appBundleID
    }
}

/// Finds what's playing. MediaRemote (works for every player incl. browsers) when the
/// OS still allows it; otherwise asks Spotify / Music directly, only if they're running.
enum NowPlayingSource {
    private static let mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)

    static func fetch(_ done: @escaping (NowPlaying?) -> Void) {
        fetchMediaRemote { info in
            if let info, !info.title.isEmpty { done(info); return }
            DispatchQueue.global(qos: .utility).async {
                let r = fetchAppleScript()
                DispatchQueue.main.async { done(r) }
            }
        }
    }

    private static func fetchMediaRemote(_ done: @escaping (NowPlaying?) -> Void) {
        guard let mr, let sym = dlsym(mr, "MRMediaRemoteGetNowPlayingInfo") else { done(nil); return }
        typealias F = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
        var finished = false
        let finish: (NowPlaying?) -> Void = { r in if !finished { finished = true; done(r) } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { finish(nil) }   // entitlement-blocked calls never answer
        unsafeBitCast(sym, to: F.self)(DispatchQueue.main) { dict in
            guard let d = dict as? [String: Any], let title = d["kMRMediaRemoteNowPlayingInfoTitle"] as? String else { finish(nil); return }
            let rate = d["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
            let art = (d["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data).flatMap(NSImage.init(data:))
            finish(NowPlaying(title: title, artist: d["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? "",
                              playing: rate > 0, appBundleID: nil, artwork: art))
        }
    }

    private static func running(_ bid: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty
    }

    private static func run(_ src: String) -> [String]? {
        var err: NSDictionary?
        guard let out = NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue, err == nil else { return nil }
        return out.components(separatedBy: "\n")
    }

    private static func fetchAppleScript() -> NowPlaying? {
        var candidates: [NowPlaying] = []
        if running("com.spotify.client"), let p = run("""
            tell application id "com.spotify.client"
              if player state is stopped then return ""
              return (name of current track) & "\n" & (artist of current track) & "\n" & (player state as string) & "\n" & (artwork url of current track)
            end tell
            """), p.count >= 3 {
            var np = NowPlaying(title: p[0], artist: p[1], playing: p[2] == "playing", appBundleID: "com.spotify.client")
            if p.count >= 4, let u = URL(string: p[3]) { np.artwork = ArtworkCache.image(for: u) }
            candidates.append(np)
        }
        if running("com.apple.Music"), let p = run("""
            tell application id "com.apple.Music"
              if player state is stopped then return ""
              return (name of current track) & "\n" & (artist of current track) & "\n" & (player state as string)
            end tell
            """), p.count >= 3 {
            candidates.append(NowPlaying(title: p[0], artist: p[1], playing: p[2] == "playing", appBundleID: "com.apple.Music"))
        }
        if candidates.first(where: { $0.playing }) == nil, let web = fetchBrowser() { candidates.insert(web, at: 0) }
        return candidates.first(where: { $0.playing }) ?? candidates.first
    }

    /// YouTube Music / YouTube in a browser tab. The tab title carries the song
    /// ("Song - YouTube Music"); browsers don't expose play state, so it counts as playing.
    static let browsers = ["com.brave.Browser", "com.google.Chrome", "company.thebrowser.Browser", "com.apple.Safari"]
    private static func fetchBrowser() -> NowPlaying? {
        for bid in browsers where running(bid) {
            let isSafari = bid == "com.apple.Safari"
            let titleProp = isSafari ? "name" : "title"
            guard let lines = run("""
                set out to ""
                tell application id "\(bid)"
                  repeat with w in windows
                    repeat with t in tabs of w
                      set u to URL of t
                      if u contains "music.youtube.com" or u contains "youtube.com/watch" then set out to out & (\(titleProp) of t) & "\t" & u & "\n"
                    end repeat
                  end repeat
                end tell
                return out
                """) else { continue }
            let tabs = lines.filter { !$0.isEmpty }.map { $0.components(separatedBy: "\t") }
            // Prefer YouTube Music, then a YouTube video.
            let pick = tabs.first { $0.count > 1 && $0[1].contains("music.youtube.com") } ?? tabs.first
            guard let t = pick, var title = t.first, !title.isEmpty else { continue }
            for suffix in [" - YouTube Music", " - YouTube"] where title.hasSuffix(suffix) { title.removeLast(suffix.count) }
            if title == "YouTube Music" || title == "YouTube" || title.isEmpty { continue }
            // "Song • Artist" or "Song - Artist" when the title has both.
            var artist = ""
            for sep in [" • ", " · "] where title.contains(sep) {
                let parts = title.components(separatedBy: sep); title = parts[0]; artist = parts.dropFirst().joined(separator: sep)
            }
            return NowPlaying(title: title, artist: artist, playing: true, appBundleID: bid)
        }
        return nil
    }
}

enum ArtworkCache {
    private static var cache: [URL: NSImage] = [:]
    static func image(for url: URL) -> NSImage? {
        if let i = cache[url] { return i }
        guard let data = try? Data(contentsOf: url), let img = NSImage(data: data) else { return nil }
        cache = [url: img]   // keep only the current one
        return img
    }
}

enum MediaKeys {
    static let play: Int32 = 16, next: Int32 = 17, previous: Int32 = 18

    /// Same events the physical media keys send, so it controls whatever is playing.
    static func press(_ key: Int32) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((key << 16) | ((down ? 0xA : 0xB) << 8))
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                               windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

final class MediaWidget: NSObject {
    static let id = NSTouchBarItem.Identifier("local.serit.media")
    private let art = NSImageView()
    private let label = MarqueeLabel()
    private let infoButton = NSButton()
    private var current: NowPlaying?
    private var timer: Timer?

    // swiftlint:disable:next function_body_length
    func makeItem() -> NSTouchBarItem {
        let item = NSCustomTouchBarItem(identifier: Self.id)

        art.imageScaling = .scaleProportionallyUpOrDown
        art.wantsLayer = true
        art.layer?.cornerRadius = 4
        art.layer?.masksToBounds = true
        art.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([art.widthAnchor.constraint(equalToConstant: 22), art.heightAnchor.constraint(equalToConstant: 22)])

        // Up to 170 pt; when the bar is full it gives way first and scrolls instead.
        label.maxWidth = 170
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true

        // Tapping the artwork/title brings the player forward.
        let info = NSStackView(views: [art, label])
        info.spacing = 6
        infoButton.isBordered = false
        infoButton.title = ""
        infoButton.target = self; infoButton.action = #selector(openPlayer)
        infoButton.translatesAutoresizingMaskIntoConstraints = false
        info.translatesAutoresizingMaskIntoConstraints = false
        let infoWrap = NSView()
        infoWrap.addSubview(info); infoWrap.addSubview(infoButton)
        NSLayoutConstraint.activate([
            info.leadingAnchor.constraint(equalTo: infoWrap.leadingAnchor, constant: 4),
            info.trailingAnchor.constraint(equalTo: infoWrap.trailingAnchor),
            info.centerYAnchor.constraint(equalTo: infoWrap.centerYAnchor),
            infoButton.leadingAnchor.constraint(equalTo: infoWrap.leadingAnchor),
            infoButton.trailingAnchor.constraint(equalTo: infoWrap.trailingAnchor),
            infoButton.topAnchor.constraint(equalTo: infoWrap.topAnchor),
            infoButton.bottomAnchor.constraint(equalTo: infoWrap.bottomAnchor),
        ])

        func control(_ symbol: String, _ sel: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!, target: self, action: sel)
            b.bezelColor = NSColor(white: 0.38, alpha: 1)
            b.contentTintColor = .white
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 46).isActive = true
            return b
        }
        let play = control("playpause.fill", #selector(togglePlay))
        let next = control("forward.fill", #selector(nextTrack))

        let row = NSStackView(views: [infoWrap, play, next])
        row.spacing = 4
        item.view = row
        item.visibilityPriority = .normal
        playToggle = play

        update(nil)
        // The helper pushes changes as they happen; the timer is only the AppleScript fallback.
        NowPlayingHelper.shared.onChange = { [weak self] np in
            guard let self, np != self.current || np?.artwork !== self.current?.artwork else { return }
            self.update(np)
        }
        NowPlayingHelper.shared.start()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
        poll()
        return item
    }
    private weak var playToggle: NSButton?

    deinit { timer?.invalidate() }

    private func poll() {
        // The helper knows exactly what is playing (including which browser tab); trust it,
        // even when it says "nothing". AppleScript guessing is only for when it can't run.
        if NowPlayingHelper.shared.alive {
            let np = NowPlayingHelper.shared.latest
            if np != current || np?.artwork !== current?.artwork { update(np) }
            return
        }
        NowPlayingSource.fetch { [weak self] np in
            guard let self, np != self.current || np?.artwork !== self.current?.artwork else { return }
            self.update(np)
        }
    }

    static let titleVisibilityChanged = Notification.Name("SeritMediaTitleVisibility")
    private var titleShown: Bool?

    private func update(_ np: NowPlaying?) {
        current = np
        let shows = !(np?.title.isEmpty ?? true)
        if shows != titleShown {
            titleShown = shows
            NotificationCenter.default.post(name: Self.titleVisibilityChanged, object: nil, userInfo: ["shown": shows])
        }
        if let np, !np.title.isEmpty {
            label.text = np.artist.isEmpty ? np.title : "\(np.title) · \(np.artist)"
            label.textColor = np.playing ? .white : NSColor.white.withAlphaComponent(0.55)
            if let a = np.artwork { art.image = a }
            else if let bid = np.appBundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
                art.image = NSWorkspace.shared.icon(forFile: url.path)
            } else { art.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil) }
            art.isHidden = false; label.isHidden = false
            playToggle?.image = NSImage(systemSymbolName: np.playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        } else {
            // Unknown source (e.g. a browser tab): keep the controls, hide the empty title.
            art.isHidden = true; label.isHidden = true
            playToggle?.image = NSImage(systemSymbolName: "playpause.fill", accessibilityDescription: nil)
        }
    }

    @objc private func togglePlay() { MediaKeys.press(MediaKeys.play); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.poll() } }
    @objc private func nextTrack() { MediaKeys.press(MediaKeys.next); DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.poll() } }
    @objc private func openPlayer() {
        if let bid = current?.appBundleID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first {
            app.activate()
        }
    }
}
