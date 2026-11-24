// OWNER: workstream C (app-ui).
import AppKit
import Foundation

/// Spotify's web player in Google Chrome, read straight from its open.spotify.com tab: the song, artist, album,
/// artwork, exact position, play state, shuffle and repeat, and its own buttons. macOS's Now Playing is not
/// enough for the web player: it follows whichever tab played last (a TikTok tab takes it over), its position
/// goes stale after a seek, and it never reports shuffle or repeat.
///
/// Needs Chrome's View › Developer › Allow JavaScript from Apple Events and a one-time "notchAgent wants to
/// control Google Chrome" Allow. With the setting off, only the tab's title is readable (`.tabOnly`).
final class SpotifyWebBridge: @unchecked Sendable {
    static let chromeBundleID = "com.google.Chrome"

    struct State: Equatable {
        var title: String
        var artist: String
        var album: String
        var artworkURL: String
        var position: TimeInterval
        var duration: TimeInterval
        var playing: Bool
        var shuffle: Bool
        var repeating: Bool
    }

    enum Result: Equatable {
        case ok(State)
        /// A Spotify tab is open but JavaScript from Apple Events is off: only its title ("Song • Artist").
        case tabOnly(title: String)
        /// Chrome has no open.spotify.com tab (or is not running).
        case noTab
        /// macOS Automation permission for Chrome was refused.
        case denied
        case failed(String)
    }

    /// The tab's controls, by Spotify's `data-testid`.
    enum Button: String {
        case playPause = "control-button-playpause"
        case next = "control-button-skip-forward"
        case previous = "control-button-skip-back"
        case shuffle = "control-button-shuffle"
        case repeating = "control-button-repeat"
    }

    private let queue = DispatchQueue(label: "dev.notchagent.spotify-web")
    private static let sep = "\u{1F}"

    static var chromeRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: chromeBundleID).isEmpty
    }

    /// Reads the tab. `completion` runs on the main queue.
    func poll(_ completion: @escaping @Sendable (Result) -> Void) {
        let js = """
        (function(){var q=function(s){return document.querySelector('[data-testid='+s+']')};\
        var r=document.querySelector('[data-testid=playback-progressbar] input[type=range]');\
        var pp=q('control-button-playpause'),sh=q('control-button-shuffle'),rp=q('control-button-repeat');\
        var t=function(e){return e?e.textContent:''};\
        var m=navigator.mediaSession&&navigator.mediaSession.metadata;\
        var a=m&&m.artwork&&m.artwork.length?m.artwork[m.artwork.length-1].src:'';\
        return JSON.stringify({title:m?m.title:'',artist:m?m.artist:'',album:m?m.album:'',art:a,\
        pos:r?Number(r.value):null,max:r?Number(r.max):null,\
        ptext:t(q('playback-position')),dtext:t(q('playback-duration')),\
        pause:pp?(pp.getAttribute('aria-label')||''):'',\
        shuffle:sh?(sh.getAttribute('aria-checked')||''):'',repeat:rp?(rp.getAttribute('aria-checked')||''):''})})()
        """
        run(js) { outcome in
            switch outcome {
            case .noTab: completion(.noTab)
            case .denied: completion(.denied)
            case .failed(let why): completion(.failed(why))
            case .javaScriptOff(let title): completion(.tabOnly(title: title))
            case .value(_, let out):
                guard let data = out.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(.failed("unreadable tab state"))
                    return
                }
                completion(Self.state(from: o).map(Result.ok) ?? .failed("no player in the Spotify tab"))
            }
        }
    }

    /// Clicks one of the tab's buttons. `completion` runs on the main queue.
    func press(_ button: Button, _ completion: @escaping @Sendable () -> Void = {}) {
        let js = "(function(){var b=document.querySelector('[data-testid=\(button.rawValue)]');if(b){b.click();return 'ok'}return ''})()"
        run(js) { _ in completion() }
    }

    // MARK: Internals

    private static func state(from o: [String: Any]) -> State? {
        let label = (o["pause"] as? String ?? "").lowercased()
        let title = o["title"] as? String ?? ""
        guard !label.isEmpty, !title.isEmpty else { return nil }
        // The time labels ("5:04", "7:15") always work; the progress slider is finer but is only trusted when its
        // range matches the labelled duration (it should hold milliseconds).
        var position = seconds(o["ptext"] as? String)
        var duration = seconds(o["dtext"] as? String)
        if let pos = (o["pos"] as? NSNumber)?.doubleValue, let max = (o["max"] as? NSNumber)?.doubleValue, max > 0 {
            let sliderDuration = max / 1000
            if let d = duration, abs(sliderDuration - d) <= 2 {
                position = pos / 1000
                duration = sliderDuration
            } else if duration == nil, sliderDuration > 5 {
                position = pos / 1000
                duration = sliderDuration
            }
        }
        let rep = o["repeat"] as? String ?? ""
        return State(title: title, artist: o["artist"] as? String ?? "", album: o["album"] as? String ?? "",
                     artworkURL: o["art"] as? String ?? "", position: position ?? 0, duration: duration ?? 0,
                     playing: label.contains("pause"), shuffle: (o["shuffle"] as? String ?? "") == "true",
                     repeating: rep == "true" || rep == "mixed")
    }

    private static func seconds(_ text: String?) -> TimeInterval? {
        guard let parts = text?.split(separator: ":").compactMap({ Double($0) }), !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    private enum Outcome {
        case value(title: String, String)
        case javaScriptOff(title: String)
        case noTab, denied
        case failed(String)
    }

    /// Runs `js` in the first open.spotify.com tab and returns the tab title with the result. Never launches Chrome.
    private func run(_ js: String, completion: @escaping @Sendable (Outcome) -> Void) {
        guard Self.chromeRunning else {
            DispatchQueue.main.async { completion(.noTab) }
            return
        }
        let escaped = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        set sep to (ASCII character 31)
        tell application id "\(Self.chromeBundleID)"
          repeat with w in windows
            repeat with t in tabs of w
              if (URL of t) starts with "https://open.spotify.com" then
                set tt to (title of t)
                try
                  set res to (execute t javascript "\(escaped)")
                on error errMsg number errNum
                  return "ERR" & sep & tt & sep & errNum & sep & errMsg
                end try
                return "OK" & sep & tt & sep & res
              end if
            end repeat
          end repeat
        end tell
        return ""
        """
        queue.async {
            var error: NSDictionary?
            let out = NSAppleScript(source: source)?.executeAndReturnError(&error)
            let outcome: Outcome
            if let error {
                let code = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue ?? 0
                let message = error[NSAppleScript.errorMessage] as? String ?? "AppleScript failed"
                outcome = code == -1743 ? .denied : .failed("\(message) (\(code))")
            } else {
                let parts = (out?.stringValue ?? "").components(separatedBy: Self.sep)
                switch parts.first {
                case "OK" where parts.count >= 3:
                    outcome = .value(title: parts[1], parts[2...].joined(separator: Self.sep))
                case "ERR" where parts.count >= 4:
                    let message = parts[3...].joined(separator: Self.sep)
                    outcome = message.localizedCaseInsensitiveContains("JavaScript")
                        ? .javaScriptOff(title: parts[1]) : .failed("\(message) (\(parts[2]))")
                default:
                    outcome = .noTab
                }
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }
}
