// OWNER: workstream B (bridge). Scaffold smoke tests for the store's contract; extend freely.
import Foundation
import Testing
import NodCore

@MainActor
@Suite struct SessionStoreSmokeTests {
    @Test func progressEventsBuildASession() throws {
        let store = SessionStore()
        store.ingest(try BridgeFixture.event("session-start"))
        store.ingest(try BridgeFixture.event("user-prompt-submit"))
        store.ingest(try BridgeFixture.event("pre-tool-use-read"))
        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].status == .working)
        #expect(store.sessions[0].lastPrompt == "add token refresh to auth")
        #expect(store.sessions[0].currentTool?.toolName == "Read")
        store.ingest(try BridgeFixture.event("post-tool-use-read"))
        #expect(store.sessions[0].steps.count == 1)
        #expect(store.sessions[0].currentTool == nil)
        store.ingest(try BridgeFixture.event("stop"))
        #expect(store.sessions[0].status == .done)
        #expect(store.toast?.kind == .done)
        store.ingest(try BridgeFixture.event("session-end"))
        #expect(store.sessions.isEmpty)
    }

    @Test func permissionRequestWaitsForTheUser() async throws {
        let store = SessionStore()
        let event = try BridgeFixture.event("permission-request-bash-npm-test")
        async let answer = store.requestDecision(for: event, timeout: 5)
        while store.pending.isEmpty { await Task.yield() }
        #expect(store.sessions[0].status == .needsYou)
        store.resolve(store.pending[0].id, .allow)
        #expect(await answer == .allow)
        #expect(store.pending.isEmpty)
        #expect(store.toast?.kind == .allowed)
    }

    @Test func timeoutGivesNoDecision() async throws {
        let store = SessionStore()
        let answer = await store.requestDecision(for: try BridgeFixture.event("permission-request-edit"), timeout: 0.05)
        #expect(answer == nil)
        #expect(store.pending.isEmpty)
    }

    @Test func passThroughToolsAreNeverHeld() async throws {
        let store = SessionStore()
        let answer = await store.requestDecision(for: try BridgeFixture.event("permission-request-ask-user-question"), timeout: 5)
        #expect(answer == nil)
        #expect(store.pending.isEmpty)
    }

    @Test func aUserRuleIsTheOnlyAutoAllow() async throws {
        let rules = RulesStore(fileURL: nil)
        let store = SessionStore(rules: rules)
        let event = try BridgeFixture.event("permission-request-bash-npm-test")
        async let first = store.requestDecision(for: event, timeout: 5)
        while store.pending.isEmpty { await Task.yield() }
        #expect(store.pending[0].ruleSuggestion != nil)
        store.resolve(store.pending[0].id, .allow, remember: true)
        #expect(await first == .allow)
        #expect(rules.rules.count == 1)
        let second = await store.requestDecision(for: event, timeout: 5)
        #expect(second == .allow)
        #expect(store.autoAllowedCount == 1)
        #expect(store.pending.isEmpty)
    }
}
