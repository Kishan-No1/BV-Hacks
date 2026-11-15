// The send path of the prompt composer: types text into the tmux pane that runs a Claude Code session.
//
// scripts/nod-claude starts `claude` inside tmux and writes one PaneRecord per session. TmuxPromptSender
// looks the record up, checks that the pane is still the same pane and is showing Claude Code's input
// prompt, then types the text and presses Enter.
//
// Rules: tmux only (no AppleScript, no Accessibility), explicit argv arrays (never a shell), and the prompt
// text is never logged, printed or put into a SendResult.
import Foundation

// MARK: - Pane records

/// One record written by scripts/nod-claude: `<panes dir>/<session_id>.json`.
public struct PaneRecord: Codable, Equatable, Sendable {
    /// The UUID passed to `claude --session-id`.
    public var sessionID: String
    /// tmux pane id, for example "%12".
    public var paneID: String
    /// tmux session name, for example "nod-myrepo".
    public var tmuxSession: String
    /// The tmux server socket.
    public var socketPath: String
    /// The tmux server pid when the pane was created.
    public var serverPID: Int
    public var cwd: String
    /// ISO 8601, UTC.
    public var startedAt: String

    public init(sessionID: String, paneID: String, tmuxSession: String, socketPath: String, serverPID: Int,
                cwd: String, startedAt: String) {
        self.sessionID = sessionID; self.paneID = paneID; self.tmuxSession = tmuxSession
        self.socketPath = socketPath; self.serverPID = serverPID; self.cwd = cwd; self.startedAt = startedAt
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case paneID = "pane_id"
        case tmuxSession = "tmux_session"
        case socketPath = "socket_path"
        case serverPID = "server_pid"
        case cwd
        case startedAt = "started_at"
    }
}

/// The directory of pane records.
public struct PaneRegistry: Sendable {
    /// `~/Library/Application Support/Nod/panes` (the same path scripts/nod-claude writes to).
    public static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Nod/panes", isDirectory: true)
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Every readable record, in file name order; unreadable or malformed files are skipped.
    public func records() -> [PaneRecord] {
        recordFiles().compactMap { Self.read($0) }
    }

    /// Exact session id first. Otherwise, if exactly ONE record has this cwd, that one (Claude Code's
    /// /clear changes the session id). Otherwise nil.
    public func lookup(sessionID: String, cwd: String) -> PaneRecord? {
        let all = records()
        if let exact = all.first(where: { $0.sessionID == sessionID }) { return exact }
        guard !cwd.isEmpty else { return nil }
        let wanted = Self.normalized(cwd)
        let sameDirectory = all.filter { !$0.cwd.isEmpty && Self.normalized($0.cwd) == wanted }
        return sameDirectory.count == 1 ? sameDirectory[0] : nil
    }

    /// Deletes the record of `sessionID`: `<sessionID>.json` and any other file that holds that session id.
    public func remove(sessionID: String) {
        guard !sessionID.isEmpty else { return }
        let fm = FileManager.default
        // The id becomes a file name only when it cannot leave the directory.
        if !sessionID.contains("/") && !sessionID.hasPrefix(".") {
            try? fm.removeItem(at: directory.appendingPathComponent(sessionID + ".json"))
        }
        for file in recordFiles() where Self.read(file)?.sessionID == sessionID {
            try? fm.removeItem(at: file)
        }
    }

    private func recordFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func read(_ file: URL) -> PaneRecord? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(PaneRecord.self, from: data)
    }

    /// Standardized and symlink-free, so "/repo/", "/repo/." and a symlinked spelling all compare equal.
    private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

// MARK: - tmux argv

/// Pure argv builders. argv[0] is the tmux path; `-S <socket>` comes right after it.
public enum TmuxCommands {
    /// What `identify` prints: the SERVER pid and the pane id.
    public static let identifyFormat = "#{pid} #{pane_id}"
    /// How far above the visible pane `capture` starts.
    public static let captureHistoryLines = 30

    /// `display-message -p -t <pane> "#{pid} #{pane_id}"`. For a pane that no longer exists tmux 3.8 still
    /// exits 0 and prints the server pid with an EMPTY pane id, so compare the whole output.
    public static func identify(tmux: String, socket: String, pane: String) -> [String] {
        [tmux, "-S", socket, "display-message", "-p", "-t", pane, identifyFormat]
    }

    /// `capture-pane -p -t <pane> -S -30`
    public static func capture(tmux: String, socket: String, pane: String) -> [String] {
        [tmux, "-S", socket, "capture-pane", "-p", "-t", pane, "-S", "-\(captureHistoryLines)"]
    }

    /// `send-keys -t <pane> -l -- <text>`: types `text` literally. The text is one argv element, passed as is.
    /// Not for a text that ends in ";" (see `TmuxText.needsPaste`).
    public static func sendLiteral(tmux: String, socket: String, pane: String, text: String) -> [String] {
        [tmux, "-S", socket, "send-keys", "-t", pane, "-l", "--", text]
    }

