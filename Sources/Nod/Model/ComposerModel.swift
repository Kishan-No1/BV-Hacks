import Foundation
import NodCore
import Observation

/// The prompt composer: rough text -> polish -> edit -> send.
///
/// Two rules hold everywhere in this file:
/// - Nothing is sent to a session unless `send()` or `copyInstead()` is called, and only the Send / Copy
///   buttons and Return call them. Polishing never sends.
/// - Log lines are built from counts and status codes. The prompt, the polish and the style notes are
///   never logged.
@MainActor
@Observable
final class ComposerModel {
    enum Phase: Equatable {
        /// Typing the rough prompt.
        case draft
        /// Waiting for the polish call.
        case polishing
        /// Reading and editing the polished text.
        case polished
        /// Handing the text to tmux.
        case sending
        /// Done: shows where it went and what was learned, then closes.
        case sent
    }

    /// The services the composer talks to. `inert` keeps tests, snapshots and the demo offline.
    struct Services {
        var polisher: any Polishing
        var context: any RepoContextProviding
        var sender: any PromptSending
        /// The active style notes to inject into the next polish.
        var topNotes: @MainActor () -> [StyleNote]
        /// Learns from one outcome and returns what changed.
        var record: @MainActor (StyleOutcome) -> [StyleChange]
        /// The menu toggle. Off = the draft is sent as written and no network call is made.
        var polishEnabled: @MainActor () -> Bool
        var copy: @MainActor (String) -> Void
        var now: @MainActor () -> Date = { Date() }
        /// How long the "Sent" card stays up.
        var sentDuration: TimeInterval = 2.6

        static var inert: Services {
            Services(polisher: InertPolisher(), context: InertContext(), sender: InertSender(),
                     topNotes: { [] }, record: { _ in [] }, polishEnabled: { true }, copy: { _ in })
        }
    }

    var services: Services = .inert
    /// Looks a session up in the store the island is showing.
    @ObservationIgnored var session: @MainActor (String) -> Session? = { _ in nil }
    /// True while the session has a permission request open: typing into its pane could answer the dialog.
    @ObservationIgnored var isSessionBlocked: @MainActor (String) -> Bool = { _ in false }

    private(set) var isOpen = false
    private(set) var phase: Phase = .draft
    var rawText = ""
    /// The polished text, edited in place by the user.
    var polishedText = ""
    /// What the model returned, before the user's edits. nil when the text was not polished.
    private(set) var polishOutput: String?
    private(set) var targetSessionID: String?
    /// One line under the text: a polish error or why the send did not happen.
    private(set) var errorMessage: String?
    /// Set when the send failed in a way that Copy can work around.
    private(set) var sendFailure: SendResult?
    /// "Learned: …" / "Dropped: …" lines from the last send.
    private(set) var chips: [String] = []
    /// "Sent to nod" / "Copied".
    private(set) var sentLabel = ""
    /// Bumped whenever the text field that should have the keyboard changes.
    private(set) var focusToken = 0

    @ObservationIgnored private var polishRun = 0
    @ObservationIgnored private var closeTask: Task<Void, Never>?

    var layout: ComposerLayout {
        switch phase {
        case .sent: return .sent
        case .polished: return .polished
        case .sending: return polishOutput == nil ? .draft : .polished
        case .draft, .polishing: return .draft
        }
    }

    var polishEnabled: Bool { services.polishEnabled() }
    var target: Session? { targetSessionID.flatMap { session($0) } }
    var noteCount: Int { services.topNotes().count }
    var isBusy: Bool { phase == .polishing || phase == .sending }

