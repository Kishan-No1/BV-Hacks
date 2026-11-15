// OWNER: workstream B (bridge). Pins SessionStore behavior. Never asserts RiskEngine/StepFormatter/RulesStore
// strings or levels (workstream A owns them); asserts structure: counts, statuses, ids, order.
import Foundation
import Testing
import NodCore

/// Injectable clock for `SessionStore(now:)`.
final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval = 1) { now = now.addingTimeInterval(seconds) }
}

@MainActor
private func event(_ name: String, session: String? = nil, tool: String? = nil) throws -> HookEvent {
    var e = try BridgeFixture.event(name)
    if let session { e.sessionID = session }
    if let tool { e.toolName = tool }
    return e
}

/// Starts `requestDecision` in a task and waits until the request is queued.
@MainActor
private func hold(_ store: SessionStore, _ e: HookEvent, timeout: TimeInterval = 30) async -> Task<Decision?, Never> {
    let before = store.pending.count
    let task = Task { @MainActor in await store.requestDecision(for: e, timeout: timeout) }
    _ = await eventually { store.pending.count > before }
    return task
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SessionStoreTests {
    // MARK: Queue

    @Test func pendingIsFIFOAcrossSessions() async throws {
        let clock = TestClock()
        let store = SessionStore(now: { clock.now })
        let a1 = await hold(store, try event("permission-request-bash-npm-test", session: "A"))
        clock.advance()
        let b1 = await hold(store, try event("permission-request-edit", session: "B"))
        clock.advance()
        let a2 = await hold(store, try event("permission-request-webfetch", session: "A"))

        #expect(store.pending.map(\.sessionID) == ["A", "B", "A"])
        #expect(store.pending.map(\.toolName) == ["Bash", "Edit", "WebFetch"])
        #expect(store.pending.map(\.receivedAt) == store.pending.map(\.receivedAt).sorted())
        #expect(store.currentRequest?.id == store.pending[0].id)

        store.resolve(store.pending[0].id, .allow)
        #expect(await a1.value == .allow)
        #expect(store.currentRequest?.sessionID == "B")
        // A still has a request, so it keeps needing the user.
        #expect(store.session(id: "A")?.status == .needsYou)

        store.resolve(store.pending[0].id, .deny(message: nil))
        #expect(await b1.value == .deny(message: nil))
        #expect(store.currentRequest?.toolName == "WebFetch")

        store.resolve(store.pending[0].id, .allow)
        #expect(await a2.value == .allow)
        #expect(store.pending.isEmpty)
        #expect(store.currentRequest == nil)
    }

    @Test func timeoutReturnsNilAndRemovesTheRequest() async throws {
        let store = SessionStore()
        let answer = await store.requestDecision(for: try event("permission-request-bash-npm-test"), timeout: 0.05)
        #expect(answer == nil)
        #expect(store.pending.isEmpty)
        // Claude Code now shows its own prompt, so the session still needs the user.
        #expect(store.sessions.first?.status == .needsYou)
    }

    @Test(arguments: [-1.0, 0.0, Double.nan, Double.infinity, 1e300])
    func oddTimeoutsNeverCrash(_ timeout: Double) async throws {
        let store = SessionStore()
        let e = try event("permission-request-edit")
        var finished = false
        let task = Task { @MainActor in
            let answer = await store.requestDecision(for: e, timeout: timeout)
            finished = true
            return answer
        }
        #expect(await eventually { finished || !store.pending.isEmpty })
        if let queued = store.pending.first { store.resolve(queued.id, .allow) }
        let answer = await task.value
        #expect(answer == nil || answer == .allow)
        #expect(store.pending.isEmpty)
    }

    @Test func cancellingTheAwaitingTaskRemovesTheRequestAndReturnsNil() async throws {
        let store = SessionStore()
        let task = await hold(store, try event("permission-request-bash-npm-test"))
        #expect(store.pending.count == 1)
        task.cancel()
        #expect(await task.value == nil)
        #expect(await eventually { store.pending.isEmpty })
        #expect(store.sessions.first?.status == .working)
    }

    @Test func anAlreadyCancelledTaskNeverLeavesARequestBehind() async throws {
        let store = SessionStore()
        let e = try event("permission-request-edit")
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await store.requestDecision(for: e, timeout: 30)
        }
        #expect(await task.value == nil)
        #expect(await eventually { store.pending.isEmpty })
    }

    @Test func resolvingAfterTheTaskWasCancelledIsANoOp() async throws {
        let store = SessionStore()
        let task = await hold(store, try event("permission-request-bash-npm-test"))
        let id = store.pending[0].id
        task.cancel()
        #expect(await task.value == nil)
        _ = await eventually { store.pending.isEmpty }
        store.resolve(id, .allow)
        #expect(store.toast == nil)
    }

    @Test func postToolUseForTheSameCallClearsAHeldRequest() async throws {
        let store = SessionStore()
        let held = await hold(store, try event("permission-request-bash-npm-test"))

        store.ingest(try event("post-tool-use-read"))  // a different call: still held
        #expect(store.pending.count == 1)

        store.ingest(try event("post-tool-use-bash"))  // same tool_name + tool_input: answered in the terminal
        #expect(await held.value == nil)
        #expect(store.pending.isEmpty)
        #expect(store.sessions[0].status == .working)
        #expect(store.sessions[0].steps.count == 2)
    }

    @Test(arguments: ["stop", "user-prompt-submit", "session-end"])
    func turnBoundariesClearThatSessionsHeldRequests(_ boundary: String) async throws {
        let store = SessionStore()
        let mine = await hold(store, try event("permission-request-bash-npm-test"))
        let mine2 = await hold(store, try event("permission-request-edit"))
        let other = await hold(store, try event("permission-request-webfetch", session: "other"))
        #expect(store.pending.count == 3)

        store.ingest(try event(boundary))
        #expect(await mine.value == nil)
        #expect(await mine2.value == nil)
        #expect(store.pending.map(\.sessionID) == ["other"])
        #expect(store.session(id: "other")?.status == .needsYou)

        store.resolve(store.pending[0].id, .allow)
        #expect(await other.value == .allow)
    }

    @Test func dismissGivesNoDecisionAndTheSessionStillNeedsTheUser() async throws {
        let store = SessionStore()
        let held = await hold(store, try event("permission-request-edit"))
        store.dismiss(store.pending[0].id)
        #expect(await held.value == nil)
        #expect(store.pending.isEmpty)
        #expect(store.sessions[0].status == .needsYou)
    }

    @Test func aDenyClearsTheToolCardBecauseNoPostToolUseFollows() async throws {
        let store = SessionStore()
        store.ingest(try event("user-prompt-submit"))
        store.ingest(try event("pre-tool-use-bash"))
        #expect(store.sessions[0].currentTool?.toolName == "Bash")
        let held = await hold(store, try event("permission-request-bash-npm-test"))
        store.resolve(store.pending[0].id, .deny(message: nil))
        #expect(await held.value == .deny(message: nil))
        #expect(store.sessions[0].currentTool == nil)
        #expect(store.sessions[0].currentStep == nil)
        #expect(store.sessions[0].status == .working)
    }

    @Test func anAllowKeepsTheToolCardUntilPostToolUse() async throws {
        let store = SessionStore()
        store.ingest(try event("pre-tool-use-bash"))
        let held = await hold(store, try event("permission-request-bash-npm-test"))
        store.resolve(store.pending[0].id, .allow)
        _ = await held.value
        #expect(store.sessions[0].currentTool?.toolName == "Bash")
        store.ingest(try event("post-tool-use-bash"))
        #expect(store.sessions[0].currentTool == nil)
    }

    @Test func denyCarriesItsMessage() async throws {
        let store = SessionStore()
        let held = await hold(store, try event("permission-request-bash-rm-rf-outside"))
        store.resolve(store.pending[0].id, .deny(message: "Not outside the repo"))
        #expect(await held.value == .deny(message: "Not outside the repo"))
    }

    @Test func unknownIDsAreIgnored() async throws {
        let store = SessionStore()
        store.resolve(UUID(), .allow)
        store.dismiss(UUID())
        #expect(store.toast == nil)
        #expect(store.pending.isEmpty)
    }

    @Test func ingestNeverQueuesAPermissionRequest() throws {
        let store = SessionStore()
        store.ingest(try event("permission-request-bash-npm-test"))
        #expect(store.pending.isEmpty)
    }

    @Test func requestDecisionForANonPermissionEventIngestsIt() async throws {
        let store = SessionStore()
        let answer = await store.requestDecision(for: try event("user-prompt-submit"), timeout: 5)
        #expect(answer == nil)
        #expect(store.sessions.first?.status == .working)
        #expect(store.pending.isEmpty)
    }

    // MARK: Rules

    @Test func aRuleNeverAutoAllowsAHighRiskCall() async throws {
        let rules = RulesStore(fileURL: nil)
        rules.add(Rule(repo: BridgeFixture.repo, tool: "Bash"))  // tool-wide: matches any Bash call here
        let store = SessionStore(rules: rules)
        let e = try event("permission-request-bash-rm-rf-outside")
        let level = RiskEngine().assess(toolName: "Bash", toolInput: e.toolInput ?? [:], cwd: e.cwd).level

        let task = Task { @MainActor in await store.requestDecision(for: e, timeout: 30) }
        // Either it is queued (high, or no rule match) or a rule answered it at once.
        #expect(await eventually { !store.pending.isEmpty || store.autoAllowedCount > 0 })
        if let queued = store.pending.first, queued.assessment.level == .high {
            #expect(store.pending.count == 1, "a high-risk call must wait for the user even when a rule matches")
            #expect(store.autoAllowedCount == 0)
            #expect(rules.rules.allSatisfy { $0.hitCount == 0 })
            store.resolve(queued.id, .deny(message: nil))
            #expect(await task.value == .deny(message: nil))
        } else {
            // The engine does not call it high (yet): only then may the rule auto-allow.
            #expect(level != .high)
            if let queued = store.pending.first { store.resolve(queued.id, .deny(message: nil)) }
            let answer = await task.value
            #expect(answer == .allow || answer == .deny(message: nil))
        }
    }

    @Test func rememberStoresTheRuleAndTheNextIdenticalRequestIsAutoAllowed() async throws {
        let rules = RulesStore(fileURL: nil)
        let store = SessionStore(rules: rules)
        let e = try event("permission-request-bash-npm-test")
        let first = await hold(store, e)
        try #require(store.pending[0].ruleSuggestion != nil)
        store.resolve(store.pending[0].id, .allow, remember: true)
        #expect(await first.value == .allow)
        #expect(rules.rules.count == 1)
        #expect(rules.rules.first?.tool == "Bash")
        #expect(store.autoAllowedCount == 0)

        let second = await store.requestDecision(for: e, timeout: 5)
        #expect(second == .allow)
        #expect(store.pending.isEmpty)
        #expect(store.autoAllowedCount == 1)
        #expect(store.toast?.kind == .autoAllowed)
        #expect(rules.rules.first?.hitCount == 1)

        _ = await store.requestDecision(for: e, timeout: 5)
        #expect(store.autoAllowedCount == 2)
    }

    @Test func rememberWithDenyStoresNothing() async throws {
        let rules = RulesStore(fileURL: nil)
        let store = SessionStore(rules: rules)
        let held = await hold(store, try event("permission-request-bash-npm-test"))
        store.resolve(store.pending[0].id, .deny(message: nil), remember: true)
        #expect(await held.value == .deny(message: nil))
        #expect(rules.rules.isEmpty)
    }

    @Test func withoutARulesStoreNothingIsSuggestedOrRemembered() async throws {
        let store = SessionStore()
        let held = await hold(store, try event("permission-request-bash-npm-test"))
        #expect(store.pending[0].ruleSuggestion == nil)
        store.resolve(store.pending[0].id, .allow, remember: true)
        #expect(await held.value == .allow)
        #expect(await store.requestDecision(for: try event("permission-request-bash-npm-test"), timeout: 0.05) == nil)
    }

    // MARK: Pass-through tools

    @Test(arguments: ["AskUserQuestion", "ExitPlanMode"])
    func passThroughToolsReturnNilAtOnceAndNeedTheUser(_ tool: String) async throws {
        let rules = RulesStore(fileURL: nil)
        rules.add(Rule(repo: BridgeFixture.repo, tool: tool))
        let store = SessionStore(rules: rules)
        let e = try event("permission-request-ask-user-question", tool: tool)
        let started = ContinuousClock.now
        let answer = await store.requestDecision(for: e, timeout: 30)
        #expect(answer == nil)
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(store.pending.isEmpty)
        #expect(store.autoAllowedCount == 0)
        #expect(store.sessions.first?.status == .needsYou)
        #expect(SessionStore.passThroughTools.contains(tool))
    }

    // MARK: Sessions

    @Test func eventsForUnknownSessionIDsCreateSessions() async throws {
        let store = SessionStore()
        store.ingest(try event("pre-tool-use-bash", session: "s1"))
        store.ingest(try event("notification-permission-prompt", session: "s2"))
        store.ingest(try event("stop", session: "s3"))
        let held = await hold(store, try event("permission-request-edit", session: "s4"))

        #expect(store.sessions.map(\.id) == ["s1", "s2", "s3", "s4"])
        #expect(store.sessions.allSatisfy { $0.cwd == BridgeFixture.repo && $0.name == "acme-web" })
        #expect(store.session(id: "s1")?.status == .working)
        #expect(store.session(id: "s2")?.status == .needsYou)
        #expect(store.session(id: "s3")?.status == .done)
        #expect(store.session(id: "s4")?.status == .needsYou)
        #expect(store.session(id: "nope") == nil)
        held.cancel()
        _ = await held.value
    }

    @Test func statusGoesIdleWorkingNeedsYouWorkingDone() async throws {
        let store = SessionStore()
        store.ingest(try event("session-start"))
        #expect(store.sessions[0].status == .idle)
        #expect(!store.isAnyWorking)

        store.ingest(try event("user-prompt-submit"))
        #expect(store.sessions[0].status == .working)
        #expect(store.isAnyWorking)
        #expect(store.sessions[0].turnStartedAt != nil)

        store.ingest(try event("pre-tool-use-bash"))
        let held = await hold(store, try event("permission-request-bash-npm-test"))
        #expect(store.sessions[0].status == .needsYou)
        #expect(!store.isAnyWorking)

        store.resolve(store.pending[0].id, .allow)
        #expect(await held.value == .allow)
        #expect(store.sessions[0].status == .working)

        store.ingest(try event("post-tool-use-bash"))
        #expect(store.sessions[0].status == .working)
        #expect(store.sessions[0].currentTool == nil)

        store.ingest(try event("stop"))
        #expect(store.sessions[0].status == .done)
        #expect(store.sessions[0].turnEndedAt != nil)
        #expect(store.sessions[0].currentStep == nil)

        // A new SessionStart (resume/clear) on a finished session goes back to idle.
        store.ingest(try event("session-start"))
        #expect(store.sessions[0].status == .idle)
    }

    @Test func aPreToolUseDoesNotHideAPendingRequest() async throws {
        let store = SessionStore()
        let held = await hold(store, try event("permission-request-bash-npm-test"))
        store.ingest(try event("pre-tool-use-read"))
        store.ingest(try event("post-tool-use-read"))
        #expect(store.sessions[0].status == .needsYou)
        held.cancel()
        _ = await held.value
    }

    @Test func userPromptSubmitStartsAFreshTurn() throws {
        let store = SessionStore()
        store.ingest(try event("user-prompt-submit"))
        store.ingest(try event("post-tool-use-read"))
        store.ingest(try event("post-tool-use-edit"))
        #expect(store.sessions[0].steps.count == 2)
        #expect(store.sessions[0].editedFiles.count == 1)
        store.ingest(try event("stop"))
        store.ingest(try event("user-prompt-submit"))
        #expect(store.sessions[0].steps.isEmpty)
        #expect(store.sessions[0].editedFiles.isEmpty)
        #expect(store.sessions[0].turnEndedAt == nil)
        #expect(store.sessions[0].lastPrompt != nil)
    }

    @Test func failedToolsAreMarkedFailed() throws {
        let store = SessionStore()
        store.ingest(try event("pre-tool-use-bash"))
        store.ingest(try event("post-tool-use-failure-bash"))
        #expect(store.sessions[0].steps.count == 1)
        #expect(store.sessions[0].steps[0].failed)
        #expect(store.sessions[0].currentTool == nil)
    }

    @Test func theStepListCapsAt200KeepingTheNewest() throws {
        let clock = TestClock()
        let store = SessionStore(now: { clock.now })
        store.ingest(try event("user-prompt-submit"))
        let read = try event("post-tool-use-read")
        var times: [Date] = []
        for _ in 0..<250 {
            clock.advance()
            times.append(clock.now)
            store.ingest(read)
        }
        #expect(SessionStore.maxSteps == 200)
        #expect(store.sessions[0].steps.count == 200)
        #expect(store.sessions[0].steps.first?.at == times[50])
        #expect(store.sessions[0].steps.last?.at == times[249])
    }

    @Test func sessionEndRemovesTheSessionAndItsSelection() throws {
        let store = SessionStore()
        store.ingest(try event("session-start"))
        store.selectedSessionID = BridgeFixture.sessionID
        store.ingest(try event("session-end"))
        #expect(store.sessions.isEmpty)
        #expect(store.selectedSessionID == nil)
        #expect(store.activeSession == nil)
    }

    @Test func subagentEventsKeepTheSessionsOwnCwd() throws {
        let store = SessionStore()
        store.ingest(try event("session-start"))
        var sub = try event("pre-tool-use-read")
        sub.agentID = "agent-1"
        sub.cwd = "/tmp/elsewhere"
        store.ingest(sub)
        #expect(store.sessions[0].cwd == BridgeFixture.repo)
        var moved = try event("pre-tool-use-read")
        moved.cwd = "/Users/dev/code/other-repo"
        store.ingest(moved)
        #expect(store.sessions[0].name == "other-repo")
    }

    // MARK: Toasts

    @Test func toastKindsForDoneAllowedDeniedAndAutoAllowed() async throws {
        let rules = RulesStore(fileURL: nil)
        let clock = TestClock()
        let store = SessionStore(rules: rules, now: { clock.now })
        #expect(store.toast == nil)

        store.ingest(try event("stop"))
        #expect(store.toast?.kind == .done)
        #expect(store.toast?.sessionID == BridgeFixture.sessionID)
        let doneID = store.toast?.id

        let a = await hold(store, try event("permission-request-bash-npm-test"))
        clock.advance()
        store.resolve(store.pending[0].id, .allow, remember: true)
        _ = await a.value
        #expect(store.toast?.kind == .allowed)
        #expect(store.toast?.at == clock.now)
        #expect(store.toast?.id != doneID)

        let d = await hold(store, try event("permission-request-edit"))
        store.resolve(store.pending[0].id, .deny(message: nil))
        _ = await d.value
        #expect(store.toast?.kind == .denied)

        if !rules.rules.isEmpty {
            _ = await store.requestDecision(for: try event("permission-request-bash-npm-test"), timeout: 5)
            #expect(store.toast?.kind == .autoAllowed)
        }
    }

    @Test func timeoutsAndDismissalsShowNoToast() async throws {
        let store = SessionStore()
        _ = await store.requestDecision(for: try event("permission-request-edit"), timeout: 0.02)
        #expect(store.toast == nil)
        let held = await hold(store, try event("permission-request-edit"))
        store.dismiss(store.pending[0].id)
        _ = await held.value
        #expect(store.toast == nil)
    }

    // MARK: activeSession

    @Test func activeSessionPrefersSelectionThenRequestThenRecentWorkingThenRecent() async throws {
        let clock = TestClock()
        let store = SessionStore(now: { clock.now })
        #expect(store.activeSession == nil)

        store.ingest(try event("user-prompt-submit", session: "W"))   // working, oldest
        clock.advance()
        store.ingest(try event("stop", session: "D"))                 // done, newer
        #expect(store.activeSession?.id == "W", "the most recent WORKING session beats a newer finished one")

        store.ingest(try event("stop", session: "W"))
        #expect(store.activeSession?.id == "W", "nothing working: the most recent session")
        clock.advance()
        store.ingest(try event("session-start", session: "D"))
        #expect(store.activeSession?.id == "D")

        clock.advance()
        let held = await hold(store, try event("permission-request-edit", session: "R"))
        clock.advance()
        store.ingest(try event("user-prompt-submit", session: "W"))
        #expect(store.activeSession?.id == "R", "the session with the current request beats recency")

        store.selectedSessionID = "D"
        #expect(store.activeSession?.id == "D", "an explicit selection wins")
        store.selectedSessionID = "gone"
        #expect(store.activeSession?.id == "R", "a stale selection falls back to automatic")

        store.selectedSessionID = nil
        store.resolve(store.pending[0].id, .allow)
        _ = await held.value
        #expect(store.activeSession?.id == "W")
    }
}

