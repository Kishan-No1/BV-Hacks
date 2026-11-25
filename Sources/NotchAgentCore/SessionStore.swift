// OWNER: workstream B (bridge). The public signatures below are FROZEN.
// The bodies are a minimal working reducer so the UI can build against real behavior from minute one;
// workstream B hardens and tests them.
import Foundation
import Observation

/// The single source of truth the island renders: sessions, the pending-request queue, toasts.
@MainActor
@Observable
public final class SessionStore {
    // MARK: Observable state (read by the UI)

    /// Sessions in first-seen order.
    public private(set) var sessions: [Session] = []
    /// Pending permission requests, FIFO across sessions. The island shows `pending.first`.
    public private(set) var pending: [PendingRequest] = []
    /// How many requests a user rule auto-allowed since launch.
    public private(set) var autoAllowedCount: Int = 0
    /// The latest toast. The UI shows it for ~1.1 s keyed on `toast.id`; the store never clears it.
    public private(set) var toast: Toast?
    /// The session Progress shows. nil = automatic (see `activeSession`).
    public var selectedSessionID: String?
    /// The learned approval chip for each pending request that has one (see `ApprovalModel`).
    public private(set) var predictions: [UUID: ApprovalPrediction] = [:]

    // MARK: Constants

    /// Tools notchAgent never answers (they need `updatedInput` with an allow). They fall through to Claude Code's own UI.
    public nonisolated static let passThroughTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]
    /// Seconds a request is held before returning "no decision". Must stay below the hook script's
    /// curl `--max-time` (590) which stays below the hook `timeout` (600).
    public nonisolated static let defaultPermissionTimeout: TimeInterval = 580
    /// Completed steps kept per session.
    public nonisolated static let maxSteps = 200

    @ObservationIgnored private let riskEngine: RiskEngine
    @ObservationIgnored private let rules: RulesStore?
    @ObservationIgnored private let approvals: ApprovalModelStore?
    /// false while a demo plays its scripted decisions through this store, so they never train the model.
    @ObservationIgnored public var learnsFromDecisions = true
    @ObservationIgnored private let now: () -> Date
    /// Maps a hook's parent pid to the Claude Code process. Replaceable for tests.
    @ObservationIgnored public var processResolver: (Int32) -> ProcessIdentity? = ProcessLiveness.claudeProcess(fromHookParent:)
    @ObservationIgnored private var waiters: [UUID: CheckedContinuation<Decision?, Never>] = [:]

    /// `approvals`: the learned approval model. It predicts a chip for each request and learns from each
    /// Allow or Deny made in the island. nil = no chips and no learning.
    public init(riskEngine: RiskEngine = RiskEngine(), rules: RulesStore? = nil, approvals: ApprovalModelStore? = nil,
                now: @escaping () -> Date = Date.init) {
        self.riskEngine = riskEngine
        self.rules = rules
        self.approvals = approvals
        self.now = now
    }

    // MARK: Derived state

    public var currentRequest: PendingRequest? { pending.first }

    public func session(id: String) -> Session? { sessions.first { $0.id == id } }

    /// The session Progress shows: the selected one, else the one with the current request,
    /// else the most recently active working session, else the most recent session.
    public var activeSession: Session? {
        if let id = selectedSessionID, let s = session(id: id) { return s }
        if let r = currentRequest, let s = session(id: r.sessionID) { return s }
        let byRecency = sessions.sorted { $0.lastEventAt > $1.lastEventAt }
        return byRecency.first { $0.status == .working } ?? byRecency.first
    }

    public var isAnyWorking: Bool { sessions.contains { $0.status == .working } }

    // MARK: Ingestion (called by the HookServer handler and by demo mode)

    /// Applies a non-permission hook event. A `PermissionRequest` passed here is ignored
    /// (use `requestDecision(for:timeout:)`).
    public func ingest(_ event: HookEvent) {
        let t = now()
        if event.eventName == .sessionEnd {
            cancelPending(sessionID: event.sessionID)
            sessions.removeAll { $0.id == event.sessionID }
            if selectedSessionID == event.sessionID { selectedSessionID = nil }
            return
        }
        let i = upsertSession(for: event, at: t)
        let input = event.toolInput ?? .object([:])
        let cwd = sessions[i].cwd

        switch event.eventName {
        case .sessionStart:
            if sessions[i].status == .done { sessions[i].status = .idle }

        case .userPromptSubmit:
            cancelPending(sessionID: event.sessionID)
            if let p = event.prompt { sessions[i].lastPrompt = StepFormatter.promptHeadline(p) }
            sessions[i].status = .working
            sessions[i].steps = []
            sessions[i].editedFiles = []
            sessions[i].currentStep = nil
            sessions[i].currentTool = nil
            sessions[i].turnStartedAt = t
            sessions[i].turnEndedAt = nil

        case .preToolUse:
            guard let tool = event.toolName else { break }
            sessions[i].currentStep = StepFormatter.current(toolName: tool, toolInput: input, cwd: cwd)
            sessions[i].currentTool = ToolActivity(
                toolName: tool,
                label: StepFormatter.toolLabel(toolName: tool, toolInput: input, cwd: cwd),
                startedAt: t, toolUseID: event.toolUseID)
            if sessions[i].turnStartedAt == nil { sessions[i].turnStartedAt = t }
            if !hasPending(sessionID: event.sessionID) { sessions[i].status = .working }

        case .postToolUse, .postToolUseFailure:
            guard let tool = event.toolName else { break }
            // The tool ran, so any request we still hold for the same call was answered elsewhere.
            cancelPending(sessionID: event.sessionID) { $0.toolName == tool && $0.toolInput == input }
            let failed = event.eventName == .postToolUseFailure
            appendStep(i, Step(text: StepFormatter.completed(toolName: tool, toolInput: input, cwd: cwd), at: t, failed: failed))
            if !failed, ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(tool),
               let path = input.string("file_path") ?? input.string("notebook_path"),
               !sessions[i].editedFiles.contains(path) {
                sessions[i].editedFiles.append(path)
            }
            if sessions[i].currentTool?.toolUseID == event.toolUseID || sessions[i].currentTool?.toolName == tool {
                sessions[i].currentTool = nil
                sessions[i].currentStep = nil
            }
            if !hasPending(sessionID: event.sessionID) { sessions[i].status = .working }

        case .notification:
            // Claude Code is showing its own dialog. A request card already covers a held request, and a
            // question or plan already has its own (more detailed) attention.
            let kind: Attention.Kind? = switch event.notificationType {
            case "permission_prompt": .permission
            case "elicitation_dialog": .input
            default: nil
            }
            if let kind {
                sessions[i].status = .needsYou
                if !hasPending(sessionID: event.sessionID), sessions[i].attention == nil {
                    sessions[i].attention = Attention(
                        kind: kind,
                        title: kind == .permission ? "Claude needs your permission" : "Claude needs your input",
                        detail: event.message ?? "Answer in Claude Code.", since: t)
                }
            }

        case .stop:
            cancelPending(sessionID: event.sessionID)
            sessions[i].status = .done
            sessions[i].currentStep = nil
            sessions[i].currentTool = nil
            sessions[i].turnEndedAt = t
            toast = Toast(kind: .done, sessionID: event.sessionID, at: t)

        default:
            break
        }
    }

    /// Handles a `PermissionRequest`: returns `.allow` at once when a user rule matches (and counts it),
    /// otherwise enqueues the request and suspends until `resolve`, the timeout, or task cancellation
    /// (= the hook client disconnected). Returns nil for "no decision", which must reach Claude Code
    /// as empty output so it shows its own prompt.
    public func requestDecision(for event: HookEvent, timeout: TimeInterval = SessionStore.defaultPermissionTimeout) async -> Decision? {
        guard event.eventName == .permissionRequest, let tool = event.toolName else {
            ingest(event)
            return nil
        }
        let t = now()
        let i = upsertSession(for: event, at: t)
        let input = event.toolInput ?? .object([:])
        let cwd = sessions[i].cwd

        if Self.passThroughTools.contains(tool) {
            sessions[i].status = .needsYou
            sessions[i].attention = Attention.passThrough(toolName: tool, input: input, at: t)
            return nil
        }

        let assessment = riskEngine.assess(toolName: tool, toolInput: input, cwd: cwd)

        // The ONLY auto-allow path: an explicit user rule, and never for a high-risk call.
        if assessment.level != .high, let rules, let rule = rules.match(toolName: tool, toolInput: input, cwd: cwd) {
            rules.recordHit(id: rule.id)
            autoAllowedCount += 1
            toast = Toast(kind: .autoAllowed, sessionID: event.sessionID, at: t)
            return .allow
        }

        let request = PendingRequest(
            sessionID: event.sessionID, toolName: tool, toolInput: input, cwd: cwd,
            assessment: assessment,
            ruleSuggestion: rules?.suggestion(toolName: tool, toolInput: input, cwd: cwd, assessment: assessment),
            receivedAt: t)
        let id = request.id
        if let prediction = approvals?.predict(request) { predictions[id] = prediction }
        pending.append(request)
        sessions[i].status = .needsYou

        // NaN, negative or absurd timeouts would trap in the UInt64 conversion.
        let seconds = timeout.isFinite ? min(max(0, timeout), 86_400) : Self.defaultPermissionTimeout
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finish(id, decision: nil, statusAfter: .needsYou)
        }
        let decision: Decision? = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Decision?, Never>) in
                if Task.isCancelled {
                    cont.resume(returning: nil)
                    self.finish(id, decision: nil, statusAfter: .working)
                } else {
                    self.waiters[id] = cont
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, decision: nil, statusAfter: .working) }
        }
        timeoutTask.cancel()
        return decision
    }

    // MARK: Actions (called by the UI)

    /// Answers a pending request. With `remember: true` and `.allow`, also stores the request's
    /// `ruleSuggestion` as an always-allow rule. Unknown ids are ignored.
    public func resolve(_ id: PendingRequest.ID, _ decision: Decision, remember: Bool = false) {
        guard let request = pending.first(where: { $0.id == id }) else { return }
        if remember, decision == .allow, let suggestion = request.ruleSuggestion {
            rules?.add(suggestion.makeRule(now: now()))
        }
        // Only a decision made here trains the model: not a timeout, a dismissal, or an answer in the terminal.
        if learnsFromDecisions { approvals?.learn(request, allowed: decision == .allow) }
        toast = Toast(kind: decision == .allow ? .allowed : .denied, sessionID: request.sessionID, at: now())
        finish(id, decision: decision, statusAfter: .working)
        // A denied call never runs, so no PostToolUse(Failure) follows (seen live with Claude Code 2.1.325):
        // drop the tool card that its PreToolUse put up.
        if decision != .allow, let i = sessions.firstIndex(where: { $0.id == request.sessionID }),
           sessions[i].currentTool?.toolName == request.toolName {
            sessions[i].currentTool = nil
            sessions[i].currentStep = nil
        }
    }

    /// Drops a pending request without a decision (Claude Code then shows its own prompt).
    public func dismiss(_ id: PendingRequest.ID) {
        finish(id, decision: nil, statusAfter: .needsYou)
    }

    // MARK: Internals

    private func finish(_ id: UUID, decision: Decision?, statusAfter: SessionStatus) {
        let request = pending.first { $0.id == id }
        pending.removeAll { $0.id == id }
        predictions[id] = nil
        if let cont = waiters.removeValue(forKey: id) { cont.resume(returning: decision) }
        if let request, !hasPending(sessionID: request.sessionID),
           let i = sessions.firstIndex(where: { $0.id == request.sessionID }),
           sessions[i].status == .needsYou {
            sessions[i].status = statusAfter
        }
    }

    private func hasPending(sessionID: String) -> Bool { pending.contains { $0.sessionID == sessionID } }

    private func cancelPending(sessionID: String, where predicate: (PendingRequest) -> Bool = { _ in true }) {
        for r in pending where r.sessionID == sessionID && predicate(r) {
            finish(r.id, decision: nil, statusAfter: .working)
        }
    }

    private func appendStep(_ i: Int, _ step: Step) {
        sessions[i].steps.append(step)
        if sessions[i].steps.count > Self.maxSteps {
            sessions[i].steps.removeFirst(sessions[i].steps.count - Self.maxSteps)
        }
    }

    /// Finds or creates the session for an event (notchAgent may start mid-session) and refreshes its metadata.
    private func upsertSession(for event: HookEvent, at t: Date) -> Int {
        let i: Int
        if let existing = sessions.firstIndex(where: { $0.id == event.sessionID }) {
            i = existing
        } else {
            let name = event.cwd.isEmpty ? "session" : (event.cwd as NSString).lastPathComponent
            sessions.append(Session(id: event.sessionID, cwd: event.cwd, name: name,
                                    branch: GitInfo.branch(cwd: event.cwd), lastEventAt: t))
            i = sessions.count - 1
        }
        // Subagent events carry the subagent's cwd; keep the session's own.
        if event.agentID == nil, !event.cwd.isEmpty, sessions[i].cwd != event.cwd {
            sessions[i].cwd = event.cwd
            sessions[i].name = (event.cwd as NSString).lastPathComponent
            sessions[i].branch = GitInfo.branch(cwd: event.cwd)
        }
        if let title = event.sessionTitle { sessions[i].title = title }
        // A resumed session can come back in a new Claude Code process: always follow the latest one.
        if let ppid = event.hookParentPID, let process = processResolver(ppid) {
            sessions[i].process = process
        }
        sessions[i].lastEventAt = t
        return i
    }

    // MARK: Pruning

    /// Sessions with no known process are dropped after this much silence (old hook scripts, demo mode).
    public nonisolated static let unknownProcessStaleAfter: TimeInterval = 30 * 60
    /// A finished or idle session is hidden after this much silence even when its process still runs:
    /// the Claude desktop app keeps a process alive for every open session. Its next event brings it back.
    public nonisolated static let idleStaleAfter: TimeInterval = 2 * 60

    /// Removes sessions whose Claude Code process has exited (closed terminal, quit app, crash), which
    /// never send `SessionEnd`; finished or idle sessions silent for `idleStaleAfter`; and sessions with
    /// no known process silent for `unknownProcessStaleAfter`. A session waiting on the user is kept
    /// while its process lives. Held requests of removed sessions end with no decision.
    public func pruneEndedSessions(isAlive: (ProcessIdentity) -> Bool = ProcessLiveness.isAlive) {
        let t = now()
        let ended = sessions.filter { s in
            if let p = s.process, !isAlive(p) { return true }
            if hasPending(sessionID: s.id) { return false }
            let silence = t.timeIntervalSince(s.lastEventAt)
            if (s.status == .done || s.status == .idle), silence > Self.idleStaleAfter { return true }
            return s.process == nil && silence > Self.unknownProcessStaleAfter
        }.map(\.id)
        guard !ended.isEmpty else { return }
        for id in ended {
            cancelPending(sessionID: id)
            if selectedSessionID == id { selectedSessionID = nil }
        }
        sessions.removeAll { ended.contains($0.id) }
    }
}

