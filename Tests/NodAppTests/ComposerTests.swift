import Foundation
import Testing
@testable import Nod
import NodCore

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// Records every call, so a test can prove what did and did not leave the composer.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _polishRequests: [PolishRequest] = []
    private var _sends: [(text: String, sessionID: String, cwd: String)] = []
    private var _outcomes: [StyleOutcome] = []
    private var _copies: [String] = []

    func polish(_ r: PolishRequest) { lock.lock(); _polishRequests.append(r); lock.unlock() }
    func send(_ text: String, _ id: String, _ cwd: String) { lock.lock(); _sends.append((text, id, cwd)); lock.unlock() }
    func outcome(_ o: StyleOutcome) { lock.lock(); _outcomes.append(o); lock.unlock() }
    func copy(_ s: String) { lock.lock(); _copies.append(s); lock.unlock() }

    var polishRequests: [PolishRequest] { lock.lock(); defer { lock.unlock() }; return _polishRequests }
    var sends: [(text: String, sessionID: String, cwd: String)] { lock.lock(); defer { lock.unlock() }; return _sends }
    var outcomes: [StyleOutcome] { lock.lock(); defer { lock.unlock() }; return _outcomes }
    var copies: [String] { lock.lock(); defer { lock.unlock() }; return _copies }
}

private struct FakePolisher: Polishing {
    let recorder: Recorder
    var result: Result<String, PolishError>
    func polish(_ request: PolishRequest) async -> Result<String, PolishError> {
        recorder.polish(request)
        return result
    }
}

private struct FakeContext: RepoContextProviding {
    func context(cwd: String) async -> RepoContext {
        RepoContext(cwd: "~/repo", branch: "main", commitSubjects: ["one"], changedFiles: ["a.swift"])
    }
}

private struct FakeSender: PromptSending {
    let recorder: Recorder
    var result: SendResult
    func send(text: String, sessionID: String, cwd: String) async -> SendResult {
        recorder.send(text, sessionID, cwd)
        return result
    }
}

@MainActor
private struct Rig {
    let store = SessionStore()
    let model: IslandModel
    let recorder = Recorder()
    var composer: ComposerModel { model.composer }

    init(polish: Result<String, PolishError> = .success("Fix the login test. Report what you changed."),
         send: SendResult = .sent(pane: "%3"), polishEnabled: Bool = true, notes: [StyleNote] = [],
         changes: [StyleChange] = []) {
        model = IslandModel(store: store, renderMode: .snapshot(now: t0))
        var prompt = HookEvent(sessionID: "s1", eventName: .userPromptSubmit, cwd: "/tmp/repo")
        prompt.prompt = "earlier prompt"
        store.ingest(prompt)
        store.ingest(HookEvent(sessionID: "s1", eventName: .stop, cwd: "/tmp/repo"))
        let recorder = self.recorder
        var services = ComposerModel.Services(
            polisher: FakePolisher(recorder: recorder, result: polish),
            context: FakeContext(),
            sender: FakeSender(recorder: recorder, result: send),
            topNotes: { notes },
            record: { outcome in recorder.outcome(outcome); return changes },
            polishEnabled: { polishEnabled },
            copy: { recorder.copy($0) })
        services.now = { t0 }
        services.sentDuration = 30
        model.composer.services = services
    }
}

@Suite("Island state with the composer")
struct ComposerStateTests {
    @Test func composerBeatsEverything() {
        let s = [Session(id: "a", cwd: "/tmp/a", name: "a", status: .needsYou, lastEventAt: t0)]
        let r = PendingRequest(sessionID: "a", toolName: "Bash", toolInput: ["command": "npm test"], cwd: "/tmp/a",
                               assessment: Assessment(level: .high, title: "Run", command: "npm test"), receivedAt: t0)
        #expect(IslandState.derive(sessions: s, currentRequest: r, visibleToast: .done, isHovering: true,
                                   composer: .draft) == .composer(.draft))
        // Without the composer nothing changed: the request still wins.
        #expect(IslandState.derive(sessions: s, currentRequest: r, visibleToast: .done, isHovering: true) == .request(r))
    }

    @Test func composerOpensWithNoSessions() {
        #expect(IslandState.derive(sessions: [], currentRequest: nil, visibleToast: nil, isHovering: false,
                                   composer: .polished) == .composer(.polished))
    }

    @Test func composerIsExpandedWithOneIdentityAndNoGlow() {
        #expect(IslandState.composer(.draft).isExpanded)
        #expect(IslandState.composer(.draft).identity == IslandState.composer(.polished).identity)
        #expect(IslandState.composer(.polished).glowRisk == nil)
    }

    @Test func composerSizesFitTheCanvas() {
        for layout in [ComposerLayout.draft, .polished, .sent] {
            let size = IslandGeometry.size(for: .composer(layout), notch: .simulated)
            #expect(size.width == 560)
            #expect(size.height == 32 + layout.bodyHeight)
            #expect(size.height < IslandGeometry.canvas.height - 60)
        }
        #expect(ComposerLayout.polished.bodyHeight > ComposerLayout.draft.bodyHeight)
    }
}

