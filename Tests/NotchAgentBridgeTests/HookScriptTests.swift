// OWNER: workstream B (bridge). Runs hooks/notch-agent-hook.sh, scripts/install-hooks.sh, scripts/uninstall-hooks.sh and
// scripts/simulate.sh with Process. Every run gets HOME pointed at a temp directory and an explicit --settings
// temp file, so nothing here can ever touch the real ~/.claude/settings.json.
import Foundation
import Testing
import NotchAgentCore

// MARK: - Process helpers

struct ProcessResult: Sendable {
    var status: Int32
    var stdout: Data
    var stderr: Data
    var elapsed: Duration
    var reason: Process.TerminationReason

    var out: String { String(decoding: stdout, as: UTF8.self) }
    var err: String { String(decoding: stderr, as: UTF8.self) }
}

/// A child process whose pipes are drained on GCD threads (never on the Swift cooperative pool).
///
/// Exit is observed with `terminationHandler`, NOT `waitUntilExit()`: the latter spins the calling thread's
/// run loop and was seen to hang forever on a GCD worker after the child had already exited.
final class Subprocess: @unchecked Sendable {
    private static let ignoreSIGPIPE: Void = { signal(SIGPIPE, SIG_IGN) }()

    let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let inPipe = Pipe()
    private let exited = DispatchGroup()
    private let started = ContinuousClock.now

    init(_ args: [String], executable: String = "/bin/bash", env: [String: String] = [:], stdin: Data? = nil) throws {
        _ = Self.ignoreSIGPIPE
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "NOTCH_AGENT_PORT")
        for (k, v) in env { environment[k] = v }
        process.environment = environment
        process.currentDirectoryURL = BridgeFixture.repoRoot
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
        exited.enter()
        process.terminationHandler = { [exited] _ in exited.leave() }
        do {
            try process.run()
        } catch {
            exited.leave()
            throw error
        }
        if let stdin {
            try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
        }
        if stdin != nil { try? inPipe.fileHandleForWriting.close() }
    }

    func terminate() { process.terminate() }

    func wait() async -> ProcessResult {
        await withCheckedContinuation { cont in
            let group = DispatchGroup()
            var outData = Data()
            var errData = Data()
            group.enter()
            DispatchQueue.global().async {
                outData = self.outPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                errData = self.errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            exited.notify(queue: .global()) { group.leave() }
            group.notify(queue: .global()) {
                cont.resume(returning: ProcessResult(
                    status: self.process.terminationStatus, stdout: outData, stderr: errData,
                    elapsed: ContinuousClock.now - self.started, reason: self.process.terminationReason))
            }
        }
    }
}

/// realpath(3): the same physical path `pwd -P` gives the scripts (URL.resolvingSymlinksInPath strips /private).
func physicalPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

enum Scripts {
    static let root = BridgeFixture.repoRoot
    static let hook = physicalPath(root.appendingPathComponent("hooks/notch-agent-hook.sh").path)
    static let install = physicalPath(root.appendingPathComponent("scripts/install-hooks.sh").path)
    static let uninstall = physicalPath(root.appendingPathComponent("scripts/uninstall-hooks.sh").path)
    static let simulate = physicalPath(root.appendingPathComponent("scripts/simulate.sh").path)

    static let nineEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                             "PermissionRequest", "Notification", "Stop", "SessionEnd"]

    static func run(_ args: [String], env: [String: String] = [:], stdin: Data? = nil,
                    executable: String = "/bin/bash") async throws -> ProcessResult {
        try await Subprocess(args, executable: executable, env: env, stdin: stdin).wait()
    }

    /// Runs the hook script for `event` against `port`.
    static func hook(_ event: String, port: UInt16, stdin: Data) async throws -> ProcessResult {
        try await run([hook, event], env: ["NOTCH_AGENT_PORT": String(port)], stdin: stdin)
    }
}

/// A fresh temp directory that also serves as HOME for script runs.
final class TempDir: @unchecked Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("notch-agent-bridge-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    var settings: URL { url.appendingPathComponent(".claude/settings.json") }
    var env: [String: String] { ["HOME": url.path] }

    func backups(of file: URL) throws -> [URL] {
        let dir = file.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(file.lastPathComponent + ".notch-agent-backup-") }
    }

    func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    func install(_ extra: [String] = [], settings file: URL? = nil) async throws -> ProcessResult {
        try await Scripts.run([Scripts.install, "--settings", (file ?? settings).path] + extra, env: env)
    }

    func uninstall(_ extra: [String] = [], settings file: URL? = nil) async throws -> ProcessResult {
        try await Scripts.run([Scripts.uninstall, "--settings", (file ?? settings).path] + extra, env: env)
    }
}

