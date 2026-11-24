// OWNER: workstream C (app-ui).
import AppKit
import Foundation
import Observation

/// What Spotify is playing, and its controls. Spotify only: TikTok, YouTube and other apps are ignored.
///
/// Two sources, in order:
/// 1. Spotify's web player in Chrome, read from its tab (`SpotifyWebBridge`): exact, and never confused by
///    another tab that is playing sound.
/// 2. macOS's Now Playing (MediaRemote) when the Spotify desktop app is the player. macOS 15.4+ only answers
///    MediaRemote for Apple-signed clients, so a small helper library (`helpers/now-playing/NowPlayingHelper.m`,
///    bundled as Resources/now-playing/NowPlayingHelper.dylib) runs inside `/usr/bin/perl` and talks JSON lines.
///    With Chrome's JavaScript setting off, Now Playing is also used for a Chrome player, but only while it is
///    the Spotify tab (its title matches).
@MainActor
@Observable
final class NowPlaying {
    struct Track: Equatable {
        var id: String
        var name: String
        var artist: String
        var album: String
        /// Seconds; 0 when unknown.
        var duration: TimeInterval
    }

    private(set) var track: Track?
    private(set) var isPlaying = false
    private(set) var repeating = false
    private(set) var shuffling = false
    private(set) var artwork: NSImage?
    /// Playback position at `positionAt`; while playing it advances with the clock.
    private(set) var position: TimeInterval = 0
    private(set) var positionAt = Date()
    /// Shown in the player when the controls cannot work.
    private(set) var problem: String?

    /// Something is loaded (playing or paused).
    var isActive: Bool { track != nil }

    func position(at now: Date) -> TimeInterval {
        let p = isPlaying ? position + now.timeIntervalSince(positionAt) : position
        guard let d = track?.duration, d > 0 else { return max(0, p) }
        return min(max(0, p), d)
    }

    /// The player reports its own repeat mode (Spotify's app). Otherwise (a web player) notchAgent loops the
    /// song itself by seeking back to the start just before it ends.
    @ObservationIgnored private var playerRepeats = false
    @ObservationIgnored private var playerShuffles = false
    @ObservationIgnored private var helper: Process?
    @ObservationIgnored private var input: FileHandle?
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private var restarts = 0
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var loopTimer: Timer?
    /// The latest Now Playing report and the latest Spotify-tab reading.
    @ObservationIgnored private var system: SystemPlayer?
    @ObservationIgnored private var tab: SpotifyWebBridge.Result = .noTab
    @ObservationIgnored private var tabAt: Date?
    @ObservationIgnored private let web = SpotifyWebBridge()
    @ObservationIgnored private var nextTabPoll = Date.distantPast
    @ObservationIgnored private var tabPolling = false
    @ObservationIgnored private var artworkURL: String?
    /// Which source the player shows right now.
    @ObservationIgnored private var mode: Mode = .none
    private enum Mode { case none, tab, system }

    /// One Now Playing report.
    private struct SystemPlayer {
        var title, artist, album: String
        var duration, elapsed: TimeInterval
        var at: Date
        var playing: Bool
        var repeatMode, shuffleMode: Int?
        var bundleID: String?
        var artwork: NSImage?
    }

    // MARK: Lifecycle