@Suite("Composer flow")
@MainActor
struct ComposerFlowTests {
    @Test func opensOnTheSessionProgressShows() {
        let rig = Rig()
        rig.model.openComposer()
        #expect(rig.composer.isOpen)
        #expect(rig.composer.target?.id == "s1")
        #expect(rig.model.derivedState == .composer(.draft))
    }

    @Test func clickingTheShownAvatarOpensTheComposerAndAnotherAvatarSwitches() {
        let rig = Rig()
        var p = HookEvent(sessionID: "s2", eventName: .userPromptSubmit, cwd: "/tmp/other")
        p.prompt = "other"
        rig.store.ingest(p)
        let shown = rig.model.progressSession!.id
        let other = shown == "s1" ? "s2" : "s1"
        rig.model.avatarClicked(other)
        #expect(!rig.composer.isOpen)
        #expect(rig.store.selectedSessionID == other)
        rig.model.avatarClicked(other)
        #expect(rig.composer.isOpen)
        #expect(rig.composer.target?.id == other)
    }

    @Test func polishNeverSends() async {
        let rig = Rig()
        rig.model.openComposer()
        rig.composer.rawText = "fix login test"
        await rig.composer.polish()
        #expect(rig.composer.phase == .polished)
        #expect(rig.composer.polishedText == "Fix the login test. Report what you changed.")
        #expect(rig.model.derivedState == .composer(.polished))
        #expect(rig.recorder.sends.isEmpty)
        #expect(rig.recorder.outcomes.isEmpty)
        #expect(rig.recorder.copies.isEmpty)
    }

    @Test func polishRequestCarriesTheRawTextTheNotesAndTheContext() async {
        let note = StyleNote(key: "add:run tests", text: "Add: “run tests after edits”", score: 1, count: 1, active: true, updatedAt: t0)
        let rig = Rig(notes: [note])
        rig.model.openComposer()
        rig.composer.rawText = "  fix login test \n"
        await rig.composer.polish()
        let request = try? #require(rig.recorder.polishRequests.first)
        #expect(request?.raw == "fix login test")
        #expect(request?.notes == ["Add: “run tests after edits”"])
        #expect(request?.context?.branch == "main")
    }