func json(_ url: URL) throws -> JSONValue { try JSONValue.parse(try Data(contentsOf: url)) }

/// `jq -S .` of a file, the canonical form the task compares with.
func jqSorted(_ url: URL) async throws -> String {
    try await Scripts.run(["-S", ".", url.path], executable: "/usr/bin/jq").out
}

private let existingSettings = """
{
  "model": "opus",
  "env": {"FOO": "bar"},
  "permissions": {"allow": ["Bash(ls:*)"], "deny": ["Read(./.env)"]},
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"type": "command", "command": "~/bin/audit.sh", "timeout": 30}]}
    ],
    "SubagentStop": [
      {"hooks": [{"type": "command", "command": "say done"}]}
    ]
  },
  "statusLine": {"type": "command", "command": "~/.claude/statusline.sh"}
}
"""

// MARK: - notch-agent-hook.sh against a live server

@Suite(.timeLimit(.minutes(1))) struct HookScriptTests {
    @Test func scriptsAreExecutableAndParse() async throws {
        for path in [Scripts.hook, Scripts.install, Scripts.uninstall, Scripts.simulate] {
            #expect(FileManager.default.isExecutableFile(atPath: path), "\(path) must be executable")
            let r = try await Scripts.run(["-n", path])
            #expect(r.status == 0, "bash -n \(path): \(r.err)")
        }
    }

    @Test func allowPrintsExactlyTheAllowJSON() async throws {
        let (server, port) = try await startServer { _ in .decision(.allow) }
        defer { server.stop() }
        let r = try await Scripts.hook("PermissionRequest", port: port, stdin: try BridgeFixture.data("permission-request-bash-npm-test"))
        #expect(r.status == 0)
        #expect(r.stdout == HookOutput.permissionRequest(.allow))
        #expect(r.err.isEmpty)
    }

    @Test func denyPrintsTheDenyJSON() async throws {
        let (server, port) = try await startServer { _ in .decision(.deny(message: "Denied from notchAgent.")) }
        defer { server.stop() }
        let r = try await Scripts.hook("PermissionRequest", port: port, stdin: try BridgeFixture.data("permission-request-bash-rm-rf-outside"))
        #expect(r.status == 0)
        #expect(r.stdout == HookOutput.permissionRequest(.deny(message: "Denied from notchAgent.")))
    }

    @Test func noDecisionPrintsNothing() async throws {
        let (server, port) = try await startServer { _ in .noDecision }
        defer { server.stop() }
        let r = try await Scripts.hook("PermissionRequest", port: port, stdin: try BridgeFixture.data("permission-request-edit"))
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty)
    }

    @Test func aNonPermissionEventPrintsNothingButIsDelivered() async throws {
        let recorder = Recorder()
        let (server, port) = try await startServer { event in
            await recorder.record(event)
            return .ack
        }
        defer { server.stop() }
        for (event, fixture) in [("PreToolUse", "pre-tool-use-bash"), ("Stop", "stop"), ("UserPromptSubmit", "user-prompt-submit")] {
            let r = try await Scripts.hook(event, port: port, stdin: try BridgeFixture.data(fixture))
            #expect(r.status == 0)
            #expect(r.stdout.isEmpty, "\(event) must print nothing")
        }
        #expect(await recorder.eventNames == ["PreToolUse", "Stop", "UserPromptSubmit"])
        #expect(await recorder.events.first?.toolInput == (try BridgeFixture.event("pre-tool-use-bash")).toolInput)
    }

    @Test func aDecisionOnANonPermissionEventIsNeverPrinted() async throws {
        // Even if the server misbehaves, stdout stays empty for every event except PermissionRequest.
        let (server, port) = try await startServer { _ in .decision(.allow) }
        defer { server.stop() }
        let r = try await Scripts.hook("PreToolUse", port: port, stdin: try BridgeFixture.data("pre-tool-use-bash"))
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty)
    }

    @Test func serverDownGivesEmptyOutputExitZeroInUnderASecond() async throws {
        let (probe, port) = try await startServer { _ in .ack }
        probe.stop()  // the port is now free and nothing listens on it
        for event in ["PermissionRequest", "PreToolUse", "Stop"] {
            let r = try await Scripts.hook(event, port: port, stdin: try BridgeFixture.data("permission-request-bash-npm-test"))
            #expect(r.status == 0)
            #expect(r.stdout.isEmpty)
            #expect(r.err.isEmpty)
            #expect(r.elapsed < .seconds(1), "took \(r.elapsed)")
        }
    }

    @Test func aBadRequestPrintsNothing() async throws {
        let (server, port) = try await startServer { _ in .decision(.allow) }
        defer { server.stop() }
        let r = try await Scripts.hook("PermissionRequest", port: port, stdin: Data("not json".utf8))
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty)
    }

    @Test func oddArgumentsExitZeroSilently() async throws {
        let recorder = Recorder()
        let (server, port) = try await startServer { event in
            await recorder.record(event)
            return .decision(.allow)
        }
        defer { server.stop() }
        let body = try BridgeFixture.data("permission-request-bash-npm-test")
        for args in [[Scripts.hook], [Scripts.hook, ""], [Scripts.hook, "../health"], [Scripts.hook, "Permission Request"]] {
            let r = try await Scripts.run(args, env: ["NOTCH_AGENT_PORT": String(port)], stdin: body)
            #expect(r.status == 0)
            #expect(r.stdout.isEmpty)
        }
        #expect(await recorder.events.isEmpty)
    }

    @Test func aHeldPermissionRequestWaitsLongerThanOneSecond() async throws {
        let gate = Gate()
        let (server, port) = try await startServer { event in await gate.hold(event.sessionID) }
        defer { server.stop() }
        let proc = try Subprocess([Scripts.hook, "PermissionRequest"], env: ["NOTCH_AGENT_PORT": String(port)],
                                  stdin: try BridgeFixture.data("permission-request-bash-npm-test"))
        #expect(await eventually { await gate.isHolding(BridgeFixture.sessionID) })
        try await Task.sleep(for: .milliseconds(1500))  // past the 1 s limit used for other events
        await gate.release(BridgeFixture.sessionID, with: .decision(.allow))
        let r = await proc.wait()
        #expect(r.status == 0)
        #expect(r.stdout == HookOutput.permissionRequest(.allow))
    }

    @Test func otherEventsGiveUpAfterAboutOneSecond() async throws {
        let recorder = Recorder()
        let (server, port) = try await startServer(sleepingHandler(recorder, seconds: 10))
        defer { server.stop() }
        let r = try await Scripts.hook("PreToolUse", port: port, stdin: try BridgeFixture.data("pre-tool-use-read"))
        #expect(r.status == 0)
        #expect(r.stdout.isEmpty)
        #expect(r.elapsed < .seconds(3), "took \(r.elapsed)")
        #expect(await eventually { await recorder.cancelled == 1 }, "curl hanging up cancels the handler")
    }

    @Test func killingTheHookDropsTheConnectionAndCancelsTheHeldRequest() async throws {
        let recorder = Recorder()
        let (server, port) = try await startServer(sleepingHandler(recorder))
        defer { server.stop() }
        let proc = try Subprocess([Scripts.hook, "PermissionRequest"], env: ["NOTCH_AGENT_PORT": String(port)],
                                  stdin: try BridgeFixture.data("permission-request-bash-npm-test"))
        #expect(await eventually { await recorder.started == 1 })
        proc.terminate()  // SIGTERM, as when Claude Code ends the hook
        let r = await proc.wait()
        #expect(r.stdout.isEmpty)
        #expect(r.status == 0 && r.reason == .exit, "status \(r.status), reason \(r.reason.rawValue)")
        #expect(await eventually(timeout: .seconds(3)) { await recorder.cancelled == 1 })
        #expect(await eventually { server.openConnectionCount == 0 })
    }

    @Test func theHookLeavesNoTempFilesBehind() async throws {
        let tmp = try TempDir()
        let (server, port) = try await startServer { _ in .decision(.allow) }
        defer { server.stop() }
        let r = try await Scripts.run([Scripts.hook, "PermissionRequest"],
                                      env: ["NOTCH_AGENT_PORT": String(port), "TMPDIR": tmp.url.path],
                                      stdin: try BridgeFixture.data("permission-request-bash-npm-test"))
        #expect(r.stdout == HookOutput.permissionRequest(.allow))
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path).isEmpty)
    }
}

