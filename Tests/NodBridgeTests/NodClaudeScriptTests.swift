// Runs scripts/nod-claude with a fake `tmux` first on PATH, a stub claude, and HOME / NOD_PANES_DIR in temp
// directories. The real tmux, the real claude and ~/Library are never touched.
import Foundation
import Testing
import NodCore

private struct Sandbox {
    let base: URL
    let bin: URL
    let work: URL
    let panes: URL
    let log: URL
    let stub: URL

    /// `existingSessions`: names the fake `has-session` reports as taken.
    init(existingSessions: [String] = [], withTmux: Bool = true) throws {
        let fm = FileManager.default
        base = URL(fileURLWithPath: physicalPath(fm.temporaryDirectory.path))
            .appendingPathComponent("nod-claude-\(UUID().uuidString)", isDirectory: true)
        bin = base.appendingPathComponent("bin", isDirectory: true)
        // A directory name with a space: every path in the script must be quoted.
        work = base.appendingPathComponent("my repo", isDirectory: true)
        panes = base.appendingPathComponent("support dir/panes", isDirectory: true)
        log = base.appendingPathComponent("tmux.log")
        stub = bin.appendingPathComponent("claude-stub")
        for dir in [bin, work] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        try Self.script("#!/bin/bash\nexit 0\n", at: stub)
        if withTmux {
            let taken = existingSessions.map { "\"=\($0)\"" }.joined(separator: " | ")
            try Self.script("""
            #!/bin/bash
            # Fake tmux: one argument per line, then a separator.
            for a in "$@"; do printf '%s\\n' "$a" >>"$FAKE_TMUX_LOG"; done
            printf -- '----\\n' >>"$FAKE_TMUX_LOG"
            case "$1" in
              has-session)
                case "$3" in \(taken.isEmpty ? "\"=never\"" : taken)) exit 0 ;; esac
                exit 1 ;;
              new-session) echo '%7|/tmp/fake.sock|4242' ;;
            esac
            exit 0
            """, at: bin.appendingPathComponent("tmux"))
        }
    }

    static func script(_ text: String, at url: URL) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func run(_ args: [String], env extra: [String: String] = [:]) async throws -> ProcessResult {
        let script = BridgeFixture.repoRoot.appendingPathComponent("scripts/nod-claude").path
        var env = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": base.appendingPathComponent("home").path,
                   "NOD_PANES_DIR": panes.path, "NOD_CLAUDE_BIN": stub.path, "FAKE_TMUX_LOG": log.path, "TMUX": ""]
        for (k, v) in extra { env[k] = v }
        return try await Subprocess(["-c", "cd \"$0\" && exec \"$@\"", work.path, script] + args, env: env).wait()
    }

    /// The fake tmux's invocations, each as its argument list.
    func invocations() -> [[String]] {
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return text.components(separatedBy: "----\n").map { $0.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).dropLast().map { $0 } }
            .filter { !$0.isEmpty }
    }

    func records() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: panes, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

@Suite("scripts/nod-claude")
struct NodClaudeScriptTests {
    @Test func startsClaudeInTmuxAndRecordsThePane() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let result = try await box.run(["--no-attach", "--", "--model", "opus", "two words"])
        #expect(result.status == 0)
        #expect(result.out.isEmpty)

        let files = box.records()
        #expect(files.count == 1)
        let file = try #require(files.first)
        let sid = file.deletingPathExtension().lastPathComponent
        #expect(sid.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, options: .regularExpression) != nil)

        let record = try JSONDecoder().decode(PaneRecord.self, from: Data(contentsOf: file))
        #expect(record.sessionID == sid)
        #expect(record.paneID == "%7")
        #expect(record.socketPath == "/tmp/fake.sock")
        #expect(record.serverPID == 4242)
        #expect(record.cwd == box.work.path)
        #expect(record.tmuxSession == "nod-my-repo")
        #expect(record.startedAt.range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$"#, options: .regularExpression) != nil)
        // server_pid is a JSON number and the object has exactly the seven keys.
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(object["server_pid"] as? Int == 4242)
        #expect(Set(object.keys) == ["session_id", "pane_id", "tmux_session", "socket_path", "server_pid", "cwd", "started_at"])
        // The registry Nod uses finds it.
        #expect(PaneRegistry(directory: box.panes).lookup(sessionID: sid, cwd: "")?.paneID == "%7")

        let calls = box.invocations()
        let create = try #require(calls.first { $0.first == "new-session" })
        #expect(create == ["new-session", "-d", "-s", "nod-my-repo", "-c", box.work.path, "-P", "-F",
                           "#{pane_id}|#{socket_path}|#{pid}", "--", box.stub.path, "--session-id", sid,
                           "--model", "opus", "two words"])
        #expect(!calls.contains { $0.first == "attach-session" || $0.first == "switch-client" })
        #expect(result.err.contains("session nod-my-repo pane %7 (session id \(sid))"))
        // Nothing was written anywhere else under the fake home.
        #expect(!FileManager.default.fileExists(atPath: box.base.appendingPathComponent("home").path))
    }

    @Test func theNameIsSanitizedForTmux() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let result = try await box.run(["--name", "my.repo:x", "--no-attach"])
        #expect(result.status == 0)
        let create = try #require(box.invocations().first { $0.first == "new-session" })
        #expect(Array(create[1...3]) == ["-d", "-s", "my-repo-x"])
    }

    @Test func aTakenNameGetsASuffix() async throws {
        let box = try Sandbox(existingSessions: ["nod-my-repo", "nod-my-repo-2"]); defer { box.cleanup() }
        let result = try await box.run(["--no-attach"])
        #expect(result.status == 0)
        let create = try #require(box.invocations().first { $0.first == "new-session" })
        #expect(create[3] == "nod-my-repo-3")
        let record = try JSONDecoder().decode(PaneRecord.self, from: Data(contentsOf: try #require(box.records().first)))
        #expect(record.tmuxSession == "nod-my-repo-3")
    }

    @Test func attachesUnlessToldNotTo() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let result = try await box.run([])
        #expect(result.status == 0)
        #expect(box.invocations().contains(["attach-session", "-t", "=nod-my-repo"]))
        // The fake session is "gone" after attach returns (has-session fails), so the record is removed.
        #expect(box.records().isEmpty)

        let inside = try Sandbox(); defer { inside.cleanup() }
        _ = try await inside.run([], env: ["TMUX": "/tmp/outer,1,0"])
        #expect(inside.invocations().contains(["switch-client", "-t", "=nod-my-repo"]))
        #expect(inside.records().count == 1)
    }

    @Test func withoutTmuxItFailsAndWritesNothing() async throws {
        let box = try Sandbox(withTmux: false); defer { box.cleanup() }
        let result = try await box.run(["--no-attach"])
        #expect(result.status == 1)
        #expect(result.err.contains("tmux"))
        #expect(result.err.contains("brew install tmux"))
        #expect(box.records().isEmpty)
    }

    @Test func aMissingClaudeFails() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let result = try await box.run(["--no-attach"], env: ["NOD_CLAUDE_BIN": "definitely-not-a-program"])
        #expect(result.status == 1)
        #expect(result.err.contains("claude"))
        #expect(!box.invocations().contains { $0.first == "new-session" })
    }

    @Test func helpPrintsUsage() async throws {
        let box = try Sandbox(); defer { box.cleanup() }
        let result = try await box.run(["--help"])
        #expect(result.status == 0)
        #expect(result.out.contains("nod-claude [--name NAME]"))
        #expect(box.invocations().isEmpty)
    }
}