    @Test func sendTypesTheEditedTextAndLearnsFromIt() async {
        let learned = StyleNote(key: "add:run tests after edits", text: "Add: “run tests after edits”", score: 1, count: 1,
                                active: true, updatedAt: t0)
        let rig = Rig(changes: [.learned(learned)])
        rig.model.openComposer()
        rig.composer.rawText = "fix login test"
        await rig.composer.polish()
        rig.composer.polishedText = "Fix the login test.\nrun tests after edits"
        await rig.composer.send()

        #expect(rig.recorder.sends.count == 1)
        #expect(rig.recorder.sends.first?.text == "Fix the login test.\nrun tests after edits")
        #expect(rig.recorder.sends.first?.sessionID == "s1")
        #expect(rig.recorder.sends.first?.cwd == "/tmp/repo")
        #expect(rig.recorder.outcomes == [StyleOutcome(raw: "fix login test",
                                                       polished: "Fix the login test. Report what you changed.",
                                                       final: "Fix the login test.\nrun tests after edits", at: t0)])
        #expect(rig.composer.phase == .sent)
        #expect(rig.composer.chips == ["Learned: Add: “run tests after edits”"])
        #expect(rig.composer.sentLabel == "Sent to repo")
        #expect(rig.model.derivedState == .composer(.sent))
        #expect(rig.composer.rawText.isEmpty)
    }

    @Test func noKeyShowsAnErrorAndTheRawTextCanStillBeSent() async {
        let rig = Rig(polish: .failure(.noKey))
        rig.model.openComposer()
        rig.composer.rawText = "fix login test"
        await rig.composer.polish()
        #expect(rig.composer.phase == .draft)
        #expect(rig.composer.errorMessage == PolishError.noKey.userMessage)
        #expect(rig.recorder.sends.isEmpty)
        #expect(rig.composer.canSend)
        await rig.composer.send()
        #expect(rig.recorder.sends.first?.text == "fix login test")
        // Sent without a polish: the profile sees no polished text.
        #expect(rig.recorder.outcomes.first?.polished == nil)
        #expect(rig.recorder.outcomes.first?.final == "fix login test")
    }

    @Test func polishOffMakesNoPolishCallAndReturnSendsTheDraft() async {
        let rig = Rig(polishEnabled: false)
        rig.model.openComposer()
        rig.composer.rawText = "fix login test"
        #expect(!rig.composer.canPolish)
        await rig.composer.polish()
        #expect(rig.recorder.polishRequests.isEmpty)
        await rig.composer.submitDraft()
        #expect(rig.recorder.polishRequests.isEmpty)
        #expect(rig.recorder.sends.first?.text == "fix login test")
    }

    @Test func returnOnTheDraftPolishesAndDoesNotSendWhenPolishIsOn() async {
        let rig = Rig()
        rig.model.openComposer()
        rig.composer.rawText = "fix login test"
        await rig.composer.submitDraft()
        #expect(rig.recorder.polishRequests.count == 1)
        #expect(rig.recorder.sends.isEmpty)
    }

    @Test(arguments: [SendResult.tmuxMissing, .paneNotFound, .notAtPrompt, .failed("tmux exited 1")])
    func aFailedSendKeepsTheTextAndOffersCopy(result: SendResult) async {
        let rig = Rig(send: result)
        rig.model.openComposer()
        rig.composer.rawText = "fix login test"
        await rig.composer.polish()
        await rig.composer.send()
        #expect(rig.composer.phase == .polished)
        #expect(rig.composer.errorMessage == result.userMessage)
        #expect(rig.composer.sendFailure == result)
        #expect(rig.composer.polishedText == "Fix the login test. Report what you changed.")
        #expect(rig.recorder.outcomes.isEmpty)

        rig.composer.copyInstead()
        #expect(rig.recorder.copies == ["Fix the login test. Report what you changed."])
        #expect(rig.composer.phase == .sent)
        #expect(rig.composer.sentLabel == "Copied to the clipboard")
        #expect(rig.recorder.outcomes.count == 1)
    }

    @Test func aSessionWaitingOnAPermissionRequestIsNeverTypedInto() async {
        let rig = Rig()
        var e = HookEvent(sessionID: "s1", eventName: .permissionRequest, cwd: "/tmp/repo")
        e.toolName = "Bash"
        e.toolInput = ["command": .string("npm test")]
        let pending = Task { @MainActor in await rig.store.requestDecision(for: e, timeout: 30) }
        #expect(await eventually { !rig.store.pending.isEmpty })

        rig.model.openComposer(sessionID: "s1")
        rig.composer.rawText = "1"
        await rig.composer.send()
        #expect(rig.recorder.sends.isEmpty)
        #expect(rig.composer.sendFailure == .notAtPrompt)
        #expect(rig.composer.errorMessage?.contains("permission request") == true)

        rig.store.resolve(rig.store.pending[0].id, .deny(message: nil))
        _ = await pending.value
    }

    @Test func theComposerHidesARequestFromTheHotkeysUntilItCloses() async {
        let rig = Rig()
        rig.model.start()
        rig.model.openComposer()
        #expect(await eventually { rig.model.displayedState == .composer(.draft) })
        var e = HookEvent(sessionID: "s1", eventName: .permissionRequest, cwd: "/tmp/repo")
        e.toolName = "Bash"
        e.toolInput = ["command": .string("npm test")]
        let pending = Task { @MainActor in await rig.store.requestDecision(for: e, timeout: 30) }
        #expect(await eventually { !rig.store.pending.isEmpty })
        // The card is not on screen, so ⌥↵ answers nothing.
        rig.model.now = { Date().addingTimeInterval(10) }
        rig.model.hotkeyDefault()
        #expect(rig.store.pending.count == 1)
        #expect(rig.model.displayedState == .composer(.draft))

        rig.composer.discard()
        #expect(await eventually { if case .request = rig.model.displayedState { return true } else { return false } })
        rig.store.resolve(rig.store.pending[0].id, .deny(message: nil))
        _ = await pending.value
        rig.model.stop()
    }

    @Test func discardThrowsTheTextAwayAndCloseKeepsIt() async {
        let rig = Rig()
        rig.model.openComposer()
        rig.composer.rawText = "draft"
        rig.model.toggleComposer()
        #expect(!rig.composer.isOpen)
        #expect(rig.composer.rawText == "draft")
        rig.model.toggleComposer()
        #expect(rig.composer.isOpen)
        rig.composer.discard()
        #expect(!rig.composer.isOpen)
        #expect(rig.composer.rawText.isEmpty)
        #expect(rig.recorder.sends.isEmpty)
    }

    @Test func nothingIsSentWithoutATargetSessionOrText() async {
        let store = SessionStore()
        let model = IslandModel(store: store, renderMode: .snapshot(now: t0))
        let recorder = Recorder()
        model.composer.services.sender = FakeSender(recorder: recorder, result: .sent(pane: "%1"))
        model.openComposer()
        model.composer.rawText = "hello"
        #expect(!model.composer.canSend)
        await model.composer.send()
        #expect(recorder.sends.isEmpty)

        let rig = Rig()
        rig.model.openComposer()
        rig.composer.rawText = "   \n"
        await rig.composer.send()
        #expect(rig.recorder.sends.isEmpty)
    }

    @Test func aLatePolishAnswerAfterDiscardIsDropped() async {
        let rig = Rig()
        rig.model.openComposer()
        rig.composer.rawText = "fix login test"
        async let polishing: Void = rig.composer.polish()
        rig.composer.discard()
        await polishing
        #expect(rig.composer.phase == .draft)
        #expect(rig.composer.polishedText.isEmpty)
        #expect(!rig.composer.isOpen)
    }
}

