// The tmux send path. No tmux is ever run here: a recording fake runner returns scripted results.
import Foundation
import Testing
import NotchAgentCore

private let tmux = "/opt/homebrew/bin/tmux"
private let socket = "/tmp/tmux-501/default"
private let promptBox = """
────────────────────────────────────────────────
❯ 
────────────────────────────────────────────────
  ? for shortcuts
"""
private let dialog = """
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and don't ask again for npm test commands
   3. No, and tell Claude what to do differently (esc)
"""

/// Records `(argv, stdin)` and answers each tmux subcommand from a script.
private final class FakeRunner: CommandRunning, @unchecked Sendable {
    struct Call: Equatable {
        var argv: [String]
        var stdin: String?
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var identify: CommandResult? = CommandResult(status: 0, stdout: "4242 %7\n")
    var capture: CommandResult? = CommandResult(status: 0, stdout: promptBox)
    var sendKeys: CommandResult? = CommandResult(status: 0)
    var loadBuffer: CommandResult? = CommandResult(status: 0)
    var pasteBuffer: CommandResult? = CommandResult(status: 0)

    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    /// The tmux subcommand of each call, in order.
    var subcommands: [String] { calls.map { $0.argv.count > 3 ? $0.argv[3] : "" } }

    func run(_ executable: String, _ arguments: [String], stdin: String?, timeout: TimeInterval) -> CommandResult? {
        lock.lock(); defer { lock.unlock() }
        _calls.append(Call(argv: [executable] + arguments, stdin: stdin))
        switch arguments.count > 2 ? arguments[2] : "" {
        case "display-message": return identify
        case "capture-pane": return capture
        case "send-keys": return sendKeys
        case "load-buffer": return loadBuffer
        case "paste-buffer": return pasteBuffer
        default: return CommandResult(status: 1)
        }
    }
}

private struct Rig {
    let dir: URL
    let registry: PaneRegistry
    let runner = FakeRunner()

    init(records: [PaneRecord] = [Rig.record()]) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("notch-agent-panes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        registry = PaneRegistry(directory: dir)
        for r in records { try Rig.write(r, to: dir) }
    }

    static func record(session: String = "sess-1", pane: String = "%7", cwd: String = "/tmp/repo", pid: Int = 4242) -> PaneRecord {
        PaneRecord(sessionID: session, paneID: pane, tmuxSession: "notch-agent-repo", socketPath: socket, serverPID: pid,
                   cwd: cwd, startedAt: "2026-11-15T20:00:00Z")
    }

    static func write(_ record: PaneRecord, to dir: URL) throws {
        try JSONEncoder().encode(record).write(to: dir.appendingPathComponent("\(record.sessionID).json"))
    }

    func sender(tmuxPath: String? = tmux) -> TmuxPromptSender {
        TmuxPromptSender(registry: registry, runner: runner, tmuxPath: tmuxPath, enterDelay: 0, bufferName: { "notch-agent-buf" })
    }

    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

@Suite struct TmuxCommandTests {
    @Test func everyBuilderGivesTheExactArgv() {
        #expect(TmuxCommands.identify(tmux: tmux, socket: socket, pane: "%7")
            == [tmux, "-S", socket, "display-message", "-p", "-t", "%7", "#{pid} #{pane_id}"])
        #expect(TmuxCommands.capture(tmux: tmux, socket: socket, pane: "%7")
            == [tmux, "-S", socket, "capture-pane", "-p", "-t", "%7", "-S", "-30"])
        #expect(TmuxCommands.sendLiteral(tmux: tmux, socket: socket, pane: "%7", text: "-x fix it")
            == [tmux, "-S", socket, "send-keys", "-t", "%7", "-l", "--", "-x fix it"])
        #expect(TmuxCommands.sendEnter(tmux: tmux, socket: socket, pane: "%7")
            == [tmux, "-S", socket, "send-keys", "-t", "%7", "Enter"])
        #expect(TmuxCommands.loadBuffer(tmux: tmux, socket: socket, buffer: "notch-agent-buf")
            == [tmux, "-S", socket, "load-buffer", "-b", "notch-agent-buf", "-"])
        #expect(TmuxCommands.pasteBuffer(tmux: tmux, socket: socket, buffer: "notch-agent-buf", pane: "%7")
            == [tmux, "-S", socket, "paste-buffer", "-d", "-p", "-r", "-b", "notch-agent-buf", "-t", "%7"])
    }
}

