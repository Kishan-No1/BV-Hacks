// OWNER: workstream C (app-ui).
import AppKit
import NodCore
import SwiftUI

/// A permission request card, 560 wide, height fit to content: who + avatars, title + risk pill, the command /
/// diff / detail card, reason chips (high), and the action buttons.
struct RequestContent: View {
    let model: IslandModel
    let request: PendingRequest

    var body: some View {
        let store = model.store
        let a = request.assessment
        let headline = store.session(id: request.sessionID)?.headline ?? (request.cwd as NSString).lastPathComponent
        VStack(alignment: .leading, spacing: 0) {
            // .rq-top
            HStack(spacing: 12) {
                WhoLine(headline: headline, clawd: 22)
                Spacer(minLength: 0)
                AvatarRow(sessions: store.sessions, ringID: request.sessionID)
            }
            .frame(height: 30)

            // .ask
            HStack(spacing: 10) {
                InlineCodeText(text: a.title, font: Theme.font(16.5, .bold), codeFont: Theme.mono(15, .bold),
                               tracking: Theme.em(-0.02, 16.5))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if let prediction = store.predictions[request.id] { PredictionChip(prediction: prediction) }
                RiskPill(level: a.level)
            }
            .padding(.top, 12)
            .padding(.bottom, 9)

            RequestBody(request: request)

            if a.level == .high, !a.reasons.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(a.reasons.enumerated()), id: \.offset) { _, reason in ReasonChip(text: reason.replacingOccurrences(of: "'", with: "’")) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .padding(.top, 8)
            }

            RequestActions(model: model, request: request)
                .padding(.top, 12)
        }
        .padding(.top, IslandGeometry.contentTopPadding(notch: model.notch))
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .frame(width: IslandGeometry.requestWidth, alignment: .topLeading)
    }
}

/// The `$ command` card, the diff card, or a detail card for other tools.
struct RequestBody: View {
    let request: PendingRequest

    var body: some View {
        let a = request.assessment
        let inlineReasons = a.level == .high ? "" : a.reasons.joined(separator: " · ").lowercased()
        if let diff = a.diff {
            DiffCard(diff: diff)
        } else if let command = a.command {
            CommandCard(prefix: "$", text: Format.commandLine(command), why: inlineReasons)
        } else {
            CommandCard(prefix: nil, text: Format.requestDetail(toolName: request.toolName, input: request.toolInput), why: inlineReasons)
        }
    }
}

/// `.card.cmd`.
struct CommandCard: View {
    let prefix: String?
    let text: String
    let why: String

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                if let prefix { Text(prefix).foregroundStyle(Theme.ink3) }
                Text(text).foregroundStyle(Color.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(Theme.mono(12.5, .semibold))
            Spacer(minLength: 0)
            if !why.isEmpty {
                Text(why)
                    .font(Theme.font(12, .medium))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(minHeight: 18)
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(CardBackground())
    }
}

/// `.card.diff`: file header with summary, then red / green lines.
struct DiffCard: View {
    let diff: DiffPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(diff.fileName)
                    .font(Theme.mono(12, .bold))
                    .foregroundStyle(Theme.orange2)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(diff.summary)
                    .font(Theme.font(12, .semibold))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            ForEach(Array(diff.lines.prefix(6).enumerated()), id: \.offset) { i, line in
                Text(Self.marker(line.kind) + line.text.replacingOccurrences(of: "\t", with: "  "))
                    .font(Theme.mono(12, .semibold))
                    .foregroundStyle(Self.color(line.kind))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 19)
                    .padding(.horizontal, 12)
                    .padding(.bottom, i == min(diff.lines.count, 6) - 1 ? 5 : 0)
                    .background(Self.background(line.kind))
            }
        }
        .background(CardBackground())
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    static func marker(_ k: DiffLine.Kind) -> String {
        switch k {
        case .added: return "+"
        case .removed: return "-"
        case .context: return " "
        }
    }

    static func color(_ k: DiffLine.Kind) -> Color {
        switch k {
        case .added: return Color(hex: 0x8BE3A4)
        case .removed: return Color(hex: 0xFFA29B)
        case .context: return Theme.ink2
        }
    }

    static func background(_ k: DiffLine.Kind) -> Color {
        switch k {
        case .added: return Theme.green.opacity(0.09)
        case .removed: return Theme.red.opacity(0.09)
        case .context: return .clear
        }
    }
}

/// `.acts`: Deny / middle / Allow for low and review; Hold to allow / wide red Deny for high.
struct RequestActions: View {
    let model: IslandModel
    let request: PendingRequest

    var body: some View {
        let id = request.id
        if request.requiresHoldToAllow {
            FlexRow(weights: [1, 1.45]) {
                HoldToAllowButton { model.allow(id) }
                CapsuleButton(kind: .red, keyHint: "⌥↵", action: { model.deny(id) }) { Text("Deny") }
            }
        } else if let diff = request.assessment.diff {
            FlexRow(weights: [1, 1.45, 1]) {
                CapsuleButton(kind: .neutral, keyHint: "⌥⌫", action: { model.deny(id) }) { Text("Deny") }
                CapsuleButton(kind: .ghost, action: { model.openDiff(request) }) { Text("Open full diff") }
                    .help(diff.filePath)
                CapsuleButton(kind: .primary, keyHint: "⌥↵", action: { model.allow(id) }) { Text("Allow") }
            }
        } else if let suggestion = request.ruleSuggestion {
            FlexRow(weights: [1, 1.45, 1]) {
                CapsuleButton(kind: .neutral, keyHint: "⌥⌫", action: { model.deny(id) }) { Text("Deny") }
                CapsuleButton(kind: .ghost, action: { model.alwaysAllow(id) }) {
                    if suggestion.commandPrefix != nil {
                        // The command is ONE monospaced span (prototype `<code>`), with no proportional
                        // tracking applied inside it, so "npm test" keeps even spacing.
                        HStack(spacing: 5) {
                            Text("Always allow")
                            Text(verbatim: suggestion.label).font(Theme.mono(12, .semibold)).tracking(0)
                        }
                    } else {
                        Text("Always allow \(suggestion.label)")
                    }
                }
                CapsuleButton(kind: .primary, keyHint: "⌥↵", action: { model.allow(id) }) { Text("Allow") }
            }
        } else {
            FlexRow(weights: [1, 1]) {
                CapsuleButton(kind: .neutral, keyHint: "⌥⌫", action: { model.deny(id) }) { Text("Deny") }
                CapsuleButton(kind: .primary, keyHint: "⌥↵", action: { model.allow(id) }) { Text("Allow") }
            }
        }
    }
}

/// Measures a request card's natural height at 560 pt, like the prototype's `measure()`.
@MainActor
enum RequestMeasurer {
    static func height(for request: PendingRequest, model: IslandModel) -> CGFloat {
        let view = RequestContent(model: model, request: request)
            .environment(\.nodRender, RenderMode.snapshot(now: Date()))
            .fixedSize(horizontal: false, vertical: true)
        let host = NSHostingController(rootView: view)
        let size = host.sizeThatFits(in: CGSize(width: IslandGeometry.requestWidth, height: 2000))
        let h = size.height.isFinite && size.height > 60 ? ceil(size.height) : IslandGeometry.fallbackRequestHeight
        return min(h, IslandGeometry.canvas.height - 110)
    }
}
