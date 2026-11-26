import NotchAgentCore
import SwiftUI

/// "Claude needs your input": a question, a plan or Claude Code's own permission dialog that notchAgent cannot
/// answer itself. Pops the island open so it is never just a dot; the answer happens in the session.
struct InputContent: View {
    let model: IslandModel
    let sessionID: String
    let attention: Attention

    var body: some View {
        let store = model.store
        let session = store.session(id: sessionID)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                WhoLine(headline: session?.headline ?? "session", mascot: 25)
                Spacer(minLength: 0)
                AvatarRow(sessions: store.sessions, ringID: sessionID)
            }
            .frame(height: 30)

            HStack(spacing: 10) {
                Text(attention.title)
                    .font(Theme.font(16.5, .bold))
                    .tracking(Theme.em(-0.02, 16.5))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(session?.name ?? "")
                    .font(Theme.font(12, .semibold))
                    .foregroundStyle(Theme.amber)
                    .lineLimit(1)
            }
            .frame(height: 40)

            Text(attention.detail)
                .font(Theme.font(13.5, .medium))
                .foregroundStyle(Color.white.opacity(0.9))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(CardBackground())
                .frame(height: 56, alignment: .top)

            if !attention.options.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(attention.options.prefix(4).enumerated()), id: \.offset) { _, option in
                        Text(option)
                            .font(Theme.font(12, .semibold))
                            .foregroundStyle(Color.white.opacity(0.85))
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                .frame(height: 36)
            }

            FlexRow(weights: [1, 1.45]) {
                CapsuleButton(kind: .neutral, action: { model.dismissInput(sessionID: sessionID, attention) }) {
                    Text("Dismiss")
                }
                CapsuleButton(kind: .primary, action: { model.openSession(sessionID) }) {
                    Text(session?.process == nil ? "Answer in Claude Code" : "Open session")
                }
                .disabled(session?.process == nil)
            }
            .padding(.top, 12)
        }
        .padding(.top, IslandGeometry.contentTopPadding(notch: model.notch))
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .frame(width: IslandGeometry.requestWidth, alignment: .topLeading)
    }
}