@Suite struct TmuxSendTests {
    @Test(arguments: [
        "fix the login test",
        "-rf is not a flag here",
        "say \"hi\" and 'bye'",
        "echo $HOME `id` $(whoami)",
        "a; b && c | d > e",
        "naïve café 日本語 🚀",
        "back\\slash and 100%",
    ])
    func aOneLineTextIsTypedVerbatimAsOneArgument(text: String) async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let result = await rig.sender().send(text: text, sessionID: "sess-1", cwd: "/tmp/repo")
        #expect(result == .sent(pane: "%7"))
        #expect(rig.runner.calls.map(\.argv) == [
            [tmux, "-S", socket, "display-message", "-p", "-t", "%7", "#{pid} #{pane_id}"],
            [tmux, "-S", socket, "capture-pane", "-p", "-t", "%7", "-S", "-30"],
            [tmux, "-S", socket, "send-keys", "-t", "%7", "-l", "--", text],
            [tmux, "-S", socket, "send-keys", "-t", "%7", "Enter"],
        ])
        #expect(rig.runner.calls.allSatisfy { $0.stdin == nil })
    }

    @Test func aMultiLineTextGoesThroughAPasteBufferOnStdin() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let text = "Fix the login test.\n- keep the diff small\n- run tests after edits"
        let result = await rig.sender().send(text: text, sessionID: "sess-1", cwd: "/tmp/repo")
        #expect(result == .sent(pane: "%7"))
        #expect(rig.runner.subcommands == ["display-message", "capture-pane", "load-buffer", "paste-buffer", "send-keys"])
        let calls = rig.runner.calls
        #expect(calls[2] == .init(argv: [tmux, "-S", socket, "load-buffer", "-b", "notch-agent-buf", "-"], stdin: text))
        #expect(calls[3].argv == [tmux, "-S", socket, "paste-buffer", "-d", "-p", "-r", "-b", "notch-agent-buf", "-t", "%7"])
        #expect(calls[4].argv == [tmux, "-S", socket, "send-keys", "-t", "%7", "Enter"])
        // The text is on stdin and in no argv.
        #expect(!calls.contains { $0.argv.contains { $0.contains("login") } })
    }

    @Test(arguments: ["col1\tcol2", "run();", ";"])
    func aTabOrATrailingSemicolonForcesThePastePath(text: String) async throws {
        // tmux reads an argument that ends in ";" as a command separator, so it is never put in argv.
        let rig = try Rig(); defer { rig.cleanup() }
        #expect(TmuxText.needsPaste(text))
        let result = await rig.sender().send(text: text, sessionID: "sess-1", cwd: "/tmp/repo")
        #expect(result.isSent)
        #expect(rig.runner.subcommands == ["display-message", "capture-pane", "load-buffer", "paste-buffer", "send-keys"])
        #expect(rig.runner.calls[2].stdin == text)
    }

    @Test func aVeryLongLineIsPastedToo() {
        #expect(!TmuxText.needsPaste(String(repeating: "a", count: TmuxText.maxLiteralBytes)))
        #expect(TmuxText.needsPaste(String(repeating: "a", count: TmuxText.maxLiteralBytes + 1)))
        #expect(!TmuxText.needsPaste("a;b"))
    }

    @Test func sanitizeStripsControlCharactersAndKeepsTheRest() {
        #expect(TmuxText.sanitize("a\u{1B}[201~b\u{0}c\u{7}d\u{7F}e") == "a[201~bcde")
        #expect(TmuxText.sanitize("one\r\ntwo\rthree\n\n") == "one\ntwo\nthree")
        #expect(TmuxText.sanitize("tab\there, naïve 🚀  \n ") == "tab\there, naïve 🚀")
        #expect(TmuxText.sanitize("\u{1B}\u{0}\u{7}\r\n") == "")
    }

    @Test func anAllControlTextIsRefusedAndNothingRuns() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        #expect(await rig.sender().send(text: "\u{1B}\u{0}\n", sessionID: "sess-1", cwd: "/tmp/repo") == .failed("empty prompt"))
        #expect(rig.runner.calls.isEmpty)
    }

    @Test func noTmuxMeansTmuxMissingAndNothingRuns() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        #expect(await rig.sender(tmuxPath: nil).send(text: "hi", sessionID: "sess-1", cwd: "/tmp/repo") == .tmuxMissing)
        #expect(rig.runner.calls.isEmpty)
    }

    @Test func noRecordMeansPaneNotFound() async throws {
        let rig = try Rig(records: []); defer { rig.cleanup() }
        #expect(await rig.sender().send(text: "hi", sessionID: "sess-1", cwd: "/tmp/repo") == .paneNotFound)
        #expect(rig.runner.calls.isEmpty)
    }

    @Test func aRecordThatIsNotAPaneIdOrAnAbsoluteSocketIsNotUsed() async throws {
        var bad = Rig.record(pane: "-t evil")
        let rig = try Rig(records: [bad]); defer { rig.cleanup() }
        #expect(await rig.sender().send(text: "hi", sessionID: "sess-1", cwd: "/tmp/repo") == .paneNotFound)
        bad = Rig.record()
        bad.socketPath = "relative.sock"
        try Rig.write(bad, to: rig.dir)
        #expect(await rig.sender().send(text: "hi", sessionID: "sess-1", cwd: "/tmp/repo") == .paneNotFound)
        #expect(rig.runner.calls.isEmpty)
    }

    @Test func aDeadPaneMeansPaneNotFound() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        rig.runner.identify = CommandResult(status: 1, stderr: "can't find pane: %7")
        #expect(await rig.sender().send(text: "hi", sessionID: "sess-1", cwd: "/tmp/repo") == .paneNotFound)
        #expect(rig.runner.subcommands == ["display-message"])
    }

    @Test(arguments: ["9999 %7\n", "4242 \n", "4242 %8\n"])
    func aRestartedServerOrAnotherPaneRemovesTheStaleRecordAndSendsNothing(identity: String) async throws {
        // tmux 3.8 exits 0 for a missing pane and prints the server pid with an empty pane id.
        let rig = try Rig(); defer { rig.cleanup() }
        rig.runner.identify = CommandResult(status: 0, stdout: identity)
        #expect(await rig.sender().send(text: "hi", sessionID: "sess-1", cwd: "/tmp/repo") == .paneNotFound)
        #expect(rig.runner.subcommands == ["display-message"])
        #expect(rig.registry.records().isEmpty)
    }

    @Test func aPermissionDialogMeansNotAtPromptAndNothingIsTyped() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        rig.runner.capture = CommandResult(status: 0, stdout: dialog)
        #expect(await rig.sender().send(text: "1", sessionID: "sess-1", cwd: "/tmp/repo") == .notAtPrompt)
        #expect(rig.runner.subcommands == ["display-message", "capture-pane"])
        rig.runner.capture = CommandResult(status: 0, stdout: "$ ")
        #expect(await rig.sender().send(text: "rm -rf x", sessionID: "sess-1", cwd: "/tmp/repo") == .notAtPrompt)
        #expect(!rig.runner.subcommands.contains("send-keys"))
        #expect(!rig.runner.subcommands.contains("paste-buffer"))
    }

    @Test func aFailedSendCarriesNoPromptTextAndNoEnterIsPressed() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        rig.runner.sendKeys = CommandResult(status: 1, stderr: "SECRET-PROMPT leaked by tmux")
        let result = await rig.sender().send(text: "SECRET-PROMPT", sessionID: "sess-1", cwd: "/tmp/repo")
        #expect(result == .failed("tmux exited 1"))
        #expect(rig.runner.subcommands == ["display-message", "capture-pane", "send-keys"])
        #expect(!String(describing: result).contains("SECRET"))

        rig.runner.loadBuffer = nil
        let pasted = await rig.sender().send(text: "SECRET\nPROMPT", sessionID: "sess-1", cwd: "/tmp/repo")
        #expect(pasted == .failed("tmux did not respond"))
        #expect(!rig.runner.subcommands.contains("paste-buffer"))
    }
}

