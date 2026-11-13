import AppKit

/// Runs helper/nowplaying.m inside the system perl and keeps the latest answer.
/// macOS only tells Apple-signed processes what is playing; perl is one, Şerit isn't.
/// If the helper can't run, `alive` stays false and MediaWidget falls back to AppleScript.
final class NowPlayingHelper {
    static let shared = NowPlayingHelper()

    private(set) var alive = false
    private(set) var latest: NowPlaying?
    var onChange: ((NowPlaying?) -> Void)?

    private var process: Process?
    private var buffer = Data()
    private var recentStarts: [Date] = []

    private static let script = """
        require DynaLoader;
        my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
        my $sym = DynaLoader::dl_find_symbol($lib, "serit_np_stream") or die "symbol missing";
        DynaLoader::dl_install_xsub("main::stream", $sym);
        stream();
        """

    func start() {
        guard process == nil else { return }
        guard let lib = Bundle.main.path(forResource: "libseritnp", ofType: "dylib") else {
            log("now playing: helper library missing, using AppleScript"); return
        }
        // Don't spin if it keeps dying: at most 5 starts in 10 minutes.
        recentStarts = recentStarts.filter { Date().timeIntervalSince($0) < 600 }
        guard recentStarts.count < 5 else { log("now playing: helper keeps failing, using AppleScript"); return }
        recentStarts.append(Date())

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", Self.script, lib]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            DispatchQueue.main.async { self?.receive(data) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if !data.isEmpty, let s = String(data: data, encoding: .utf8) { log("now playing helper: \(s.trimmingCharacters(in: .whitespacesAndNewlines))") }
        }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                log("now playing: helper exited (\(proc.terminationStatus)), restarting")
                self.alive = false; self.process = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.start() }
            }
        }
        do {
            try p.run()
            process = p
            log("now playing: helper started (pid \(p.processIdentifier))")
        } catch {
            log("now playing: helper failed to start: \(error.localizedDescription)")
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let e = obj["error"] as? String { log("now playing helper: \(e)"); continue }
            alive = true
            let title = obj["title"] as? String ?? ""
            let artist = obj["artist"] as? String ?? ""
            let bid = (obj["bid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            var np: NowPlaying? = title.isEmpty ? nil
                : NowPlaying(title: title, artist: artist, playing: (obj["rate"] as? Double ?? 0) > 0, appBundleID: bid)
            if let b64 = obj["art"] as? String, let d = Data(base64Encoded: b64) { np?.artwork = NSImage(data: d) }
            else if let old = latest, old.title == title, old.appBundleID == bid { np?.artwork = old.artwork }
            if np != latest || np?.artwork !== latest?.artwork {
                log("now playing: \(np.map { "\($0.playing ? "▶" : "⏸") \($0.title) [\($0.appBundleID ?? "?")]" } ?? "nothing")")
            }
            latest = np
            onChange?(np)
        }
    }

    func stop() { process?.terminate() }
}