    /// The text Send would send right now.
    var outgoingText: String {
        let showsPolish = phase == .polished || (phase == .sending && polishOutput != nil)
        return (showsPolish ? polishedText : rawText).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canPolish: Bool {
        polishEnabled && !isBusy && phase != .sent && !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSend: Bool { !isBusy && phase != .sent && !outgoingText.isEmpty && targetSessionID != nil }

    // MARK: Open / close

    func open(sessionID: String?) {
        closeTask?.cancel()
        if phase == .sent { reset() }
        if let sessionID { targetSessionID = sessionID }
        isOpen = true
        focusToken += 1
    }

    /// Hides the composer and keeps the draft (⌃⌥P again).
    func close() {
        closeTask?.cancel()
        isOpen = false
        if phase == .sent { reset() }
    }

    /// Discard / Esc: throws the text away and closes.
    func discard() {
        Log.debug("action: discard prompt")
        closeTask?.cancel()
        polishRun += 1
        reset()
        isOpen = false
    }

    func selectTarget(_ sessionID: String) {
        guard !isBusy else { return }
        targetSessionID = sessionID
        clearError()
    }

    private func reset() {
        rawText = ""
        polishedText = ""
        polishOutput = nil
        errorMessage = nil
        sendFailure = nil
        chips = []
        sentLabel = ""
        phase = .draft
    }

    private func clearError() {
        errorMessage = nil
        sendFailure = nil
    }

    // MARK: Polish

    /// Return in the draft field: polish when polish is on, otherwise send the draft as written.
    func submitDraft() async {
        if polishEnabled { await polish() } else { await send() }
    }

    /// Sends the rough text, the style notes and the repo context to the polisher. Never sends to a session.
    func polish() async {
        guard canPolish else { return }
        let raw = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        polishRun += 1
        let run = polishRun
        clearError()
        phase = .polishing
        let started = services.now()
        let notes = services.topNotes().map(\.text)
        var context: RepoContext?
        if let cwd = target?.cwd, !cwd.isEmpty { context = await services.context.context(cwd: cwd) }
        guard run == polishRun else { return }
        let result = await services.polisher.polish(PolishRequest(raw: raw, notes: notes, context: context))
        // Discarded, closed or polished again while the call was in flight: drop the answer.
        guard run == polishRun, phase == .polishing else { return }
        let ms = Int(services.now().timeIntervalSince(started) * 1000)
        switch result {
        case .success(let text):
            polishOutput = text
            polishedText = text
            phase = .polished
            focusToken += 1
            Log.debug(ComposerLog.polished(rawCount: raw.count, polishedCount: text.count, notes: notes.count, ms: ms))
        case .failure(let error):
            phase = .draft
            errorMessage = error.userMessage
            focusToken += 1
            Log.debug(ComposerLog.polishFailed(error, ms: ms))
        }
    }

    /// Back to the rough text to polish it again.
    func editDraft() {
        guard phase == .polished else { return }
        polishOutput = nil
        polishedText = ""
        clearError()
        phase = .draft
        focusToken += 1
    }

    // MARK: Send

    /// The Send button and Return on the text. The only path that types into a session.
    func send() async {
        guard canSend, let sessionID = targetSessionID else { return }
        let text = outgoingText
        let before = phase
        clearError()
        if isSessionBlocked(sessionID) {
            errorMessage = "That session is waiting on a permission request. Answer it first, or copy the prompt."
            sendFailure = .notAtPrompt
            Log.debug(ComposerLog.sendResult(.notAtPrompt, changes: 0))
            return
        }
        phase = .sending
        let result = await services.sender.send(text: text, sessionID: sessionID, cwd: session(sessionID)?.cwd ?? "")
        guard phase == .sending else { return }
        if result.isSent {
            let name = session(sessionID)?.name
            finish(text: text, polished: before == .polished ? polishOutput : nil,
                   label: name.map { "Sent to \($0)" } ?? "Sent", result: result)
        } else {
            phase = before
            errorMessage = result.userMessage
            sendFailure = result
            focusToken += 1
            Log.debug(ComposerLog.sendResult(result, changes: 0))
        }
    }

    /// Copy: puts the text on the clipboard when tmux cannot deliver it. Also an explicit user action,
    /// so the style profile learns from it like a send.
    func copyInstead() {
        guard !isBusy, phase != .sent else { return }
        let text = outgoingText
        guard !text.isEmpty else { return }
        services.copy(text)
        finish(text: text, polished: phase == .polished ? polishOutput : nil, label: "Copied to the clipboard", result: nil)
    }

    private func finish(text: String, polished: String?, label: String, result: SendResult?) {
        let outcome = StyleOutcome(raw: rawText.trimmingCharacters(in: .whitespacesAndNewlines), polished: polished,
                                   final: text, at: services.now())
        let changes = services.record(outcome)
        chips = changes.compactMap(\.chipText)
        sentLabel = label
        errorMessage = nil
        sendFailure = nil
        rawText = ""
        polishedText = ""
        polishOutput = nil
        phase = .sent
        if let result { Log.debug(ComposerLog.sendResult(result, changes: chips.count)) } else { Log.debug(ComposerLog.copied(changes: chips.count)) }
        closeTask?.cancel()
        let delay = services.sentDuration
        closeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.phase == .sent else { return }
            self.close()
        }
    }

    // MARK: Snapshots

    /// Puts the composer into a fixed state for `--snapshot` (no services run).
    func showForSnapshot(phase: Phase, sessionID: String?, raw: String, polished: String = "", error: String? = nil,
                         failure: SendResult? = nil, chips: [String] = [], sentLabel: String = "") {
        targetSessionID = sessionID
        rawText = raw
        polishedText = polished
        polishOutput = phase == .polished ? polished : nil
        errorMessage = error
        sendFailure = failure
        self.chips = chips
        self.sentLabel = sentLabel
        self.phase = phase
        isOpen = true
    }
}

/// Debug log lines for the composer. Counts and status only: no prompt text, no note text, no key.
enum ComposerLog {
    static func polished(rawCount: Int, polishedCount: Int, notes: Int, ms: Int) -> String {
        "composer: polish ok, \(rawCount) -> \(polishedCount) chars, \(notes) style notes, \(ms) ms"
    }

    static func polishFailed(_ error: PolishError, ms: Int) -> String {
        let why: String
        switch error {
        case .noKey: why = "no API key"
        case .http(let status, let type): why = "http \(status)\(type.map { " \($0)" } ?? "")"
        case .network: why = "network"
        case .refused: why = "refused"
        case .empty: why = "empty"
        }
        return "composer: polish failed (\(why)), \(ms) ms"
    }

    static func sendResult(_ result: SendResult, changes: Int) -> String {
        switch result {
        case .sent(let pane): return "composer: sent to pane \(pane), \(changes) style changes"
        case .tmuxMissing: return "composer: not sent (tmux missing)"
        case .paneNotFound: return "composer: not sent (no pane for the session)"
        case .notAtPrompt: return "composer: not sent (session not at its prompt)"
        case .failed: return "composer: not sent (tmux failed)"
        }
    }

    static func copied(changes: Int) -> String {
        "composer: copied to the clipboard, \(changes) style changes"
    }
}

private struct InertPolisher: Polishing {
    func polish(_ request: PolishRequest) async -> Result<String, PolishError> { .failure(.noKey) }
}

private struct InertContext: RepoContextProviding {
    func context(cwd: String) async -> RepoContext { RepoContext(cwd: cwd) }
}

private struct InertSender: PromptSending {
    func send(text: String, sessionID: String, cwd: String) async -> SendResult { .paneNotFound }
}