@Suite struct PaneRegistryTests {
    @Test func readsRecordsAndSkipsMalformedFiles() throws {
        let rig = try Rig(records: [Rig.record(session: "a"), Rig.record(session: "b", pane: "%9")]); defer { rig.cleanup() }
        try Data("{ not json".utf8).write(to: rig.dir.appendingPathComponent("broken.json"))
        try Data("{}".utf8).write(to: rig.dir.appendingPathComponent("empty.json"))
        try Data("x".utf8).write(to: rig.dir.appendingPathComponent("notes.txt"))
        #expect(rig.registry.records().map(\.sessionID) == ["a", "b"])
    }

    @Test func decodesTheFileTheLauncherWrites() throws {
        let json = #"{"session_id":"s","pane_id":"%3","tmux_session":"notch-agent-x","socket_path":"/tmp/s","server_pid":77,"cwd":"/tmp/x","started_at":"2026-11-15T20:00:00Z"}"#
        let record = try JSONDecoder().decode(PaneRecord.self, from: Data(json.utf8))
        #expect(record == PaneRecord(sessionID: "s", paneID: "%3", tmuxSession: "notch-agent-x", socketPath: "/tmp/s", serverPID: 77,
                                     cwd: "/tmp/x", startedAt: "2026-11-15T20:00:00Z"))
    }

    @Test func theExactSessionIdWinsOverTheDirectory() throws {
        let rig = try Rig(records: [Rig.record(session: "a", pane: "%1", cwd: "/tmp/one"),
                                    Rig.record(session: "b", pane: "%2", cwd: "/tmp/two")]); defer { rig.cleanup() }
        #expect(rig.registry.lookup(sessionID: "b", cwd: "/tmp/one")?.paneID == "%2")
    }

    @Test func theDirectoryIsAFallbackOnlyWhenItIsUnique() throws {
        // /clear gives the session a new id; the pane is still the only one in that directory.
        let rig = try Rig(records: [Rig.record(session: "a", pane: "%1", cwd: "/tmp/one")]); defer { rig.cleanup() }
        #expect(rig.registry.lookup(sessionID: "new-id", cwd: "/tmp/one")?.paneID == "%1")
        #expect(rig.registry.lookup(sessionID: "new-id", cwd: "/tmp/one/")?.paneID == "%1")
        #expect(rig.registry.lookup(sessionID: "new-id", cwd: "/tmp/other") == nil)
        #expect(rig.registry.lookup(sessionID: "new-id", cwd: "") == nil)
        try Rig.write(Rig.record(session: "c", pane: "%3", cwd: "/tmp/one"), to: rig.dir)
        #expect(rig.registry.lookup(sessionID: "new-id", cwd: "/tmp/one") == nil)
    }

    @Test func removeDeletesTheFileAndAMissingDirectoryIsEmpty() throws {
        let rig = try Rig(records: [Rig.record(session: "a"), Rig.record(session: "b")]); defer { rig.cleanup() }
        rig.registry.remove(sessionID: "a")
        #expect(rig.registry.records().map(\.sessionID) == ["b"])
        rig.registry.remove(sessionID: "../b")
        #expect(rig.registry.records().map(\.sessionID) == ["b"])
        #expect(PaneRegistry(directory: rig.dir.appendingPathComponent("nope")).records().isEmpty)
        #expect(PaneRegistry.defaultDirectory.path.hasSuffix("/Library/Application Support/notchAgent/panes"))
    }
}

