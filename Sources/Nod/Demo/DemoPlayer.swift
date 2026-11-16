// OWNER: workstream C (app-ui).
import Foundation
import NodCore

/// The store clock for demo and snapshot runs: real time (live) or a virtual timeline (fast-forward),
/// shifted by `offset` so history can be back-dated.
final class DemoClock: @unchecked Sendable {
    private let virtualBase: Date?
    private var virtualElapsed: TimeInterval = 0
    var offset: TimeInterval = 0

    init(virtualBase: Date? = nil) {
        self.virtualBase = virtualBase
    }

    func now() -> Date {
        (virtualBase?.addingTimeInterval(virtualElapsed) ?? Date()).addingTimeInterval(offset)
    }

    func advance(_ t: TimeInterval) {
        virtualElapsed += max(0, t)
    }
}

/// Replays `DemoScript` through the REAL store path: `HookEvent.decode` -> `store.ingest` /
/// `store.requestDecision(for:)`. Requests are answered on the story's schedule unless the user answers first.
@MainActor
final class DemoPlayer {
    enum Mode {
        /// Real time, for the menu's "Play demo" and `--demo`.
        case live
        /// No sleeping: the clock jumps forward. Used by `--snapshot` and tests.
        case fastForward
    }

    /// How events reach the store.
    enum Transport {
        /// Call the store directly (works with the hook server off).
        case direct
        /// POST to the local hook server like `hooks/nod-hook.sh` does (`--demo-http`).
        case http(port: UInt16)
    }

    let store: SessionStore
    let clock: DemoClock
    let mode: Mode
    let transport: Transport
    weak var model: IslandModel?

    private(set) var forceProgress = false
    /// Decisions returned by `requestDecision` (or the hook server), keyed by the script's request key.
    private(set) var decisions: [String: Decision] = [:]
    private var requestIDs: [String: UUID] = [:]
    private var requestTasks: [Task<Void, Never>] = []
    private var beatWaited: TimeInterval = 0

    /// A demo store never writes rules to disk.
    static func makeStore(clock: DemoClock) -> SessionStore {
        SessionStore(rules: RulesStore(fileURL: nil), approvals: makeApprovals(), now: { clock.now() })
    }

    /// An in-memory approval model trained on `DemoScript.approvalHistory()`. Never the user's real model.
    static func makeApprovals() -> ApprovalModelStore {
        let approvals = ApprovalModelStore(fileURL: nil)
        let engine = RiskEngine()
        for h in DemoScript.approvalHistory() {
            let assessment = engine.assess(toolName: h.tool, toolInput: h.input, cwd: h.session.cwd)
            approvals.learn(toolName: h.tool, toolInput: h.input, cwd: h.session.cwd, assessment: assessment, allowed: h.allowed)
        }
        return approvals
    }

    init(store: SessionStore, clock: DemoClock, mode: Mode, transport: Transport = .direct, model: IslandModel? = nil) {
        self.store = store
        self.clock = clock
        self.mode = mode
        self.transport = transport
        self.model = model
    }

    /// Plays the preroll and every beat. `afterBeat` runs once a beat's events are in (snapshots, tests).
    func run(afterBeat: ((Int, DemoBeat) async -> Void)? = nil) async {
        model?.beginPreroll()
        for action in DemoScript.preroll() { await perform(action) }
        model?.endPreroll()
        let beats = DemoScript.story()
        for (i, beat) in beats.enumerated() {
            if Task.isCancelled { break }
            Log.debug("demo: beat \(i + 1)/\(beats.count) '\(beat.name)' (\(beat.duration)s)")
            beatWaited = 0
            for action in beat.actions {
                if Task.isCancelled { break }
                await perform(action)
            }
            if let afterBeat { await afterBeat(i, beat) }
            await pause(max(0, beat.duration - beatWaited))
        }
        finish()
        for t in requestTasks { _ = await t.value }
        Log.debug("demo: finished (\(Task.isCancelled ? "cancelled" : "complete"))")
    }