// MARK: - install-hooks.sh / uninstall-hooks.sh on temp settings files

@Suite(.timeLimit(.minutes(1))) struct InstallScriptTests {
    @Test func installCreatesTheNineEventsInANewFile() async throws {
        let tmp = try TempDir()
        let r = try await tmp.install()
        #expect(r.status == 0, "\(r.err)")
        #expect(!r.out.isEmpty)
        let doc = try json(tmp.settings)
        #expect(doc.objectValue.map { Array($0.keys) } == ["hooks"])
        let hooks = try #require(doc["hooks"]?.objectValue)
        #expect(Set(hooks.keys) == Set(Scripts.nineEvents))
        for event in Scripts.nineEvents {
            let groups = try #require(hooks[event]?.arrayValue)
            #expect(groups.count == 1)
            #expect(groups[0]["matcher"] == nil, "no matcher: match everything")
            let handlers = try #require(groups[0]["hooks"]?.arrayValue)
            #expect(handlers.count == 1)
            #expect(handlers[0]["type"] == "command")
            #expect(handlers[0].string("command") == "'\(Scripts.hook)' \(event)")
            switch event {
            case "PermissionRequest": #expect(handlers[0]["timeout"] == 600)
            case "SessionEnd": #expect(handlers[0]["timeout"] == nil)
            default: #expect(handlers[0]["timeout"] == 5)
            }
        }
        #expect(try tmp.backups(of: tmp.settings).isEmpty, "nothing to back up for a new file")
    }

    @Test func installingTwiceGivesAByteIdenticalFile() async throws {
        let tmp = try TempDir()
        try tmp.write(existingSettings, to: tmp.settings)
        #expect(try await tmp.install().status == 0)
        let first = try Data(contentsOf: tmp.settings)
        let r = try await tmp.install()
        #expect(r.status == 0)
        #expect(try Data(contentsOf: tmp.settings) == first)
        // Also from a fresh file.
        let fresh = tmp.url.appendingPathComponent("fresh/settings.json")
        #expect(try await tmp.install(settings: fresh).status == 0)
        let a = try Data(contentsOf: fresh)
        #expect(try await tmp.install(settings: fresh).status == 0)
        #expect(try Data(contentsOf: fresh) == a)
        let handlers = try json(fresh)["hooks"]?.objectValue?.values.flatMap { $0.arrayValue ?? [] } ?? []
        #expect(handlers.count == 9, "one group per event, never duplicated")
    }

    @Test func unrelatedKeysAndHooksSurvive() async throws {
        let tmp = try TempDir()
        try tmp.write(existingSettings, to: tmp.settings)
        let original = try JSONValue.parse(Data(existingSettings.utf8))
        #expect(try await tmp.install().status == 0)
        let doc = try json(tmp.settings)
        for key in ["model", "env", "permissions", "statusLine"] {
            #expect(doc[key] == original[key], "\(key) changed")
        }
        #expect(doc["hooks"]?["SubagentStop"] == original["hooks"]?["SubagentStop"])
        let pre = try #require(doc["hooks"]?["PreToolUse"]?.arrayValue)
        #expect(pre.count == 2)
        #expect(pre[0] == original["hooks"]?["PreToolUse"]?.arrayValue?[0], "the user's group stays first and untouched")
        #expect(pre[1]["hooks"]?.arrayValue?[0].string("command")?.contains("notch-agent-hook.sh") == true)
    }

    @Test func anExistingFileIsBackedUpFirst() async throws {
        let tmp = try TempDir()
        try tmp.write(existingSettings, to: tmp.settings)
        let r = try await tmp.install()
        #expect(r.status == 0)
        let backups = try tmp.backups(of: tmp.settings)
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        #expect(try Data(contentsOf: backup) == Data(existingSettings.utf8))
        #expect(backup.lastPathComponent.range(of: #"\.notch-agent-backup-\d{8}-\d{6}$"#, options: .regularExpression) != nil)
        #expect(r.out.contains(backup.lastPathComponent))
        // A no-op second run makes no new backup.
        #expect(try await tmp.install().status == 0)
        #expect(try tmp.backups(of: tmp.settings).count == 1)
    }

    @Test(arguments: ["{ \"hooks\": ", "not json at all", "", "{} {}"])
    func invalidJSONIsRefusedAndLeftUntouched(_ content: String) async throws {
        let tmp = try TempDir()
        try tmp.write(content, to: tmp.settings)
        let r = try await tmp.install()
        #expect(r.status == 1)
        #expect(!r.err.isEmpty)
        #expect(r.stdout.isEmpty)
        #expect(try Data(contentsOf: tmp.settings) == Data(content.utf8))
        #expect(try tmp.backups(of: tmp.settings).isEmpty)
        let u = try await tmp.uninstall()
        #expect(u.status == 1)
        #expect(try Data(contentsOf: tmp.settings) == Data(content.utf8))
    }

    @Test(arguments: [#"[1, 2]"#, #"{"hooks": []}"#, #"{"hooks": {"PreToolUse": {"hooks": []}}}"#])
    func unexpectedShapesAreRefused(_ content: String) async throws {
        let tmp = try TempDir()
        try tmp.write(content, to: tmp.settings)
        let r = try await tmp.install()
        #expect(r.status == 1)
        #expect(try Data(contentsOf: tmp.settings) == Data(content.utf8))
        #expect(try tmp.backups(of: tmp.settings).isEmpty)
    }

    @Test func uninstallAfterInstallRestoresTheOriginal() async throws {
        let tmp = try TempDir()
        try tmp.write(existingSettings, to: tmp.settings)
        let original = tmp.url.appendingPathComponent("original.json")
        try tmp.write(existingSettings, to: original)
        #expect(try await tmp.install().status == 0)
        #expect(try await tmp.install().status == 0)
        let r = try await tmp.uninstall()
        #expect(r.status == 0, "\(r.err)")
        #expect(r.out.contains("Removed 9"))
        #expect(try await jqSorted(tmp.settings) == (try await jqSorted(original)))
        #expect(try json(tmp.settings) == (try json(original)))
        #expect(try tmp.backups(of: tmp.settings).count == 2, "install and uninstall each back up")
    }

    @Test func uninstallOfAFileInstallCreatedLeavesAnEmptyObject() async throws {
        let tmp = try TempDir()
        #expect(try await tmp.install().status == 0)
        #expect(try await tmp.uninstall().status == 0)
        #expect(try json(tmp.settings) == .object([:]))
    }

    @Test func uninstallRemovesOnlyNotchAgentHandlers() async throws {
        let tmp = try TempDir()
        try tmp.write("""
        {"hooks": {
          "PreToolUse": [{"matcher": "Bash", "hooks": [
            {"type": "command", "command": "~/bin/audit.sh"},
            {"type": "command", "command": "'/old/notchAgent.app/Contents/Resources/hooks/notch-agent-hook.sh' PreToolUse", "timeout": 5}
          ]}],
          "Stop": [{"hooks": [{"type": "command", "command": "/somewhere/notch-agent-hook.sh Stop"}]}],
          "Notification": [{"hooks": [{"type": "command", "command": "terminal-notifier"}]}]
        }, "model": "sonnet"}
        """, to: tmp.settings)
        let r = try await tmp.uninstall()
        #expect(r.status == 0)
        let doc = try json(tmp.settings)
        #expect(doc["model"] == "sonnet")
        #expect(doc["hooks"]?["Stop"] == nil, "an event left empty by the removal is dropped")
        #expect(doc["hooks"]?["PreToolUse"]?.arrayValue?.count == 1)
        #expect(doc["hooks"]?["PreToolUse"]?[ "hooks"] == nil)
        #expect(doc["hooks"]?["PreToolUse"]?.arrayValue?[0]["hooks"]?.arrayValue?.count == 1)
        #expect(doc["hooks"]?["PreToolUse"]?.arrayValue?[0]["matcher"] == "Bash")
        #expect(doc["hooks"]?["Notification"]?.arrayValue?.count == 1)
        // Installing over stale entries replaces them instead of duplicating.
        try tmp.write("""
        {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "/somewhere/notch-agent-hook.sh Stop"}]}]}}
        """, to: tmp.settings)
        #expect(try await tmp.install().status == 0)
        let stop = try json(tmp.settings)["hooks"]?["Stop"]?.arrayValue ?? []
        #expect(stop.count == 1)
        #expect(stop.first?["hooks"]?.arrayValue?.first?.string("command") == "'\(Scripts.hook)' Stop")
    }

    /// Before the rename the hook was nod-hook.sh. Those entries are still ours: install replaces them and
    /// uninstall removes them, while an unrelated my-nod-hook.sh is left alone.
    @Test func entriesFromBeforeTheRenameAreReplacedAndRemoved() async throws {
        let tmp = try TempDir()
        try tmp.write("""
        {"hooks": {
          "Stop": [{"hooks": [{"type": "command", "command": "'/old/Nod.app/Contents/Resources/hooks/nod-hook.sh' Stop"}]}],
          "PreToolUse": [{"hooks": [{"type": "command", "command": "~/bin/my-nod-hook.sh PreToolUse"}]}]
        }}
        """, to: tmp.settings)
        #expect(try await tmp.install().status == 0)
        let stop = try json(tmp.settings)["hooks"]?["Stop"]?.arrayValue ?? []
        #expect(stop.count == 1)
        #expect(stop.first?["hooks"]?.arrayValue?.first?.string("command") == "'\(Scripts.hook)' Stop")
        #expect(try await tmp.uninstall().status == 0)
        let doc = try json(tmp.settings)
        #expect(doc["hooks"]?["Stop"] == nil)
        let pre = doc["hooks"]?["PreToolUse"]?.arrayValue ?? []
        #expect(pre.count == 1)
        #expect(pre.first?["hooks"]?.arrayValue?.first?.string("command") == "~/bin/my-nod-hook.sh PreToolUse")
    }

    @Test func uninstallWithoutAFileIsANoOp() async throws {
        let tmp = try TempDir()
        let r = try await tmp.uninstall()
        #expect(r.status == 0)
        #expect(!FileManager.default.fileExists(atPath: tmp.settings.path))
        #expect(!FileManager.default.fileExists(atPath: tmp.settings.deletingLastPathComponent().path))
    }

    @Test func uninstallWithoutNotchAgentEntriesChangesNothing() async throws {
        let tmp = try TempDir()
        try tmp.write(existingSettings, to: tmp.settings)
        let r = try await tmp.uninstall()
        #expect(r.status == 0)
        #expect(try Data(contentsOf: tmp.settings) == Data(existingSettings.utf8))
        #expect(try tmp.backups(of: tmp.settings).isEmpty)
    }

    @Test func dryRunWritesNothing() async throws {
        let tmp = try TempDir()
        // No file: nothing created, not even the directory.
        let r = try await tmp.install(["--dry-run"])
        #expect(r.status == 0)
        #expect(!FileManager.default.fileExists(atPath: tmp.settings.deletingLastPathComponent().path))
        let printed = try JSONValue.parse(r.stdout)
        #expect(Set(printed["hooks"]?.objectValue?.keys.map { $0 } ?? []) == Set(Scripts.nineEvents))

        // Existing file: unchanged, no backup.
        try tmp.write(existingSettings, to: tmp.settings)
        let r2 = try await tmp.install(["--dry-run"])
        #expect(r2.status == 0)
        #expect(try Data(contentsOf: tmp.settings) == Data(existingSettings.utf8))
        #expect(try tmp.backups(of: tmp.settings).isEmpty)
        #expect(try JSONValue.parse(r2.stdout)["model"] == "opus")

        // Uninstall --dry-run on an installed file: unchanged, prints the cleaned document.
        #expect(try await tmp.install().status == 0)
        let installed = try Data(contentsOf: tmp.settings)
        let backups = try tmp.backups(of: tmp.settings).count
        let u = try await tmp.uninstall(["--dry-run"])
        #expect(u.status == 0)
        #expect(try Data(contentsOf: tmp.settings) == installed)
        #expect(try tmp.backups(of: tmp.settings).count == backups)
        #expect(try JSONValue.parse(u.stdout) == (try JSONValue.parse(Data(existingSettings.utf8))))
    }

    @Test func aCustomHookPathIsQuotedAndRuns() async throws {
        let tmp = try TempDir()
        let dir = tmp.url.appendingPathComponent("notchAgent's App/Contents/Resources/hooks")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let hook = dir.appendingPathComponent("notch-agent-hook.sh")
        try FileManager.default.copyItem(atPath: Scripts.hook, toPath: hook.path)
        let r = try await tmp.install(["--hook", hook.path])
        #expect(r.status == 0, "\(r.err)")
        let command = try #require(json(tmp.settings)["hooks"]?["PermissionRequest"]?.arrayValue?.first?["hooks"]?.arrayValue?.first?.string("command"))
        #expect(command.hasSuffix(" PermissionRequest"))
        #expect(command.contains("notch-agent-hook.sh"))

        // The command string runs through a shell exactly as Claude Code would run it.
        let (server, port) = try await startServer { _ in .decision(.allow) }
        defer { server.stop() }
        let run = try await Scripts.run(["-c", command], env: ["NOTCH_AGENT_PORT": String(port)],
                                        stdin: try BridgeFixture.data("permission-request-bash-npm-test"), executable: "/bin/sh")
        #expect(run.status == 0)
        #expect(run.stdout == HookOutput.permissionRequest(.allow))
    }

    @Test func theInstalledCommandsReachNotchAgent() async throws {
        let tmp = try TempDir()
        #expect(try await tmp.install().status == 0)
        let recorder = Recorder()
        let (server, port) = try await startServer { event in
            await recorder.record(event)
            return event.eventName == .permissionRequest ? .decision(.deny(message: nil)) : .ack
        }
        defer { server.stop() }
        let hooks = try #require(json(tmp.settings)["hooks"])
        let fixtures = ["SessionStart": "session-start", "PreToolUse": "pre-tool-use-bash",
                        "PermissionRequest": "permission-request-bash-npm-test", "SessionEnd": "session-end"]
        for (event, fixture) in fixtures.sorted(by: { $0.key < $1.key }) {
            let command = try #require(hooks[event]?.arrayValue?.first?["hooks"]?.arrayValue?.first?.string("command"))
            let r = try await Scripts.run(["-c", command], env: ["NOTCH_AGENT_PORT": String(port)],
                                          stdin: try BridgeFixture.data(fixture), executable: "/bin/sh")
            #expect(r.status == 0)
            if event == "PermissionRequest" {
                #expect(r.stdout == HookOutput.permissionRequest(.deny(message: nil)))
            } else {
                #expect(r.stdout.isEmpty)
            }
        }
        #expect(await recorder.events.count == 4)
    }

    @Test func aMissingHookScriptIsRefused() async throws {
        let tmp = try TempDir()
        let r = try await tmp.install(["--hook", tmp.url.appendingPathComponent("nope/notch-agent-hook.sh").path])
        #expect(r.status == 1)
        #expect(!FileManager.default.fileExists(atPath: tmp.settings.path))
    }

    @Test func aSymlinkedSettingsFileStaysALink() async throws {
        let tmp = try TempDir()
        let real = tmp.url.appendingPathComponent("dotfiles/claude-settings.json")
        try tmp.write(existingSettings, to: real)
        try FileManager.default.createDirectory(at: tmp.settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: tmp.settings, withDestinationURL: real)
        #expect(try await tmp.install().status == 0)
        let attrs = try FileManager.default.attributesOfItem(atPath: tmp.settings.path)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try json(real)["hooks"]?["PermissionRequest"] != nil)
        #expect(try await tmp.uninstall().status == 0)
        #expect(try json(real) == (try JSONValue.parse(Data(existingSettings.utf8))))
    }

    @Test func helpExitsZero() async throws {
        for script in [Scripts.install, Scripts.uninstall, Scripts.simulate] {
            let r = try await Scripts.run([script, "-h"], env: ["HOME": "/nonexistent-notch-agent-test-home"])
            #expect(r.status == 0)
            #expect(r.out.contains("Usage"))
        }
    }
}

// MARK: - simulate.sh

@Suite(.timeLimit(.minutes(1))) struct SimulateScriptTests {
    @Test func postsAFixtureByNameAndPrintsTheStatus() async throws {
        let recorder = Recorder()
        let (server, port) = try await startServer { event in
            await recorder.record(event)
            return .ack
        }
        defer { server.stop() }
        let r = try await Scripts.run([Scripts.simulate, "--port", String(port), "session-start", "pre-tool-use-read"])
        #expect(r.status == 0, "\(r.err)")
        #expect(r.out.contains("200"))
        #expect(await recorder.eventNames == ["SessionStart", "PreToolUse"])
    }

    @Test func sessionOverrideAndPathsWork() async throws {
        let recorder = Recorder()
        let (server, port) = try await startServer { event in
            await recorder.record(event)
            return .ack
        }
        defer { server.stop() }
        let path = BridgeFixture.fixturesDir.appendingPathComponent("stop.json").path
        let r = try await Scripts.run([Scripts.simulate, "--session", "sim-2", path], env: ["NOTCH_AGENT_PORT": String(port)])
        #expect(r.status == 0, "\(r.err)")
        #expect(await recorder.events.map(\.sessionID) == ["sim-2"])
    }

    @Test func theStoryPlaysInOrderAndPrintsDecisions() async throws {
        let recorder = Recorder()
        let (server, port) = try await startServer { event in
            await recorder.record(event)
            if event.eventName == .permissionRequest {
                return event.toolInput?.string("command")?.hasPrefix("rm") == true ? .decision(.deny(message: nil)) : .decision(.allow)
            }
            return .ack
        }
        defer { server.stop() }
        let r = try await Scripts.run([Scripts.simulate, "--port", String(port), "--fast", "story"])
        #expect(r.status == 0, "\(r.err)")
        #expect(await recorder.eventNames == ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PreToolUse",
                                              "PostToolUse", "PermissionRequest", "PostToolUse", "PermissionRequest", "Stop"])
        #expect(r.out.contains("-> allow"))
        #expect(r.out.contains("-> deny"))
    }

    @Test func notchAgentDownFailsFast() async throws {
        let (probe, port) = try await startServer { _ in .ack }
        probe.stop()
        let r = try await Scripts.run([Scripts.simulate, "--port", String(port), "stop"])
        #expect(r.status != 0)
        #expect(r.err.contains("not reachable"))
    }

    @Test func anUnknownFixtureFails() async throws {
        let (server, port) = try await startServer { _ in .ack }
        defer { server.stop() }
        let r = try await Scripts.run([Scripts.simulate, "--port", String(port), "no-such-fixture"])
        #expect(r.status != 0)
        #expect(r.err.contains("no such fixture"))
    }
}