@Suite struct PanePromptDetectorTests {
    @Test func bothPromptBoxStylesAreAPrompt() {
        let boxed = """
        ╭──────────────────────────────────────────────╮
        │ >                                            │
        ╰──────────────────────────────────────────────╯
          ? for shortcuts
        """
        #expect(PanePromptDetector.isAtPrompt(boxed))
        #expect(PanePromptDetector.isAtPrompt(promptBox))
        #expect(PanePromptDetector.isAtPrompt(promptBox.replacingOccurrences(of: "❯ ", with: "❯ half a draft")))
        #expect(PanePromptDetector.isAtPrompt(boxed.replacingOccurrences(of: "│ >   ", with: "│ > Try \"fix the lint errors\"")))
        // capture-pane prints the whole pane height: blank lines below the prompt do not hide it.
        #expect(PanePromptDetector.isAtPrompt(promptBox + String(repeating: "\n", count: 40)))
    }

    /// Captured from Claude Code 2.1.322 in tmux 3.8 (idle, placeholder text; "❯" is followed by a no-break space).
    private static let realIdle = """
     ▐▛███▛█   Claude Code v2.1.322
    ▝▜██████▀  Fable 5.2 with high effort · Claude Pro
     ▝▝   ▝▝   /…/scratchpad/real/proj

                                                                  ● high · /effort
    ────────────────────────────────────────────────────────────────────────────────
    ❯\u{A0}Try "how do I log an error?"
    ────────────────────────────────────────────────────────────────────────────────
      ⏵⏵ auto mode on (shift+tab to cycle) · ← 3 agents
    """