    /// `send-keys -t <pane> Enter`
    public static func sendEnter(tmux: String, socket: String, pane: String) -> [String] {
        [tmux, "-S", socket, "send-keys", "-t", pane, "Enter"]
    }

    /// `load-buffer -b <buffer> -`: the text goes in on stdin.
    public static func loadBuffer(tmux: String, socket: String, buffer: String) -> [String] {
        [tmux, "-S", socket, "load-buffer", "-b", buffer, "-"]
    }

    /// `paste-buffer -d -p -r -b <buffer> -t <pane>`: `-p` bracketed paste (newlines do not submit),
    /// `-r` no LF to CR translation, `-d` delete the buffer afterwards.
    public static func pasteBuffer(tmux: String, socket: String, buffer: String, pane: String) -> [String] {
        [tmux, "-S", socket, "paste-buffer", "-d", "-p", "-r", "-b", buffer, "-t", pane]
    }
}

// MARK: - Text

public enum TmuxText {
    /// A longer one-line text goes through a paste buffer: tmux refuses a command above about 16 KB
    /// ("command too long", checked on tmux 3.8).
    public static let maxLiteralBytes = 4096

    /// Normalizes CRLF and CR to LF, removes every control character except "\n" and "\t" (C0, DEL and C1;
    /// that includes ESC: an ESC sequence could end a bracketed paste early), trims trailing whitespace and
    /// newlines.
    public static func sanitize(_ text: String) -> String {
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(text.unicodeScalars.count)
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            defer { previousWasCR = scalar == "\r" }
            switch scalar.value {
            case 0x0D:
                scalars.append("\n")
            case 0x0A:
                if !previousWasCR { scalars.append("\n") }  // the CR of a CRLF already became the newline
            case 0x09:
                scalars.append(scalar)
            case 0x00...0x1F, 0x7F...0x9F:
                continue
            default:
                scalars.append(scalar)
            }
        }
        while let last = scalars.last, last.properties.isWhitespace {
            scalars.removeLast()
        }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    /// true when the text must go through a paste buffer instead of being typed:
    /// - it contains "\n" or "\t" (typed, a newline would submit and a tab would complete);
    /// - it ends in ";": tmux reads an argument that ends in ";" as a command separator, even after `--`
    ///   and with `-l`, so `send-keys -l -- "run();"` types `run()` (checked on tmux 3.8). A buffer is
    ///   loaded from stdin and has no such parsing;
    /// - it is too long for one tmux argument.
    public static func needsPaste(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0 == "\n" || $0 == "\t" } || text.hasSuffix(";") || text.utf8.count > maxLiteralBytes
    }
}

// MARK: - Prompt detection

/// Decides from a `capture-pane` whether the pane is showing Claude Code's input prompt. The patterns are
/// calibrated against real captures; change them here.
public enum PanePromptDetector {
    /// Only the last lines of the capture count (blank lines at the bottom of the pane are dropped first:
    /// capture-pane prints the whole pane height).
    public static let lookbackLines = 30

    /// A line of a numbered choice dialog: " ❯ 1. Yes", "   2. Yes, and don't ask again", "│ 3) No".
    public static let numberedOptionPattern = #"^[\s│]*[❯>]?\s*\d+[.)]\s+\S"#

    /// This many numbered option lines make a dialog.
    public static let dialogOptionCount = 2

    /// The input line: ">" or "❯" first (after indentation and the box's "│"), then a space or the end of
    /// the line. `\s` also matches the no-break space.
    public static let promptLinePattern = #"^[\s│]*[❯>](\s|$)"#

    /// true when the captured pane shows Claude Code's input prompt and no numbered choice dialog.
    public static func isAtPrompt(_ capture: String) -> Bool {
        var lines = capture.split(omittingEmptySubsequences: false) { $0.isNewline }.map(String.init)
        while let last = lines.last, last.allSatisfy(\.isWhitespace) {
            lines.removeLast()
        }
        let tail = lines.suffix(lookbackLines)
        guard !tail.isEmpty else { return false }
        let options = tail.filter { matches(numberedOptionPattern, $0) }.count
        if options >= dialogOptionCount { return false }
        return tail.contains { matches(promptLinePattern, $0) }
    }

    private static func matches(_ pattern: String, _ line: String) -> Bool {
        line.range(of: pattern, options: .regularExpression) != nil
    }
}

// MARK: - Finding tmux

public enum TmuxLocator {
    public static let environmentKey = "NOD_TMUX"
    public static let fixedPaths = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]

    /// NOD_TMUX from env if it names an executable file; else /opt/homebrew/bin/tmux, /usr/local/bin/tmux,
    /// /usr/bin/tmux; else each PATH entry. nil when none exists. (A Finder-launched app has a minimal PATH.)
    public static func find(env: [String: String] = ProcessInfo.processInfo.environment,
                            isExecutable: (String) -> Bool = TmuxLocator.isExecutableFile) -> String? {
        if let override = env[environmentKey], !override.isEmpty, isExecutable(override) { return override }
        if let fixed = fixedPaths.first(where: isExecutable) { return fixed }
        for entry in (env["PATH"] ?? "").split(separator: ":") {
            let candidate = (entry.hasSuffix("/") ? String(entry) : entry + "/") + "tmux"
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// An executable regular file (a directory also has its x bit set).
    public static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }
}