@Suite("Composer log lines carry no prompt text")
struct ComposerLogTests {
    @Test func linesAreBuiltFromCountsAndStatusOnly() {
        let secret = "SECRET-PROMPT-TEXT"
        let lines = [
            ComposerLog.polished(rawCount: secret.count, polishedCount: 120, notes: 3, ms: 412),
            ComposerLog.polishFailed(.noKey, ms: 1),
            ComposerLog.polishFailed(.http(status: 401, type: "authentication_error"), ms: 80),
            ComposerLog.polishFailed(.network, ms: 80),
            ComposerLog.polishFailed(.refused, ms: 80),
            ComposerLog.polishFailed(.empty, ms: 80),
            ComposerLog.sendResult(.sent(pane: "%3"), changes: 2),
            ComposerLog.sendResult(.tmuxMissing, changes: 0),
            ComposerLog.sendResult(.paneNotFound, changes: 0),
            ComposerLog.sendResult(.notAtPrompt, changes: 0),
            ComposerLog.sendResult(.failed(secret), changes: 0),
            ComposerLog.copied(changes: 1),
        ]
        for line in lines {
            #expect(!line.contains(secret))
            #expect(line.hasPrefix("composer: "))
        }
        #expect(lines[0] == "composer: polish ok, 18 -> 120 chars, 3 style notes, 412 ms")
        #expect(lines[2] == "composer: polish failed (http 401 authentication_error), 80 ms")
    }

    @Test func launchOptionsParseTheComposerFlags() {
        let o = LaunchOptions.parse(["Nod", "--test-compose", "hello there"],
                                    env: ["NOD_STYLE_FILE": "/tmp/style.json", "NOD_PANES_DIR": "/tmp/panes"])
        #expect(o.testCompose == "hello there")
        #expect(o.styleFile == "/tmp/style.json")
        #expect(o.panesDir == "/tmp/panes")
        #expect(o.errors.isEmpty)
        #expect(LaunchOptions.parse(["Nod", "--test-compose"], env: [:]).errors.count == 1)
        #expect(LaunchOptions.parse(["Nod"], env: [:]).testCompose == nil)
    }
}
