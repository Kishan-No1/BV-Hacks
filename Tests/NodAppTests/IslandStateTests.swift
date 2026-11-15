// OWNER: workstream C (app-ui).
import Foundation
import Testing
@testable import Nod
import NodCore

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func session(_ id: String, _ status: SessionStatus) -> Session {
    Session(id: id, cwd: "/tmp/\(id)", name: id, status: status, lastEventAt: t0)
}

private func request(_ level: RiskLevel, session: String = "a") -> PendingRequest {
    PendingRequest(sessionID: session, toolName: "Bash", toolInput: ["command": "npm test"], cwd: "/tmp/a",
                   assessment: Assessment(level: level, title: "Run `npm test`", command: "npm test"),
                   receivedAt: t0)
}

@Suite("IslandState derivation")
struct IslandStateTests {
    @Test func emptyStoreIsIdle() {
        #expect(IslandState.derive(sessions: [], currentRequest: nil, visibleToast: nil, isHovering: false) == .idle)
    }

    @Test func idleAndDoneSessionsAreIdle() {
        let s = [session("a", .idle), session("b", .done)]
        #expect(IslandState.derive(sessions: s, currentRequest: nil, visibleToast: nil, isHovering: false) == .idle)
    }

    @Test func anyWorkingSessionIsWorking() {
        let s = [session("a", .done), session("b", .working)]
        #expect(IslandState.derive(sessions: s, currentRequest: nil, visibleToast: nil, isHovering: false) == .working)
    }

    @Test func needsYouWithoutRequestIsAttentionAndBeatsWorking() {
        let s = [session("a", .working), session("b", .needsYou)]
        #expect(IslandState.derive(sessions: s, currentRequest: nil, visibleToast: nil, isHovering: false) == .attention)
    }

    @Test func hoverOpensProgressOnlyWhenThereAreSessions() {
        #expect(IslandState.derive(sessions: [], currentRequest: nil, visibleToast: nil, isHovering: true) == .idle)
        let s = [session("a", .working)]
        #expect(IslandState.derive(sessions: s, currentRequest: nil, visibleToast: nil, isHovering: true) == .progress)
        // A finished session can still be inspected.
        let done = [session("a", .done)]
        #expect(IslandState.derive(sessions: done, currentRequest: nil, visibleToast: nil, isHovering: true) == .progress)
    }

    @Test func forcedProgressActsLikeHover() {
        let s = [session("a", .working)]
        #expect(IslandState.derive(sessions: s, currentRequest: nil, visibleToast: nil, isHovering: false, forceProgress: true) == .progress)
    }

    @Test func progressBeatsAttention() {
        let s = [session("a", .needsYou)]
        #expect(IslandState.derive(sessions: s, currentRequest: nil, visibleToast: nil, isHovering: true) == .progress)
    }

    @Test func toastBeatsProgressAndWorking() {
        let s = [session("a", .working)]
        #expect(IslandState.derive(sessions: s, currentRequest: nil, visibleToast: .done, isHovering: true) == .toast(.done))
        #expect(IslandState.derive(sessions: s, currentRequest: nil, visibleToast: .denied, isHovering: false) == .toast(.denied))
    }

    @Test func requestBeatsEverything() {
        let r = request(.high)
        let s = [session("a", .needsYou)]
        #expect(IslandState.derive(sessions: s, currentRequest: r, visibleToast: .allowed, isHovering: true, forceProgress: true) == .request(r))
    }

    @Test func expandedStatesAndRisk() {
        #expect(IslandState.progress.isExpanded)
        #expect(IslandState.request(request(.low)).isExpanded)
        #expect(!IslandState.working.isExpanded)
        #expect(!IslandState.toast(.done).isExpanded)
        #expect(IslandState.request(request(.high)).glowRisk == .high)
        #expect(IslandState.request(request(.review)).glowRisk == .review)
        #expect(IslandState.request(request(.low)).glowRisk == nil)
        #expect(IslandState.progress.glowRisk == nil)
        #expect(IslandState.progress.glassOverContent)
        #expect(!IslandState.request(request(.low)).glassOverContent)
    }