    func start() {
        stopped = false
        launchHelper()
        loopTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.loopIfNeeded()
                self?.pollTabIfDue()
            }
        }
    }

    func stop() {
        stopped = true
        loopTimer?.invalidate()
        try? input?.close()
        helper?.terminate()
        helper = nil
    }

    /// For snapshots: a fixed track, no helper.
    func showForSnapshot(_ track: Track, playing: Bool, position: TimeInterval, at: Date, repeating: Bool = false) {
        self.track = track
        isPlaying = playing
        self.position = position
        positionAt = at
        self.repeating = repeating
    }

    /// The helper polls by itself; nothing to do. Kept so opening the player can ask for fresh state later.
    func refreshIfRunning() {}

    static let loader = """
    require DynaLoader; my $l = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error(); \
    my $s = DynaLoader::dl_find_symbol($l, "notchagent_now_playing_main") or die "no entry point"; \
    DynaLoader::dl_install_xsub("main::np", $s); np();
    """

    private func launchHelper() {
        guard !stopped else { return }
        guard let lib = Bundle.main.resourceURL?.appendingPathComponent("now-playing/NowPlayingHelper.dylib"),
              FileManager.default.fileExists(atPath: lib.path) else {
            Log.info("now playing: helper library missing from the app bundle (run scripts/bundle.sh)")
            problem = "Now Playing helper missing; rebuild with scripts/bundle.sh"
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", Self.loader, lib.path]
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardInput = inp
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(data) } }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.helperExited(status) } }
        }
        do {
            try p.run()
            helper = p
            input = inp.fileHandleForWriting
        } catch {
            Log.info("now playing: cannot start helper: \(error)")
        }
    }

    private func helperExited(_ status: Int32) {
        helper = nil
        input = nil
        guard !stopped else { return }
        restarts += 1
        Log.info("now playing: helper exited (\(status)); restart \(restarts)")
        guard restarts <= 5 else {
            problem = "Now Playing is unavailable"
            clear()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(restarts) * 2) { [weak self] in
            MainActor.assumeIsolated { self?.launchHelper() }
        }
    }

    // MARK: Reading Now Playing

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { ingest(obj) }
        }
    }

    private func ingest(_ o: [String: Any]) {
        restarts = 0
        let pid = (o["pid"] as? NSNumber)?.int32Value ?? 0
        var art = system?.artwork
        if let a = o["art"] as? String {
            art = a.isEmpty ? nil : Data(base64Encoded: a).flatMap(NSImage.init(data:))
            // A player with no album art hands over its app icon: never show that.
            if let image = art, pid > 0, Self.isAppIcon(image, pid: pid) { art = nil }
        }
        guard let title = o["title"] as? String, !title.isEmpty else {
            system = nil
            recompute()
            return
        }
        system = SystemPlayer(
            title: title, artist: o["artist"] as? String ?? "", album: o["album"] as? String ?? "",
            duration: (o["duration"] as? NSNumber)?.doubleValue ?? 0,
            elapsed: (o["elapsed"] as? NSNumber)?.doubleValue ?? 0,
            at: (o["at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date(),
            playing: ((o["rate"] as? NSNumber)?.doubleValue ?? 0) > 0,
            repeatMode: (o["repeat"] as? NSNumber)?.intValue, shuffleMode: (o["shuffle"] as? NSNumber)?.intValue,
            bundleID: pid > 0 ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier : nil,
            artwork: art)
        recompute()
    }

    // MARK: Reading the Spotify tab

    private func pollTabIfDue(force: Bool = false) {
        guard !tabPolling, force || Date() >= nextTabPoll else { return }
        guard SpotifyWebBridge.chromeRunning else {
            if tabAt != nil || tab != .noTab { tab = .noTab; tabAt = nil; recompute() }
            nextTabPoll = Date().addingTimeInterval(3)
            return
        }
        tabPolling = true
        web.poll { [weak self] result in
            MainActor.assumeIsolated { self?.applyTab(result) }
        }
    }

    private func applyTab(_ result: SpotifyWebBridge.Result) {
        tabPolling = false
        let now = Date()
        tab = result
        tabAt = now
        switch result {
        case .ok, .tabOnly: nextTabPoll = now.addingTimeInterval(1)
        case .noTab: nextTabPoll = now.addingTimeInterval(4)
        case .denied: nextTabPoll = now.addingTimeInterval(15)
        case .failed(let why):
            nextTabPoll = now.addingTimeInterval(4)
            Log.info("spotify web: \(why)")
        }
        recompute()
    }

    private var tabFresh: Bool { tabAt.map { Date().timeIntervalSince($0) < 4 } ?? false }

    // MARK: Choosing what to show

    /// Spotify only: the tab when it answers, else the Spotify app (or, with Chrome's JavaScript setting off, a
    /// Chrome player whose title matches the Spotify tab). Anything else clears the player.
    private func recompute() {
        if tabFresh, case .ok(let s) = tab {
            showTab(s)
            return
        }
        if let sys = system, isSpotify(sys) {
            showSystem(sys)
            return
        }
        mode = .none
        clear()
        problem = Self.hint(for: tab)
    }

    private func isSpotify(_ sys: SystemPlayer) -> Bool {
        if sys.bundleID == "com.spotify.client" { return true }
        // With only the tab title ("Song • Artist"), accept Chrome's player when it is that song.
        if sys.bundleID == SpotifyWebBridge.chromeBundleID, tabFresh, case .tabOnly(let title) = tab {
            return title.localizedCaseInsensitiveContains(sys.title)
        }
        return false
    }

    private static func hint(for tab: SpotifyWebBridge.Result) -> String? {
        switch tab {
        case .tabOnly: return "For exact sync: Chrome › View › Developer › Allow JavaScript from Apple Events"
        case .denied: return "Allow notchAgent to control Chrome: System Settings › Privacy & Security › Automation"
        default: return nil
        }
    }

    private func showTab(_ s: SpotifyWebBridge.State) {
        mode = .tab
        let id = "\(s.title)\u{1F}\(s.artist)\u{1F}\(s.album)"
        let duration = s.duration > 0 ? s.duration : (track?.id == id ? track?.duration ?? 0 : 0)
        track = Track(id: id, name: s.title, artist: s.artist, album: s.album, duration: duration)
        isPlaying = s.playing
        // Keep the local clock when the tab agrees within a second, so the bar does not stutter.
        let now = Date()
        if abs(position(at: now) - s.position) > 1.0 || !s.playing {
            position = s.position
            positionAt = now
        }
        shuffling = s.shuffle
        repeating = s.repeating
        playerRepeats = true
        playerShuffles = true
        problem = nil
        loadArtwork(s.artworkURL)
    }

    private func showSystem(_ sys: SystemPlayer) {
        let id = "\(sys.title)\u{1F}\(sys.artist)\u{1F}\(sys.album)"
        if mode == .system, track?.id != id, sys.repeatMode == nil, track != nil {
            repeating = false  // notchAgent's own loop covers only the song it was turned on for
        }
        mode = .system
        track = Track(id: id, name: sys.title, artist: sys.artist, album: sys.album, duration: sys.duration)
        isPlaying = sys.playing
        position = sys.elapsed
        positionAt = sys.at
        if let r = sys.repeatMode { playerRepeats = true; repeating = r >= 2 } else { playerRepeats = false }
        if let s = sys.shuffleMode { playerShuffles = true; shuffling = s >= 2 } else { playerShuffles = false }
        artworkURL = nil
        artwork = sys.artwork
        problem = Self.hint(for: tab)
    }

    private func loadArtwork(_ urlString: String) {
        guard urlString != artworkURL else { return }
        artworkURL = urlString
        guard let url = URL(string: urlString), url.scheme == "https" else { artwork = nil; return }
        Task { [weak self] in
            let data = try? await URLSession.shared.data(from: url).0
            guard let self, self.artworkURL == urlString else { return }
            self.artwork = data.flatMap(NSImage.init(data:))
        }
    }

    /// True when `art` is just the player app's icon (Chrome's logo and the like): compared at 16 x 16 over the
    /// icon's opaque pixels. Real album art scores far apart (measured: an icon ~41, album art ~166).
    static func isAppIcon(_ art: NSImage, pid: pid_t) -> Bool {
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon else { return false }
        let a = thumbnail(art), b = thumbnail(icon)
        guard a.count == b.count else { return false }
        var sum = 0.0, n = 0.0
        for p in stride(from: 0, to: b.count, by: 4) where b[p + 3] > 128 {
            for c in 0..<3 { sum += abs(Double(a[p + c]) - Double(b[p + c])) }
            n += 3
        }
        return n > 0 && sum / n < 80
    }

    private static func thumbnail(_ image: NSImage, side: Int = 16) -> [UInt8] {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: side * 4, bitsPerPixel: 32),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return [] }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: side * side * 4))
    }

    private func clear() {
        track = nil
        isPlaying = false
        artwork = nil
        artworkURL = nil
        repeating = false
        shuffling = false
    }

    // MARK: Controls

    func playPause() {
        let now = Date()
        position = position(at: now)
        positionAt = now
        isPlaying.toggle()
        control(.playPause, system: "toggle")
    }

    func next() { control(.next, system: "next") }
    func previous() { control(.previous, system: "prev") }

    func toggleRepeat() {
        repeating.toggle()
        if mode == .tab {
            control(.repeating, system: nil)
        } else if playerRepeats {
            send("repeat")
        }
    }

    func toggleShuffle() {
        shuffling.toggle()
        if mode == .tab {
            control(.shuffle, system: nil)
            return
        }
        send("shuffle")
        if !playerShuffles {
            // The player does not take shuffle this way; drop the green state again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.playerShuffles else { return }
                    self.shuffling = false
                }
            }
        }
    }

    func seek(toFraction fraction: Double) {
        guard let d = track?.duration, d > 0 else { return }
        seek(to: max(0, min(1, fraction)) * d)
    }

    private func seek(to seconds: TimeInterval) {
        position = seconds
        positionAt = Date()
        send("seek \(seconds)")
        if mode == .tab { refreshTabSoon(0.5) }
    }

    /// Presses the tab's own button when the tab is the source; otherwise sends the Now Playing command.
    private func control(_ button: SpotifyWebBridge.Button, system command: String?) {
        if mode == .tab {
            web.press(button) { [weak self] in
                MainActor.assumeIsolated { self?.refreshTabSoon(0.3) }
            }
        } else if let command {
            send(command)
        }
    }

    private func refreshTabSoon(_ delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.pollTabIfDue(force: true) }
        }
    }

    /// notchAgent's own loop (a player that does not report repeat): back to the start just before the end.
    private func loopIfNeeded() {
        guard mode == .system, repeating, !playerRepeats, isPlaying, let d = track?.duration, d > 3 else { return }
        if d - position(at: Date()) < 1.2 { seek(to: 0) }
    }

    private func send(_ command: String) {
        guard let input else { return }
        try? input.write(contentsOf: Data((command + "\n").utf8))
    }
}