// MARK: - Sender

public struct TmuxPromptSender: PromptSending {
    /// Per tmux command. tmux answers in milliseconds; a hung server must not hang the composer.
    static let commandTimeout: TimeInterval = 3

    private let registry: PaneRegistry
    private let runner: CommandRunning
    private let tmuxPath: String?
    private let enterDelay: TimeInterval
    private let bufferName: @Sendable () -> String

    /// - Parameters:
    ///   - tmuxPath: `TmuxLocator.find()`; nil makes every send `.tmuxMissing`.
    ///   - enterDelay: pause between the text and Enter, so Claude Code has taken the text in.
    ///   - bufferName: name of the paste buffer for one multi-line send.
    public init(registry: PaneRegistry, runner: CommandRunning = ProcessCommandRunner(), tmuxPath: String?,
                enterDelay: TimeInterval = 0.15,
                bufferName: @escaping @Sendable () -> String = { "nod-" + UUID().uuidString }) {
        self.registry = registry
        self.runner = runner
        self.tmuxPath = tmuxPath
        self.enterDelay = enterDelay
        self.bufferName = bufferName
    }

    public func send(text: String, sessionID: String, cwd: String) async -> SendResult {
        // The runner blocks; keep it off the main thread and off the cooperative pool.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: sendBlocking(text: text, sessionID: sessionID, cwd: cwd))
            }
        }
    }

    private func sendBlocking(text: String, sessionID: String, cwd: String) -> SendResult {
        guard let tmux = tmuxPath else { return .tmuxMissing }
        let clean = TmuxText.sanitize(text)
        guard !clean.isEmpty else { return .failed("empty prompt") }
        guard let record = registry.lookup(sessionID: sessionID, cwd: cwd), Self.isUsable(record) else {
            return .paneNotFound
        }
        let socket = record.socketPath, pane = record.paneID

        // Same server, same pane? Pane ids restart from %0 when the tmux server restarts, so without the
        // server pid a stale record could point at an unrelated pane.
        guard let identity = run(TmuxCommands.identify(tmux: tmux, socket: socket, pane: pane)),
              identity.status == 0 else {
            return .paneNotFound
        }
        guard identity.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "\(record.serverPID) \(pane)" else {
            registry.remove(sessionID: record.sessionID)
            return .paneNotFound
        }

        // Only type into Claude Code's input: text sent to a permission dialog would answer it.
        guard let capture = run(TmuxCommands.capture(tmux: tmux, socket: socket, pane: pane)) else {
            return .failed(Self.reason(nil))
        }
        guard capture.status == 0, PanePromptDetector.isAtPrompt(capture.stdout) else { return .notAtPrompt }

        if TmuxText.needsPaste(clean) {
            let buffer = bufferName()
            let loaded = run(TmuxCommands.loadBuffer(tmux: tmux, socket: socket, buffer: buffer), stdin: clean)
            guard loaded?.status == 0 else { return .failed(Self.reason(loaded)) }
            let pasted = run(TmuxCommands.pasteBuffer(tmux: tmux, socket: socket, buffer: buffer, pane: pane))
            guard pasted?.status == 0 else { return .failed(Self.reason(pasted)) }
        } else {
            let typed = run(TmuxCommands.sendLiteral(tmux: tmux, socket: socket, pane: pane, text: clean))
            guard typed?.status == 0 else { return .failed(Self.reason(typed)) }
        }

        if enterDelay > 0 { Thread.sleep(forTimeInterval: enterDelay) }
        let entered = run(TmuxCommands.sendEnter(tmux: tmux, socket: socket, pane: pane))
        guard entered?.status == 0 else { return .failed(Self.reason(entered)) }
        return .sent(pane: pane)
    }

    private func run(_ argv: [String], stdin: String? = nil) -> CommandResult? {
        runner.run(argv[0], Array(argv.dropFirst()), stdin: stdin, timeout: Self.commandTimeout)
    }

    /// Status only: tmux's stderr is never passed on.
    private static func reason(_ result: CommandResult?) -> String {
        guard let result else { return "tmux did not respond" }
        return "tmux exited \(result.status)"
    }

    /// A record from disk goes into argv: the pane must be a pane id ("%12", so it can never read as an
    /// option) and the socket an absolute path.
    private static func isUsable(_ record: PaneRecord) -> Bool {
        let digits = record.paneID.dropFirst()
        return record.paneID.hasPrefix("%") && !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
            && record.socketPath.hasPrefix("/")
    }
}