    @Test func identityChangesWithTheRequest() {
        let a = request(.low), b = request(.low)
        #expect(IslandState.request(a).identity != IslandState.request(b).identity)
        #expect(IslandState.toast(.done).identity != IslandState.toast(.allowed).identity)
        #expect(IslandState.idle.identity == "idle")
    }

    @Test func logNamesAreReadable() {
        #expect(IslandState.working.logName == "working")
        #expect(IslandState.toast(.autoAllowed).logName == "toast(autoAllowed)")
        #expect(IslandState.request(request(.high)).logName.hasPrefix("request(high)"))
    }

    @MainActor @Test func derivesFromARealStore() async {
        let store = SessionStore()
        #expect(IslandState.derive(store: store, visibleToast: nil, isHovering: false) == .idle)
        var e = HookEvent(sessionID: "s1", eventName: .userPromptSubmit, cwd: "/tmp/x")
        e.prompt = "add token refresh to auth"
        store.ingest(e)
        #expect(IslandState.derive(store: store, visibleToast: nil, isHovering: false) == .working)
        #expect(IslandState.derive(store: store, visibleToast: nil, isHovering: true) == .progress)
    }
}

@Suite("Toast timing")
struct ToastClockTests {
    private func toast(_ kind: Toast.Kind) -> Toast { Toast(kind: kind, sessionID: "a", at: t0) }

    @Test func aNewToastShowsForAboutOnePointOneSeconds() {
        var clock = ToastClock()
        let done = toast(.done)
        let shown1 = clock.observe(done, now: t0)
        #expect(shown1)
        #expect(clock.visibleKind(at: t0) == .done)
        #expect(clock.visibleKind(at: t0.addingTimeInterval(1.0)) == .done)
        #expect(clock.visibleKind(at: t0.addingTimeInterval(1.1)) == nil)
        #expect(ToastClock.duration == 1.1)
    }

    @Test func theSameToastIsShownOnlyOnce() {
        var clock = ToastClock()
        let done = toast(.done)
        let shown2 = clock.observe(done, now: t0)
        #expect(shown2)
        let shown3 = clock.observe(done, now: t0.addingTimeInterval(2))
        #expect(!shown3)
        #expect(clock.visibleKind(at: t0.addingTimeInterval(2)) == nil)
    }

    @Test func aNewerToastReplacesTheCurrentOne() {
        var clock = ToastClock()
        let shown4 = clock.observe(toast(.allowed), now: t0)
        #expect(shown4)
        let shown5 = clock.observe(toast(.denied), now: t0.addingTimeInterval(0.5))
        #expect(shown5)
        #expect(clock.visibleKind(at: t0.addingTimeInterval(1.2)) == .denied)
        #expect(clock.visibleKind(at: t0.addingTimeInterval(1.6)) == nil)
    }

    @Test func nilToastShowsNothing() {
        var clock = ToastClock()
        let shown6 = clock.observe(nil, now: t0)
        #expect(!shown6)
        #expect(clock.visibleKind(at: t0) == nil)
    }

    @Test func markSeenSuppressesAToastThatAlreadyExisted() {
        var clock = ToastClock()
        let stale = toast(.done)
        clock.markSeen(stale)
        let shown7 = clock.observe(stale, now: t0)
        #expect(!shown7)
        #expect(clock.visibleKind(at: t0) == nil)
    }

    @Test func expireClearsTheVisibleToast() {
        var clock = ToastClock()
        _ = clock.observe(toast(.allowed), now: t0)
        clock.expire(now: t0.addingTimeInterval(0.5))
        #expect(clock.visible?.kind == .allowed)
        clock.expire(now: t0.addingTimeInterval(1.2))
        #expect(clock.visible == nil)
    }
}
