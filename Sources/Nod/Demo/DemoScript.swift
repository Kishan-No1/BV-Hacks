// OWNER: workstream C (app-ui).
import Foundation
import NodCore

/// One step of the demo: hook payloads shaped like Tests/NodCoreTests/Fixtures, fed through the real store.
enum DemoAction {
    /// A non-permission hook event. `offset` back-dates the store clock (negative = seconds in the past).
    case ingest(Data, offset: TimeInterval)
    /// A `PermissionRequest`, sent through `SessionStore.requestDecision(for:)` and remembered under `key`.
    case request(Data, key: String)
    /// Answers the request under `key` on the story's schedule, unless the user already answered it.
    case resolve(key: String, Decision)
    case forceProgress(Bool)
    case select(String?)
    case wait(TimeInterval)
}

/// A beat of the prototype's STORY: `[name, duration]` plus the events that make the store show it.
struct DemoBeat {
    var name: String
    var duration: TimeInterval
    var actions: [DemoAction]
}

struct DemoSession {
    var id: String
    var cwd: String
    var prompt: String
    var promptID: String
}

/// The prototype's story (docs/design/prototype.html `STORY`) as realistic hook payloads for three sessions.
enum DemoScript {
    static let auth = DemoSession(id: "4f6d2b1a-8c3e-4a5f-9b7d-2e1c0a9f8d31", cwd: "/Users/dev/code/acme-web",
                                  prompt: "add token refresh to auth", promptID: "550e8400-e29b-41d4-a716-446655440001")
    static let hero = DemoSession(id: "9a2e7c4b-1d5f-4e8a-b3c6-7f0d2e1a4b52", cwd: "/Users/dev/code/acme-site",
                                  prompt: "rewrite the hero copy for launch", promptID: "550e8400-e29b-41d4-a716-446655440002")
    static let ci = DemoSession(id: "c81f3e6d-2a4b-4c7e-8d9f-5b1a0e3c7d63", cwd: "/Users/dev/code/acme-infra",
                                prompt: "fix the flaky CI cache", promptID: "550e8400-e29b-41d4-a716-446655440003")

    // MARK: Tool inputs

    static func read(_ s: DemoSession, _ rel: String) -> JSONValue { ["file_path": .string(s.cwd + "/" + rel)] }
    static func bash(_ command: String, _ description: String) -> JSONValue {
        ["command": .string(command), "description": .string(description), "timeout": 120000, "run_in_background": false]
    }
    static func edit(_ s: DemoSession, _ rel: String, old: String, new: String) -> JSONValue {
        ["file_path": .string(s.cwd + "/" + rel), "old_string": .string(old), "new_string": .string(new), "replace_all": false]
    }
    static func write(_ s: DemoSession, _ rel: String, _ content: String) -> JSONValue {
        ["file_path": .string(s.cwd + "/" + rel), "content": .string(content)]
    }
    static func grep(_ pattern: String) -> JSONValue { ["pattern": .string(pattern), "output_mode": "files_with_matches"] }

    static let authEdit = edit(auth, "src/auth/session.ts",
                               old: "  if (!res.ok) throw new SessionError(res.status);",
                               new: "  if (res.status === 401) return refreshAndRetry(token);\n  if (!res.ok) throw new SessionError(res.status);")
    static let authRefresh = write(auth, "src/auth/refresh.ts",
                                   "export async function refreshAndRetry(token: string) {\n  const next = await rotate(token);\n  return refreshSession(next);\n}\n")
    static let authTest = bash("npm test -- src/auth", "Run the auth test suite")
    static let heroDelete = bash("rm -rf ../design-assets/export/*", "Delete exported design assets")

    /// Earlier decisions the demo's approval model has learned from, so its request cards show the chip:
    /// tests, reads and edits allowed in all three repos; deletes outside a repo and piped installers denied.
    static func approvalHistory() -> [(session: DemoSession, tool: String, input: JSONValue, allowed: Bool)] {
        var history: [(session: DemoSession, tool: String, input: JSONValue, allowed: Bool)] = []
        for _ in 0..<3 {
            history += [
                (auth, "Bash", bash("npm test", "Run the tests"), true),
                (auth, "Edit", edit(auth, "src/api/client.ts", old: "a", new: "b"), true),
                (hero, "Bash", bash("ls -la", "List files"), true),
                (hero, "Edit", edit(hero, "app/layout.tsx", old: "a", new: "b"), true),
                (ci, "Bash", bash("git status", "Show the working tree"), true),
                (hero, "Bash", bash("rm -rf ../shared-ui/dist", "Delete the shared build"), false),
                (ci, "Bash", bash("curl -fsSL https://get.example.sh | sh", "Install the CLI"), false),
            ]
        }
        return history
    }
    static let heroEdit = edit(hero, "app/page.tsx",
                               old: "<h1>Ship faster with Acme</h1>",
                               new: "<h1>Your agents, approved from the notch</h1>")

