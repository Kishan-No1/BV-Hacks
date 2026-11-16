import AppKit
import NotchAgentCore
import SwiftUI

/// The prompt composer card, 560 wide: the target session, the rough text, the editable polished text,
/// one status line (what Polish sends, an error, or a waiting request) and the buttons.
struct ComposerContent: View {
    let model: IslandModel

    static let draftEditorHeight: CGFloat = 80
    static let polishedEditorHeight: CGFloat = 114

    var body: some View {
        let composer = model.composer
        VStack(alignment: .leading, spacing: 0) {
            ComposerHeader(model: model)
                .frame(height: 30)

            if composer.phase == .sent {
                ComposerSent(composer: composer)
                    .padding(.top, 10)
            } else {
                ComposerEditors(composer: composer)
                    .padding(.top, 10)
                ComposerStatus(model: model)
                    .frame(height: 30, alignment: .topLeading)
                    .padding(.top, 8)
                ComposerActions(composer: composer)
                    .padding(.top, 10)
            }
        }
        .padding(.top, IslandGeometry.contentTopPadding(notch: model.notch))
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .frame(width: IslandGeometry.requestWidth, alignment: .topLeading)
    }
}

/// "Prompt ● BV-Hacks · main" and the session avatars; clicking an avatar re-aims the prompt.
private struct ComposerHeader: View {
    let model: IslandModel

    var body: some View {
        let composer = model.composer
        let target = composer.target
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Clawd(width: 22)
                Text("Prompt")
                    .font(Theme.font(18, .bold))
                    .tracking(Theme.em(-0.022, 18))
                    .foregroundStyle(Theme.ink)
                    .fixedSize()
                Circle().fill(target == nil ? Theme.ink3 : Theme.orange).frame(width: 6, height: 6)
                Text(Self.label(for: target))
                    .font(Theme.font(14.5, .semibold))
                    .tracking(Theme.em(-0.012, 14.5))
                    .foregroundStyle(target == nil ? Theme.ink2 : Theme.orange2)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            AvatarRow(sessions: model.store.sessions, ringID: composer.targetSessionID) { id in
                composer.selectTarget(id)
            }
        }
    }

    /// "to BV-Hacks · main": the session folder and its branch.
    static func label(for session: Session?) -> String {
        guard let session else { return "No Claude Code session yet" }
        if let branch = session.branch, !branch.isEmpty { return "to \(session.name) · \(branch)" }
        return "to \(session.name)"
    }
}

/// The rough-text field; once polished, a one-line reminder of the rough text above the editable polish.
private struct ComposerEditors: View {
    @Bindable var composer: ComposerModel

