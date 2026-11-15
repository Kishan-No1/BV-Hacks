// OWNER: workstream C (app-ui).
import NodCore
import SwiftUI

/// The Progress view (600 x 256): header with avatars and tabs, "Claude ● <headline>", the step checklist and the
/// tool card. The step list fades under the glass edge at the bottom.
struct ProgressContent: View {
    let model: IslandModel

    var body: some View {
        let store = model.store
        let session = model.progressSession
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 9) {
                    StrokeIcon(shape: ListShape(), size: 17, color: Theme.ink2)
                    Text("Progress")
                        .font(Theme.font(14.5, .semibold))
                        .tracking(Theme.em(-0.01, 14.5))
                        .foregroundStyle(Theme.ink2)
                }
                Spacer(minLength: 12)
                HStack(spacing: 16) {
                    AvatarRow(sessions: store.sessions, ringID: session?.id) { id in
                        model.avatarClicked(id)
                    }
                    TabButtons()
                }
            }
            .frame(height: 30)

            if let session {
                WhoLine(headline: session.headline, clawd: 24)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                    .id(session.id)

                HStack(alignment: .top, spacing: 18) {
                    StepList(session: session)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ToolCard(session: session)
                        .frame(width: 214)
                        .padding(.top, 6)
                }
            }
        }
        .padding(.top, IslandGeometry.contentTopPadding(notch: model.notch))
        .padding(.horizontal, 24)
        .frame(width: IslandGeometry.progressSize.width, height: IslandGeometry.progressSize.height, alignment: .top)
        // "the step list fades under the bottom edge"
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.8),
                                     .init(color: .black.opacity(0.35), location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }
}

/// `.steps`: orange checks for completed steps, the current step dimmed with a play icon.
struct StepList: View {
    let session: Session
    @Environment(\.nodRender) private var render
    @State private var shown = false

    /// Rows that fit above the bottom edge; older steps scroll off the top.
    static let visibleRows = 5

    private struct Row: Identifiable {
        var id: String
        var text: String
        var isCurrent: Bool
        var failed: Bool
    }

    private var rows: [Row] {
        let hasCurrent = session.currentStep != nil
        let completed = session.steps.suffix(hasCurrent ? Self.visibleRows - 1 : Self.visibleRows)
        var rows = completed.map { Row(id: $0.id.uuidString, text: $0.text, isCurrent: false, failed: $0.failed) }
        if let now = session.currentStep {
            rows.append(Row(id: "now-\(session.currentTool?.startedAt.timeIntervalSinceReferenceDate ?? 0)", text: now, isCurrent: true, failed: false))
        }
        if rows.isEmpty {
            let placeholder = session.status == .idle ? "Waiting for a prompt" : "Thinking…"
            rows.append(Row(id: "placeholder", text: placeholder, isCurrent: true, failed: false))
        }
        return rows
    }

    var body: some View {
        let visible = shown || !render.animated
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                HStack(spacing: 12) {
                    Group {
                        if row.isCurrent {
                            PlayShape().fill(Theme.orange)
                        } else if row.failed {
                            CrossShape().stroke(Theme.red, style: StrokeStyle(lineWidth: 2.5 * 14 / 24, lineCap: .round))
                        } else {
                            CheckShape().stroke(Theme.orange, style: StrokeStyle(lineWidth: 3 * 14 / 24, lineCap: .round, lineJoin: .round))
                        }
                    }
                    .frame(width: 14, height: 14)
                    InlineCodeText(text: row.text, font: Theme.font(14, .semibold), codeFont: Theme.mono(12.5, .semibold),
                                   tracking: Theme.em(-0.012, 14))
                        .foregroundStyle(row.isCurrent ? Color.white.opacity(0.55) : Color.white.opacity(0.93))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(height: 25)
                // @keyframes rise { from { opacity:0; transform: translateY(4px) } }, staggered 60 + i * 45 ms
                .opacity(visible ? 1 : 0)
                .offset(y: visible ? 0 : 4)
                .animation(.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.45).delay(0.06 + Double(i) * 0.045), value: visible)
            }
        }
        .animation(.easeOut(duration: 0.25), value: rows.map(\.id))
        .onAppear { shown = true }
    }
}

/// `.card.tool`: path, live "N.NN seconds" counter and bar; or the green Finished card.
struct ToolCard: View {
    let session: Session
    @Environment(\.nodRender) private var render

    var body: some View {
        Group {
            if session.status == .done {
                finished
            } else if let tool = session.currentTool {
                running(label: tool.label, since: tool.startedAt, icon: true)
            } else if session.status == .working || session.status == .needsYou {
                running(label: session.status == .needsYou ? "Waiting for you" : "Thinking…",
                        since: session.steps.last?.at ?? session.turnStartedAt ?? session.lastEventAt, icon: false)
            } else {
                idle
            }
        }
        .padding(EdgeInsets(top: 12, leading: 14, bottom: 14, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground())
    }

    private func running(label: String, since: Date, icon: Bool) -> some View {
        LiveDate { now in
            let t = now.timeIntervalSince(since)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    if icon { DocShape().fill(Theme.orange2, style: FillStyle(eoFill: true)).frame(width: 13, height: 13) }
                    Text(label)
                        .font(Theme.mono(12.5, .bold))
                        .foregroundStyle(Theme.orange2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(Format.seconds(t))
                    .font(Theme.font(13, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink2)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                ToolBar(fraction: Format.toolBarFraction(elapsed: t), color: Theme.orange)
            }
        }
    }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                CheckIcon(size: 13, color: Theme.green)
                Text("Finished").font(Theme.font(12.5, .bold)).foregroundStyle(Theme.green)
            }
            Text(Format.finishedSummary(session))
                .font(Theme.font(13, .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .padding(.top, 6)
                .padding(.bottom, 10)
            ToolBar(fraction: 1, color: Theme.green)
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Ready").font(Theme.font(12.5, .bold)).foregroundStyle(Theme.ink2)
            Text("Waiting for a prompt")
                .font(Theme.font(13, .semibold))
                .foregroundStyle(Theme.ink3)
                .padding(.top, 6)
                .padding(.bottom, 10)
            ToolBar(fraction: 0, color: Theme.orange)
        }
    }
}

/// `.bar2`: 4 pt track with a fill.
struct ToolBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.18))
                Capsule().fill(color).frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 4)
    }
}

/// A live clock for counters (20 Hz), frozen in snapshots.
struct LiveDate<Content: View>: View {
    @Environment(\.nodRender) private var render
    @ViewBuilder var content: (Date) -> Content

    var body: some View {
        if let now = render.frozenNow {
            content(now)
        } else {
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in content(ctx.date) }
        }
    }
}
