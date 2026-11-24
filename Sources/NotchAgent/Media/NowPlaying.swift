// OWNER: workstream C (app-ui).
import AppKit
import Foundation
import Observation

/// What the system is playing (the "Now Playing" of Control Center: Spotify's app or web player, Apple Music,
/// a browser tab...) and its controls.
///
/// macOS 15.4+ only answers MediaRemote for Apple-signed clients, so a small helper library
/// (`helpers/now-playing/NowPlayingHelper.m`, bundled as Resources/now-playing/NowPlayingHelper.dylib) runs
/// inside `/usr/bin/perl` and talks JSON lines over a pipe. No permission prompt is involved.
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
    @ObservationIgnored private var rawArtwork: NSImage?
    @ObservationIgnored private var artworkPID: pid_t = -1

    // MARK: Lifecycle

    func start() {
        stopped = false
        launchHelper()
        loopTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.loopIfNeeded() }
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

    // MARK: Reading

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
        if let art = o["art"] as? String {
            rawArtwork = art.isEmpty ? nil : Data(base64Encoded: art).flatMap(NSImage.init(data:))
            artworkPID = -1
        }
        // A player with no album art (a browser tab) hands over its app icon: never show that.
        if pid > 0, pid != artworkPID {
            artworkPID = pid
            artwork = rawArtwork.flatMap { Self.isAppIcon($0, pid: pid) ? nil : $0 }
        } else if pid <= 0 {
            artwork = rawArtwork
        }
        guard let title = o["title"] as? String, !title.isEmpty else {
            clear()
            return
        }
        let artist = o["artist"] as? String ?? ""
        let album = o["album"] as? String ?? ""
        let duration = (o["duration"] as? NSNumber)?.doubleValue ?? 0
        let newTrack = Track(id: "\(title)\u{1F}\(artist)\u{1F}\(album)", name: title, artist: artist, album: album,
                             duration: duration)
        if track?.id != newTrack.id, !playerRepeats {
            // A new song: notchAgent's own loop applies to the song it was turned on for only.
            if track != nil { repeating = false }
        }
        track = newTrack
        isPlaying = ((o["rate"] as? NSNumber)?.doubleValue ?? 0) > 0
        position = (o["elapsed"] as? NSNumber)?.doubleValue ?? 0
        positionAt = (o["at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
        // MediaRemote modes: 1 = off; 2 / 3 = on (one / all).
        if let r = (o["repeat"] as? NSNumber)?.intValue {
            playerRepeats = true
            repeating = r >= 2
        } else {
            playerRepeats = false
        }
        if let s = (o["shuffle"] as? NSNumber)?.intValue {
            playerShuffles = true
            shuffling = s >= 2
        } else {
            playerShuffles = false
        }
        problem = nil
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
        rawArtwork = nil
        artworkPID = -1
        repeating = false
    }

    // MARK: Controls

    func playPause() {
        let now = Date()
        position = position(at: now)
        positionAt = now
        isPlaying.toggle()
        send("toggle")
    }

    func next() { send("next") }
    func previous() { send("prev") }

    func toggleRepeat() {
        repeating.toggle()
        if playerRepeats { send("repeat") }
    }

    func toggleShuffle() {
        shuffling.toggle()
        // Web players do not take shuffle through Now Playing; the green state then only reflects the click.
        send("shuffle")
        if !playerShuffles {
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
    }

    /// notchAgent's own loop (players that do not report repeat): back to the start just before the end.
    private func loopIfNeeded() {
        guard repeating, !playerRepeats, isPlaying, let d = track?.duration, d > 3 else { return }
        if d - position(at: Date()) < 1.2 { seek(to: 0) }
    }

    private func send(_ command: String) {
        guard let input else { return }
        try? input.write(contentsOf: Data((command + "\n").utf8))
    }
}