    /// Captured from the same version: the folder-trust dialog. Its selected row starts with "❯" too.
    private static let realTrustDialog = """
    ────────────────────────────────────────────────────────────────────────────────
     Accessing workspace:

     /private/tmp/scratchpad/real/proj

     Quick safety check: Is this a project you created or one you trust? (Like your
     own code, a well-known open source project, or work from your team). If not,
     take a moment to review what's in this folder first.

     Claude Code'll be able to read, edit, and execute files here.

     Security guide

     ❯ No, exit
       Yes, I trust this folder

     Enter to confirm · Esc to cancel
    """

    @Test func theRealIdlePromptIsAPromptAndTheRealTrustDialogIsNot() {
        #expect(PanePromptDetector.isAtPrompt(Self.realIdle))
        #expect(!PanePromptDetector.isAtPrompt(Self.realTrustDialog))
        // A draft of several lines still ends in the closing rule.
        let draft = Self.realIdle.replacingOccurrences(of: "❯\u{A0}Try \"how do I log an error?\"", with: "❯\u{A0}first line\n  second line\n  third line")
        #expect(PanePromptDetector.isAtPrompt(draft))
    }

    @Test func aMenuRowWithoutRulesAroundItIsNotAPrompt() {
        #expect(!PanePromptDetector.isAtPrompt("Pick one\n❯ Yes\n  No\n"))
        // A rule above a menu, none below it.
        #expect(!PanePromptDetector.isAtPrompt("────────────────\n❯ Yes\n  No\n Enter to confirm"))
        // "❯" under a rule, but the line right above it is text.
        #expect(!PanePromptDetector.isAtPrompt("────────────────\n Choose:\n❯ Yes\n────────────────"))
    }

    @Test func aDialogAShellOrNothingIsNotAPrompt() {
        #expect(!PanePromptDetector.isAtPrompt(dialog))
        // A dialog drawn above an old prompt box still wins.
        #expect(!PanePromptDetector.isAtPrompt(promptBox + "\n" + dialog))
        #expect(!PanePromptDetector.isAtPrompt(dialog + "\n" + promptBox))
        #expect(!PanePromptDetector.isAtPrompt("user@mac repo % "))
        #expect(!PanePromptDetector.isAtPrompt("$ "))
        #expect(!PanePromptDetector.isAtPrompt("❯ "))
        #expect(!PanePromptDetector.isAtPrompt(""))
        #expect(!PanePromptDetector.isAtPrompt("\n\n\n"))
    }

    @Test func oneNumberedLineInTheTranscriptIsNotADialog() {
        #expect(PanePromptDetector.isAtPrompt("⏺ Done. Next steps:\n  1. Run the tests\n" + promptBox))
    }
}

@Suite struct TmuxLocatorTests {
    @Test func theOverrideWinsThenTheFixedPathsThenPath() {
        let all: (String) -> Bool = { _ in true }
        #expect(TmuxLocator.find(env: ["NOTCH_AGENT_TMUX": "/x/tmux", "PATH": "/a:/b"], isExecutable: all) == "/x/tmux")
        #expect(TmuxLocator.find(env: ["PATH": "/a:/b"], isExecutable: all) == "/opt/homebrew/bin/tmux")
        #expect(TmuxLocator.find(env: ["NOTCH_AGENT_TMUX": "/x/tmux"], isExecutable: { $0 == "/usr/local/bin/tmux" }) == "/usr/local/bin/tmux")
        #expect(TmuxLocator.find(env: ["PATH": "/a:/b/"], isExecutable: { $0 == "/b/tmux" }) == "/b/tmux")
        #expect(TmuxLocator.find(env: ["PATH": "/a:/b"], isExecutable: { _ in false }) == nil)
        #expect(TmuxLocator.find(env: [:], isExecutable: { _ in false }) == nil)
    }
}