extension SessionStore {
    /// The glue between `HookServer` and the store: `HookServer(port:handler: store.hookHandler())`.
    public nonisolated func hookHandler(permissionTimeout: TimeInterval = SessionStore.defaultPermissionTimeout) -> HookServer.Handler {
        { [weak self] event in
            guard let self else { return .noDecision }
            if event.eventName == .permissionRequest {
                if let decision = await self.requestDecision(for: event, timeout: permissionTimeout) {
                    return .decision(decision)
                }
                return .noDecision
            }
            await self.ingest(event)
            return .ack
        }
    }
}

/// Reads the current branch without spawning git. Handles worktrees (`.git` file with `gitdir:`).
enum GitInfo {
    static func branch(cwd: String) -> String? {
        guard !cwd.isEmpty else { return nil }
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: cwd)
        for _ in 0..<12 {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                var gitDir = dotGit
                if !isDir.boolValue {
                    guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") })
                    else { return nil }
                    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = path.hasPrefix("/") ? URL(fileURLWithPath: path) : dir.appendingPathComponent(path)
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
                let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
                let prefix = "ref: refs/heads/"
                return trimmed.hasPrefix(prefix) ? String(trimmed.dropFirst(prefix.count)) : String(trimmed.prefix(7))
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
        return nil
    }
}
