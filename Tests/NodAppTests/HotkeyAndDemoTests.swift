// OWNER: workstream C (app-ui).
import Foundation
import Testing
@testable import Nod
import NodCore

final class FakeRegistrar: HotkeyRegistrar {
    private(set) var isRegistered = false
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    var onPress: ((IslandHotkey) -> Void)?
    func register() { isRegistered = true; registerCount += 1 }
    func unregister() { isRegistered = false; unregisterCount += 1 }
}

/// Spins the main actor until `condition` holds (or ~2 s pass).
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

@MainActor
private func permissionEvent(session: String = "s1", command: String = "npm test") -> HookEvent {
    var e = HookEvent(sessionID: session, eventName: .permissionRequest, cwd: "/tmp/repo")
    e.toolName = "Bash"
    e.toolInput = ["command": .string(command)]
    return e
}

@Suite("Hotkeys are held only while a request is pending")
@MainActor
struct HotkeyGatingTests {
    @Test func registersWhilePendingAndUnregistersWhenEmpty() async {
        let store = SessionStore()
        let fake = FakeRegistrar()
        let controller = HotkeyController(registrar: fake) { !store.pending.isEmpty }
        controller.start()
        #expect(!fake.isRegistered)

        let task = Task { @MainActor in await store.requestDecision(for: permissionEvent(), timeout: 30) }
        #expect(await eventually { fake.isRegistered })
        #expect(fake.registerCount == 1)

        let id = store.pending[0].id
        store.resolve(id, .allow)
        #expect(await eventually { !fake.isRegistered })
        #expect(await task.value == .allow)
        #expect(fake.unregisterCount == 1)
        controller.stop()
    }

    @Test func staysRegisteredAcrossAQueueAndUnregistersAfterTheLast() async {
        let store = SessionStore()
        let fake = FakeRegistrar()
        let controller = HotkeyController(registrar: fake) { !store.pending.isEmpty }
        controller.start()
        let a = Task { @MainActor in await store.requestDecision(for: permissionEvent(session: "s1"), timeout: 30) }
        let b = Task { @MainActor in await store.requestDecision(for: permissionEvent(session: "s2", command: "ls"), timeout: 30) }
        #expect(await eventually { store.pending.count == 2 && fake.isRegistered })
        store.resolve(store.pending[0].id, .deny(message: nil))
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(fake.isRegistered)
        store.resolve(store.pending[0].id, .allow)
        #expect(await eventually { !fake.isRegistered })
        _ = await (a.value, b.value)
        #expect(fake.registerCount == 1)
        controller.stop()
    }

    @Test func stopReleasesTheKeys() async {
        let store = SessionStore()
        let fake = FakeRegistrar()
        let controller = HotkeyController(registrar: fake) { !store.pending.isEmpty }
        controller.start()
        let task = Task { @MainActor in await store.requestDecision(for: permissionEvent(), timeout: 30) }
        #expect(await eventually { fake.isRegistered })
        controller.stop()
        #expect(!fake.isRegistered)
        store.dismiss(store.pending[0].id)
        _ = await task.value
    }
}