    /// Stops forcing Progress and drops any request still held (no decision).
    func finish() {
        if forceProgress { setForceProgress(false) }
        for (key, id) in requestIDs where store.pending.contains(where: { $0.id == id }) {
            Log.debug("demo: dropping unanswered request '\(key)'")
            store.dismiss(id)
        }
        for t in requestTasks { t.cancel() }
    }

    // MARK: Actions

    private func perform(_ action: DemoAction) async {
        switch action {
        case .ingest(let data, let offset):
            await send(data, offset: offset)
        case .request(let data, let key):
            await request(data, key: key)
        case .resolve(let key, let decision):
            guard let id = requestIDs[key], store.pending.contains(where: { $0.id == id }) else {
                Log.debug("demo: request '\(key)' was already answered")
                return
            }
            store.resolve(id, decision)
        case .forceProgress(let on):
            setForceProgress(on)
        case .select(let id):
            store.selectedSessionID = id
        case .wait(let t):
            beatWaited += t
            await pause(t)
        }
    }

    private func setForceProgress(_ on: Bool) {
        forceProgress = on
        model?.forceProgress = on
    }

    private func pause(_ t: TimeInterval) async {
        guard t > 0 else { return }
        switch mode {
        case .fastForward:
            clock.advance(t)
        case .live:
            try? await Task.sleep(nanoseconds: UInt64(t * 1_000_000_000))
        }
    }

    private func send(_ data: Data, offset: TimeInterval) async {
        switch transport {
        case .direct:
            do {
                let event = try HookEvent.decode(data)
                clock.offset = offset
                store.ingest(event)
                clock.offset = 0
            } catch {
                Log.info("demo: undecodable payload: \(error)")
            }
        case .http(let port):
            _ = await Self.post(data, port: port, timeout: 2)
        }
    }

    private func request(_ data: Data, key: String) async {
        let before = Set(store.pending.map(\.id))
        let task: Task<Void, Never>
        switch transport {
        case .direct:
            guard let event = try? HookEvent.decode(data) else {
                Log.info("demo: undecodable request payload '\(key)'")
                return
            }
            task = Task { @MainActor [weak self, store] in
                let decision = await store.requestDecision(for: event, timeout: 300)
                self?.record(key, decision)
            }
        case .http(let port):
            task = Task { @MainActor [weak self] in
                let body = await Self.post(data, port: port, timeout: 300)
                self?.record(key, body.flatMap(Self.decision(fromHookOutput:)))
            }
        }
        requestTasks.append(task)
        // Wait for the store to enqueue it, so `.resolve` can find it.
        for i in 0..<300 {
            if let new = store.pending.first(where: { !before.contains($0.id) }) {
                requestIDs[key] = new.id
                return
            }
            if i < 50 { await Task.yield() } else { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
        Log.info("demo: request '\(key)' never reached the store")
    }

    private func record(_ key: String, _ decision: Decision?) {
        if let decision { decisions[key] = decision }
        let text: String
        switch decision {
        case .allow?: text = "allow"
        case .deny?: text = "deny"
        case nil: text = "no decision"
        }
        Log.debug("demo: request '\(key)' -> \(text)")
    }

    // MARK: HTTP transport

    /// POSTs a hook payload to `http://127.0.0.1:<port>/hook/<Event>`; returns the body for a 200.
    static func post(_ data: Data, port: UInt16, timeout: TimeInterval) async -> Data? {
        let event = (try? JSONValue.parse(data))?.string("hook_event_name") ?? "Unknown"
        guard let url = URL(string: "http://127.0.0.1:\(port)/hook/\(event)") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        do {
            let (body, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return body
        } catch {
            Log.debug("demo-http: \(event) failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func decision(fromHookOutput body: Data) -> Decision? {
        guard let json = try? JSONValue.parse(body),
              let behavior = json["hookSpecificOutput"]?["decision"]?.string("behavior") else { return nil }
        switch behavior {
        case "allow": return .allow
        case "deny": return .deny(message: json["hookSpecificOutput"]?["decision"]?.string("message"))
        default: return nil
        }
    }
}