// MARK: - End to end: HookServer + SessionStore over a real socket

@MainActor
@Suite(.timeLimit(.minutes(1))) struct BridgeEndToEndTests {
    @Test func aPermissionRequestPostedOverHTTPIsAnsweredFromTheStore() async throws {
        let store = SessionStore()
        let server = HookServer(port: 0, handler: store.hookHandler(permissionTimeout: 5))
        let port = try await server.start()
        defer { server.stop() }

        let body = try BridgeFixture.data("permission-request-bash-npm-test")
        let call = Task { try await HTTPClient.post(port: port, event: "PermissionRequest", body: body) }
        #expect(await eventually { !store.pending.isEmpty })
        #expect(store.pending[0].toolName == "Bash")
        #expect(store.sessions.first?.status == .needsYou)

        store.resolve(store.pending[0].id, .allow)
        let reply = try await call.value
        #expect(reply.status == 200)
        #expect(reply.body == HookOutput.permissionRequest(.allow))
        #expect(store.pending.isEmpty)
    }

    @Test func aDenyFromTheStoreReachesTheClient() async throws {
        let store = SessionStore()
        let server = HookServer(port: 0, handler: store.hookHandler(permissionTimeout: 5))
        let port = try await server.start()
        defer { server.stop() }
        let call = Task { try await HTTPClient.post(port: port, event: "PermissionRequest",
                                                     body: try BridgeFixture.data("permission-request-write-env")) }
        #expect(await eventually { !store.pending.isEmpty })
        store.resolve(store.pending[0].id, .deny(message: nil))
        let reply = try await call.value
        #expect(reply.body == HookOutput.permissionRequest(.deny(message: nil)))
    }

    @Test func progressEventsAreAcknowledgedAndReduced() async throws {
        let store = SessionStore()
        let server = HookServer(port: 0, handler: store.hookHandler(permissionTimeout: 5))
        let port = try await server.start()
        defer { server.stop() }
        for name in ["session-start", "user-prompt-submit", "pre-tool-use-read"] {
            let reply = try await HTTPClient.post(port: port, event: "x", body: try BridgeFixture.data(name))
            #expect(reply.status == 200)
            #expect(reply.bodyString == #"{"ok":true}"#)
        }
        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].status == .working)
        #expect(store.sessions[0].currentTool?.toolName == "Read")
    }

    @Test func aStoreTimeoutAnswers204() async throws {
        let store = SessionStore()
        let server = HookServer(port: 0, handler: store.hookHandler(permissionTimeout: 0.2))
        let port = try await server.start()
        defer { server.stop() }
        let reply = try await HTTPClient.post(port: port, event: "PermissionRequest",
                                              body: try BridgeFixture.data("permission-request-edit"))
        #expect(reply.status == 204)
        #expect(reply.body.isEmpty)
        #expect(store.pending.isEmpty)
    }

    @Test func passThroughToolsAnswer204Immediately() async throws {
        let store = SessionStore()
        let server = HookServer(port: 0, handler: store.hookHandler(permissionTimeout: 30))
        let port = try await server.start()
        defer { server.stop() }
        let reply = try await HTTPClient.post(port: port, event: "PermissionRequest",
                                              body: try BridgeFixture.data("permission-request-ask-user-question"))
        #expect(reply.status == 204)
    }

    @Test func aClientDisconnectRemovesTheRequestFromTheStore() async throws {
        let store = SessionStore()
        let server = HookServer(port: 0, handler: store.hookHandler(permissionTimeout: 30))
        let port = try await server.start()
        defer { server.stop() }
        let body = try BridgeFixture.data("permission-request-bash-npm-test")
        let client = RawClient(port: port)
        try await client.connect()
        try await client.send(Data("POST /hook/PermissionRequest HTTP/1.1\r\nHost: x\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body)
        #expect(await eventually { store.pending.count == 1 })
        client.close()
        #expect(await eventually { store.pending.isEmpty })
        #expect(store.sessions.first?.status == .working)
    }

    @Test func stoppingTheServerReleasesHeldRequests() async throws {
        let store = SessionStore()
        let server = HookServer(port: 0, handler: store.hookHandler(permissionTimeout: 30))
        let port = try await server.start()
        let call = Task { try await HTTPClient.post(port: port, event: "PermissionRequest",
                                                     body: try BridgeFixture.data("permission-request-edit")) }
        #expect(await eventually { store.pending.count == 1 })
        server.stop()
        #expect(await eventually { store.pending.isEmpty })
        _ = await call.result
    }
}