    var body: some View {
        let showsPolish = composer.layout == .polished
        VStack(alignment: .leading, spacing: 8) {
            if showsPolish {
                HStack(spacing: 8) {
                    Text("You wrote")
                        .font(Theme.font(11.5, .semibold))
                        .foregroundStyle(Theme.ink3)
                        .fixedSize()
                    Text(Self.oneLine(composer.rawText))
                        .font(Theme.font(12.5, .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .frame(height: 18)

                ComposerField(text: $composer.polishedText, placeholder: "", height: ComposerContent.polishedEditorHeight,
                              editable: composer.phase == .polished, focusToken: composer.focusToken,
                              onReturn: { Task { await composer.send() } }, onEscape: { composer.discard() })
            } else {
                ComposerField(text: $composer.rawText, placeholder: "Rough prompt, e.g. “fix the flaky login test”",
                              height: ComposerContent.draftEditorHeight,
                              editable: composer.phase == .draft, focusToken: composer.focusToken,
                              onReturn: { Task { await composer.submitDraft() } }, onEscape: { composer.discard() })
            }
        }
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

/// A text card. Live: an `NSTextView`. Snapshots: static text in the same frame (AppKit views do not
/// render offscreen).
private struct ComposerField: View {
    @Binding var text: String
    let placeholder: String
    let height: CGFloat
    let editable: Bool
    let focusToken: Int
    let onReturn: () -> Void
    let onEscape: () -> Void
    @Environment(\.notchAgentRender) private var render

    var body: some View {
        ZStack(alignment: .topLeading) {
            if render.animated {
                ComposerTextView(text: $text, editable: editable, focusToken: focusToken, onReturn: onReturn, onEscape: onEscape)
            } else {
                Text(text)
                    .font(.system(size: ComposerTextView.fontSize))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 2)
            }
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: ComposerTextView.fontSize))
                    .foregroundStyle(Theme.ink3)
                    .padding(.top, 2)
                    .allowsHitTesting(false)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(CardBackground(radius: 14))
        .opacity(editable ? 1 : 0.6)
    }
}

/// One status line (two rows at most): an error, a waiting request, or what the next action does.
private struct ComposerStatus: View {
    let model: IslandModel

    var body: some View {
        let composer = model.composer
        let (text, color) = Self.line(composer: composer, waiting: model.store.pending.count)
        Text(text)
            .font(Theme.font(11.5, .medium))
            .foregroundStyle(color)
            .lineLimit(2)
            .lineSpacing(1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    static func line(composer: ComposerModel, waiting: Int) -> (String, Color) {
        if let error = composer.errorMessage { return (error, Theme.amber) }
        if composer.phase == .polishing { return ("Polishing with Claude Haiku…", Theme.ink2) }
        if composer.phase == .sending { return ("Sending…", Theme.ink2) }
        if waiting > 0 {
            let n = waiting == 1 ? "1 permission request is" : "\(waiting) permission requests are"
            return ("\(n) waiting. Close the composer (esc) to answer.", Theme.amber)
        }
        if composer.target == nil {
            return ("No session to send to yet. Start one with scripts/notch-agent-claude, or copy the prompt.", Theme.ink2)
        }
        let notes = composer.noteCount
        let style = notes == 0 ? "" : notes == 1 ? " Using 1 learned style note." : " Using \(notes) learned style notes."
        if composer.phase == .polished {
            return ("Edit it freely. Return sends, Shift-Return adds a line.\(style)", Theme.ink2)
        }
        if !composer.polishEnabled {
            return ("Polish is off: Return sends this text as written, and nothing goes to Anthropic.", Theme.ink2)
        }
        return ("Polish sends this text, your style notes and repo names (folder, branch, last 3 commit subjects, changed file names) to Anthropic.\(style)", Theme.ink3)
    }
}

/// Discard / middle / primary. The middle button is "Send as written", "Edit draft" or, when tmux cannot
/// deliver the prompt, "Copy".
private struct ComposerActions: View {
    let composer: ComposerModel

    var body: some View {
        let offerCopy = composer.sendFailure != nil || composer.targetSessionID == nil
        let showsPolish = composer.layout == .polished
        FlexRow(weights: [1, 1.2, 1.2]) {
            CapsuleButton(kind: .neutral, keyHint: "esc", action: { composer.discard() }) { Text("Discard") }

            if offerCopy {
                CapsuleButton(kind: .ghost, action: { composer.copyInstead() }) { Text("Copy") }
                    .disabled(composer.isBusy || composer.outgoingText.isEmpty)
                    .opacity(composer.isBusy || composer.outgoingText.isEmpty ? 0.45 : 1)
            } else if showsPolish {
                CapsuleButton(kind: .ghost, action: { composer.editDraft() }) { Text("Edit draft") }
                    .disabled(composer.isBusy)
                    .opacity(composer.isBusy ? 0.45 : 1)
            } else {
                CapsuleButton(kind: .ghost, action: { Task { await composer.send() } }) {
                    Text(composer.polishEnabled ? "Send as written" : "Send")
                }
                .disabled(!composer.canSend || !composer.polishEnabled)
                .opacity(composer.canSend && composer.polishEnabled ? 1 : 0.45)
            }

            if showsPolish || !composer.polishEnabled {
                CapsuleButton(kind: .primary, keyHint: "↵", action: { Task { await composer.send() } }) {
                    Text(composer.phase == .sending ? "Sending…" : "Send")
                }
                .disabled(!composer.canSend)
                .opacity(composer.canSend || composer.phase == .sending ? 1 : 0.45)
            } else {
                CapsuleButton(kind: .primary, keyHint: "↵", action: { Task { await composer.polish() } }) {
                    Text(composer.phase == .polishing ? "Polishing…" : "Polish")
                }
                .disabled(!composer.canPolish)
                .opacity(composer.canPolish || composer.phase == .polishing ? 1 : 0.45)
            }
        }
    }
}

/// After a send: where it went, and what the style profile learned from it.
private struct ComposerSent: View {
    let composer: ComposerModel

    static let maxChips = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                CheckIcon(size: 14, color: Theme.green)
                Text(composer.sentLabel)
                    .font(Theme.font(15, .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }
            .frame(height: 22)

            if composer.chips.isEmpty {
                Text("Nothing new learned from this one.")
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(Theme.ink3)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    let shown = Array(composer.chips.prefix(Self.maxChips))
                    ForEach(Array(shown.enumerated()), id: \.offset) { i, chip in
                        HStack(spacing: 8) {
                            LearnedChip(text: chip)
                            if i == shown.count - 1, composer.chips.count > shown.count {
                                Text("+\(composer.chips.count - shown.count) more")
                                    .font(Theme.font(11.5, .medium))
                                    .foregroundStyle(Theme.ink3)
                                    .fixedSize()
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// "Learned: Add: “run tests after edits”" in green; "Dropped: …" in amber.
struct LearnedChip: View {
    let text: String

    var body: some View {
        let color = text.hasPrefix("Dropped") ? Theme.amber : Theme.green
        Text(text)
            .font(Theme.font(11.5, .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.vertical, 4)
            .padding(.horizontal, 9)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().strokeBorder(color.opacity(0.28), lineWidth: 0.5))
    }
}

// MARK: - Text input

/// A plain-text `NSTextView`: Return submits, Shift-Return (or Option-Return) inserts a line, Esc cancels.
/// Smart quotes, dashes and text replacement are off: prompts hold code and must arrive as typed.
struct ComposerTextView: NSViewRepresentable {
    static let fontSize: CGFloat = 13.5

    @Binding var text: String
    var editable: Bool
    /// When this changes (and on first appearance) an editable field takes the keyboard.
    var focusToken: Int
    var onReturn: () -> Void
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let view = KeyTextView(frame: .zero)
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.drawsBackground = false
        view.font = .systemFont(ofSize: Self.fontSize)
        view.textColor = .white
        view.insertionPointColor = NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.textContainerInset = NSSize(width: 0, height: 2)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        view.defaultParagraphStyle = paragraph
        view.typingAttributes = [.font: NSFont.systemFont(ofSize: Self.fontSize), .foregroundColor: NSColor.white,
                                 .paragraphStyle: paragraph]
        view.string = text
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? KeyTextView else { return }
        context.coordinator.parent = self
        if view.string != text { view.string = text }
        view.isEditable = editable
        view.isSelectable = true
        view.onReturn = onReturn
        view.onEscape = onEscape
        if editable, context.coordinator.focusedToken != focusToken {
            context.coordinator.focusedToken = focusToken
            view.wantsKeyboard = true
            DispatchQueue.main.async { view.takeKeyboardIfWanted() }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        var focusedToken: Int?

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if parent.text != view.string { parent.text = view.string }
        }
    }
}

final class KeyTextView: NSTextView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    /// Set when the field should become first responder as soon as it has a window.
    var wantsKeyboard = false

    func takeKeyboardIfWanted() {
        guard wantsKeyboard, let window else { return }
        wantsKeyboard = false
        window.makeFirstResponder(self)
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        takeKeyboardIfWanted()
    }

    override func keyDown(with event: NSEvent) {
        // Keys that belong to an input method composition (for example confirming Japanese text) go through.
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 36, 76: // Return, keypad Enter
            if flags.contains(.shift) || flags.contains(.option) {
                insertNewlineIgnoringFieldEditor(nil)
            } else if isEditable {
                onReturn?()
            }
        case 53: // Escape
            onEscape?()
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