@Suite("Demo script")
@MainActor
struct DemoScriptTests {
    @Test func storyFollowsThePrototypeBeats() {
        let names = DemoScript.story().map(\.name)
        #expect(names == ["idle", "working", "progress", "working", "attention", "low", "allowed", "med", "allowed",
                          "working", "high", "denied", "working", "done", "working"])
        let durations = DemoScript.story().map(\.duration)
        #expect(durations == [1.2, 2.0, 3.6, 1.2, 1.1, 2.8, 1.1, 3.0, 1.1, 1.3, 3.6, 1.3, 1.3, 2.2, 1.2])
    }

    @Test func everyPayloadDecodesAsAHookEvent() throws {
        var count = 0
        for action in DemoScript.preroll() + DemoScript.story().flatMap(\.actions) {
            switch action {
            case .ingest(let data, _), .request(let data, _):
                let e = try HookEvent.decode(data)
                #expect(!e.sessionID.isEmpty)
                count += 1
            default: break
            }
        }
        #expect(count > 20)
    }

    @Test func prerollLeavesThreeSessionsWithOnlyTheCISessionDone() {
        let clock = DemoClock(virtualBase: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let store = DemoPlayer.makeStore(clock: clock)
        for action in DemoScript.preroll() {
            if case .ingest(let data, let offset) = action {
                clock.offset = offset
                store.ingest(try! HookEvent.decode(data))
                clock.offset = 0
            }
        }
        // First-seen order matches the prototype's avatars; only the CI session has had a turn yet.
        #expect(store.sessions.map(\.id) == [DemoScript.auth.id, DemoScript.hero.id, DemoScript.ci.id])
        #expect(store.sessions[2].headline == "fix the flaky CI cache")
        #expect(store.sessions.map(\.status) == [.idle, .idle, .done])
        let ci = store.sessions[2]
        #expect(ci.editedFiles.count == 3)
        #expect(Format.finishedSummary(ci) == "3 files changed · 9m 12s")
        #expect(IslandState.derive(store: store, visibleToast: nil, isHovering: false) == .idle)
    }

    @Test func fastForwardRunsTheWholeStoryThroughTheStore() async {
        let clock = DemoClock(virtualBase: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let store = DemoPlayer.makeStore(clock: clock)
        let player = DemoPlayer(store: store, clock: clock, mode: .fastForward)
        var seen: [String: IslandState] = [:]
        await player.run { index, beat in
            seen["\(index):\(beat.name)"] = IslandState.derive(store: store, visibleToast: nil, isHovering: false,
                                                               forceProgress: player.forceProgress)
        }
        #expect(seen["1:working"] == .working)
        #expect(seen["2:progress"] == .progress)
        #expect(seen["4:attention"] == .attention)
        if case .request(let r)? = seen["5:low"] { #expect(r.toolName == "Bash") } else { Issue.record("no low request") }
        if case .request(let r)? = seen["7:med"] { #expect(r.toolName == "Edit"); #expect(r.assessment.diff != nil) } else { Issue.record("no review request") }
        if case .request(let r)? = seen["10:high"] { #expect(r.toolName == "Bash"); #expect(r.sessionID == DemoScript.hero.id) } else { Issue.record("no high request") }
        #expect(store.pending.isEmpty)
        #expect(player.decisions == ["low": .allow, "med": .allow, "high": .deny(message: nil)])
        #expect(store.session(id: DemoScript.auth.id)?.status == .done)
        #expect(store.session(id: DemoScript.hero.id)?.status == .working)
    }
}

@Suite("Island model")
@MainActor
struct IslandModelTests {
    private func prompt(_ id: String) -> HookEvent {
        var e = HookEvent(sessionID: id, eventName: .userPromptSubmit, cwd: "/tmp/\(id)")
        e.prompt = "do the thing"
        return e
    }

    @Test func followsTheStoreAndShowsANewToast() async {
        let store = SessionStore()
        let model = IslandModel(store: store, renderMode: .snapshot(now: Date()))
        model.start()
        #expect(model.displayedState == .idle)
        store.ingest(prompt("a"))
        #expect(await eventually { model.displayedState == .working })
        store.ingest(HookEvent(sessionID: "a", eventName: .stop, cwd: "/tmp/a"))
        #expect(await eventually { model.displayedState == .toast(.done) })
        // ~1.1 s later the toast is gone and the finished session leaves the island idle.
        #expect(await eventually { model.displayedState == .idle })
        model.stop()
    }

    @Test func prerollHistoryNeverFlashes() async {
        let store = SessionStore()
        let model = IslandModel(store: store, renderMode: .snapshot(now: Date()))
        model.start()
        model.beginPreroll()
        store.ingest(prompt("ci"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.displayedState == .idle)
        store.ingest(HookEvent(sessionID: "ci", eventName: .stop, cwd: "/tmp/ci"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.displayedState == .idle)
        model.endPreroll()
        try? await Task.sleep(nanoseconds: 50_000_000)
        // The stale "Done" toast from history is never shown.
        #expect(model.displayedState == .idle)
        model.stop()
    }

    @Test func swappingStoresDoesNotReplayTheirToast() async {
        let live = SessionStore()
        let other = SessionStore()
        other.ingest(prompt("x"))
        other.ingest(HookEvent(sessionID: "x", eventName: .stop, cwd: "/tmp/x"))
        let model = IslandModel(store: live, renderMode: .snapshot(now: Date()))
        model.start()
        model.store = other
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(model.displayedState == .idle)
        model.stop()
    }

    @Test func hoverOpensProgressAfterTheDelayAndClosesAfterLeaving() async {
        let store = SessionStore()
        store.ingest(prompt("a"))
        let model = IslandModel(store: store, renderMode: .snapshot(now: Date()))
        model.start()
        #expect(await eventually { model.displayedState == .working })
        model.setPointerInside(true)
        #expect(model.displayedState == .working)   // not before 120 ms
        #expect(await eventually { model.displayedState == .progress })
        model.setPointerInside(false)
        #expect(model.displayedState == .progress)  // not before 220 ms
        #expect(await eventually { model.displayedState == .working })
        model.stop()
    }
}