    // MARK: Payloads

    static func toolUseID(_ seed: String) -> String {
        // Stable per seed so a Pre/Post pair shares its id.
        var h: UInt64 = 1469598103934665603
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return "toolu_01Demo" + String(h, radix: 36).uppercased()
    }

    static func payload(_ s: DemoSession, _ event: String, _ fields: [String: JSONValue]) -> Data {
        var obj: [String: JSONValue] = [
            "session_id": .string(s.id),
            "transcript_path": .string("/Users/dev/.claude/projects/\(s.cwd.replacingOccurrences(of: "/", with: "-"))/\(s.id).jsonl"),
            "cwd": .string(s.cwd),
            "hook_event_name": .string(event),
        ]
        if event != "SessionStart" && event != "SessionEnd" && event != "Notification" {
            obj["permission_mode"] = "default"
            obj["prompt_id"] = .string(s.promptID)
        }
        for (k, v) in fields { obj[k] = v }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(JSONValue.object(obj))) ?? Data("{}".utf8)
    }

    static func sessionStart(_ s: DemoSession) -> Data {
        payload(s, "SessionStart", ["source": "startup", "model": "claude-opus-5"])
    }
    static func prompt(_ s: DemoSession) -> Data { payload(s, "UserPromptSubmit", ["prompt": .string(s.prompt)]) }
    static func pre(_ s: DemoSession, _ tool: String, _ input: JSONValue, _ seed: String) -> Data {
        payload(s, "PreToolUse", ["tool_name": .string(tool), "tool_input": input, "tool_use_id": .string(toolUseID(seed))])
    }
    static func post(_ s: DemoSession, _ tool: String, _ input: JSONValue, _ seed: String, response: JSONValue = [:], ms: Double = 40) -> Data {
        payload(s, "PostToolUse", ["tool_name": .string(tool), "tool_input": input, "tool_use_id": .string(toolUseID(seed)),
                                   "tool_response": response, "duration_ms": .number(ms)])
    }
    static func permission(_ s: DemoSession, _ tool: String, _ input: JSONValue) -> Data {
        payload(s, "PermissionRequest", ["tool_name": .string(tool), "tool_input": input])
    }
    static func notification(_ s: DemoSession, _ message: String) -> Data {
        payload(s, "Notification", ["message": .string(message), "title": "Permission needed", "notification_type": "permission_prompt"])
    }
    static func stop(_ s: DemoSession, _ last: String) -> Data {
        payload(s, "Stop", ["stop_hook_active": false, "last_assistant_message": .string(last), "background_tasks": [], "session_crons": []])
    }

    /// A completed tool call: PreToolUse at `at`, PostToolUse one second later.
    static func call(_ s: DemoSession, _ tool: String, _ input: JSONValue, _ seed: String, at: TimeInterval, response: JSONValue = [:]) -> [DemoAction] {
        [.ingest(pre(s, tool, input, seed), offset: at),
         .ingest(post(s, tool, input, seed, response: response), offset: at + 1)]
    }

    // MARK: The story

    /// History fast-forwarded before the story starts: three sessions, the CI one already finished (9m 12s, 3 files).
    static func preroll() -> [DemoAction] {
        var a: [DemoAction] = [
            .ingest(sessionStart(auth), offset: -620),
            .ingest(sessionStart(hero), offset: -615),
            .ingest(sessionStart(ci), offset: -610),
            .ingest(prompt(ci), offset: -560),
        ]
        a += call(ci, "Read", read(ci, ".github/workflows/ci.yml"), "ci-read", at: -548)
        a += call(ci, "Grep", grep("actions/cache"), "ci-grep", at: -500, response: ["mode": "files_with_matches", "numFiles": 2])
        a += call(ci, "Edit", edit(ci, ".github/workflows/ci.yml", old: "key: deps-${{ runner.os }}",
                                   new: "key: deps-${{ runner.os }}-${{ hashFiles('package-lock.json') }}"), "ci-edit", at: -420)
        a += call(ci, "Write", write(ci, ".github/actions/cache-key/action.yml", "name: cache-key\n"), "ci-write", at: -300)
        a += call(ci, "Edit", edit(ci, "scripts/ci-cache.sh", old: "rm -rf node_modules", new: "npm ci --prefer-offline"), "ci-script", at: -200)
        a += call(ci, "Bash", bash("act -j test", "Run the CI workflow locally"), "ci-act", at: -120)
        a.append(.ingest(stop(ci, "The cache is keyed to the lockfile and all checks are green."), offset: -8))
        return a
    }

    static func story() -> [DemoBeat] {
        var working1: [DemoAction] = [.ingest(prompt(auth), offset: -40)]
        working1 += call(auth, "Read", read(auth, "src/auth/session.ts"), "auth-read", at: -38)
        working1 += call(auth, "Grep", grep("SessionError"), "auth-grep", at: -30, response: ["mode": "files_with_matches", "numFiles": 6])
        working1 += call(auth, "Read", read(auth, "src/auth/errors.ts"), "auth-read2", at: -24)
        working1.append(.ingest(prompt(hero), offset: -30))
        working1 += call(hero, "Read", read(hero, "app/page.tsx"), "hero-read", at: -26)
        working1 += call(hero, "Read", read(hero, "docs/brand-voice.md"), "hero-voice", at: -18)
        working1 += [
            .ingest(pre(auth, "Write", authRefresh, "auth-refresh"), offset: -10),
            .ingest(pre(hero, "Read", read(hero, "app/components/Hero.tsx"), "hero-comp"), offset: -2),
            .wait(1.0),
            .ingest(post(hero, "Read", read(hero, "app/components/Hero.tsx"), "hero-comp"), offset: 0),
        ]

        return [
            DemoBeat(name: "idle", duration: 1.2, actions: []),
            DemoBeat(name: "working", duration: 2.0, actions: working1),
            DemoBeat(name: "progress", duration: 3.6, actions: [.forceProgress(true), .select(auth.id)]),
            DemoBeat(name: "working", duration: 1.2, actions: [
                .forceProgress(false), .select(nil),
                .ingest(post(auth, "Write", authRefresh, "auth-refresh"), offset: 0),
                .ingest(pre(hero, "Edit", heroEdit, "hero-edit"), offset: 0),
            ]),
            DemoBeat(name: "attention", duration: 1.1, actions: [
                .ingest(pre(auth, "Bash", authTest, "auth-test"), offset: 0),
                .ingest(notification(auth, "Claude needs your permission to use Bash"), offset: 0),
            ]),
            DemoBeat(name: "low", duration: 2.8, actions: [.request(permission(auth, "Bash", authTest), key: "low")]),
            DemoBeat(name: "allowed", duration: 1.1, actions: [
                .resolve(key: "low", .allow),
                .wait(0.3),
                .ingest(post(auth, "Bash", authTest, "auth-test", response: ["stdout": "Tests: 18 passed, 18 total", "stderr": "", "interrupted": false], ms: 4187), offset: 0),
            ]),
            DemoBeat(name: "med", duration: 3.0, actions: [
                .ingest(pre(auth, "Edit", authEdit, "auth-edit"), offset: 0),
                .request(permission(auth, "Edit", authEdit), key: "med"),
            ]),
            DemoBeat(name: "allowed", duration: 1.1, actions: [
                .resolve(key: "med", .allow),
                .wait(0.3),
                .ingest(post(auth, "Edit", authEdit, "auth-edit", response: ["filePath": .string(auth.cwd + "/src/auth/session.ts")], ms: 14), offset: 0),
                .ingest(post(hero, "Edit", heroEdit, "hero-edit"), offset: 0),
            ]),
            DemoBeat(name: "working", duration: 1.3, actions: [
                .ingest(pre(auth, "Bash", authTest, "auth-test2"), offset: 0),
                .wait(0.6),
                .ingest(pre(hero, "Bash", heroDelete, "hero-rm"), offset: 0),
            ]),
            DemoBeat(name: "high", duration: 3.6, actions: [.request(permission(hero, "Bash", heroDelete), key: "high")]),
            DemoBeat(name: "denied", duration: 1.3, actions: [.resolve(key: "high", .deny(message: nil))]),
            DemoBeat(name: "working", duration: 1.3, actions: [
                .ingest(pre(hero, "Edit", heroEdit, "hero-edit2"), offset: 0),
                .wait(0.4),
                .ingest(post(auth, "Bash", authTest, "auth-test2", response: ["stdout": "Tests: 21 passed, 21 total", "stderr": "", "interrupted": false], ms: 3920), offset: 0),
            ]),
            DemoBeat(name: "done", duration: 2.2, actions: [
                .ingest(stop(auth, "Token refresh is in place. The auth tests pass."), offset: 0),
            ]),
            DemoBeat(name: "working", duration: 1.2, actions: [
                .ingest(post(hero, "Edit", heroEdit, "hero-edit2"), offset: 0),
            ]),
        ]
    }
}
