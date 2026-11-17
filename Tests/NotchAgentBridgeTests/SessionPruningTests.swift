import Foundation
import Testing
import NotchAgentCore

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SessionPruningTests {
    private func event(_ name: String, session: String, pid: Int32?) throws -> HookEvent {
        var e = try BridgeFixture.event(name)
        e.sessionID = session
        e.hookParentPID = pid
        return e
    }

    @Test func dropsSessionsWhoseProcessExited() throws {
        let store = SessionStore()
        store.processResolver = { ProcessIdentity(pid: $0, startedAt: 1) }
        store.ingest(try event("user-prompt-submit", session: "A", pid: 100))
        store.ingest(try event("user-prompt-submit", session: "B", pid: 200))
        #expect(store.sessions.map(\.id) == ["A", "B"])
        store.selectedSessionID = "A"

        store.pruneEndedSessions { $0.pid == 200 }
        #expect(store.sessions.map(\.id) == ["B"])
        #expect(store.selectedSessionID == nil)
    }

    @Test func keepsUnknownProcessSessionsUntilStale() throws {
        let clock = TestClock()
        let store = SessionStore(now: { clock.now })
        store.ingest(try event("stop", session: "A", pid: nil))
        store.pruneEndedSessions { _ in false }
        #expect(store.sessions.count == 1)
        clock.advance(SessionStore.unknownProcessStaleAfter + 1)
        store.pruneEndedSessions { _ in false }
        #expect(store.sessions.isEmpty)
    }

    @Test func realProcessLiveness() {
        let me = ProcessLiveness.claudeProcess(fromHookParent: getpid())
        #expect(me?.pid == getpid())
        #expect(me.map(ProcessLiveness.isAlive) == true)
        if let me {
            #expect(!ProcessLiveness.isAlive(ProcessIdentity(pid: me.pid, startedAt: me.startedAt + 1)))
        }
    }
}