// MARK: - Review findings: SIGKILL fail-open, exact hook-name matching

@Suite(.timeLimit(.minutes(1))) struct HookScriptHardeningTests {
    /// SIGKILL runs no trap: the watchdog must end curl (so notchAgent drops the card) and remove the payload.
    @Test func aSIGKILLedHookStillDropsTheConnectionAndItsTempFiles() async throws {
        let tmp = try TempDir()
        let recorder = Recorder()
        let (server, port) = try await startServer(sleepingHandler(recorder))
        defer { server.stop() }
        let proc = try Subprocess([Scripts.hook, "PermissionRequest"],
                                  env: ["NOTCH_AGENT_PORT": String(port), "TMPDIR": tmp.url.path],
                                  stdin: try BridgeFixture.data("permission-request-bash-npm-test"))
        #expect(await eventually { await recorder.started == 1 })
        kill(proc.process.processIdentifier, SIGKILL)
        _ = await proc.wait()
        #expect(await eventually(timeout: .seconds(5)) { await recorder.cancelled == 1 })
        #expect(await eventually(timeout: .seconds(5)) { server.openConnectionCount == 0 })
        #expect(await eventually(timeout: .seconds(5)) {
            (try? FileManager.default.contentsOfDirectory(atPath: tmp.url.path).isEmpty) == true
        }, "the payload copy is removed")
    }

    @Test func uninstallAndReinstallLeaveASimilarlyNamedHookAlone() async throws {
        let tmp = try TempDir()
        try tmp.write("""
        {"hooks": {
          "Stop": [{"hooks": [
            {"type": "command", "command": "~/bin/my-notch-agent-hook.sh Stop"},
            {"type": "command", "command": "/somewhere/notch-agent-hook.sh.bak Stop"},
            {"type": "command", "command": "/somewhere/notch-agent-hook.sh Stop"},
            {"type": "command", "command": "'/quoted path/notch-agent-hook.sh' Stop"},
            {"type": "command", "command": "notch-agent-hook.sh"}
          ]}]
        }}
        """, to: tmp.settings)
        #expect(try await tmp.uninstall().status == 0)
        let left = try json(tmp.settings)["hooks"]?["Stop"]?.arrayValue?.first?["hooks"]?.arrayValue ?? []
        #expect(left.compactMap { $0.string("command") } == ["~/bin/my-notch-agent-hook.sh Stop", "/somewhere/notch-agent-hook.sh.bak Stop"])
        #expect(try await tmp.install().status == 0)
        let stop = try json(tmp.settings)["hooks"]?["Stop"]?.arrayValue ?? []
        let commands = stop.flatMap { $0["hooks"]?.arrayValue ?? [] }.compactMap { $0.string("command") }
        #expect(commands == ["~/bin/my-notch-agent-hook.sh Stop", "/somewhere/notch-agent-hook.sh.bak Stop", "'\(Scripts.hook)' Stop"])
    }
}
