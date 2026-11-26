// OWNER: workstream C (app-ui).
import NotchAgentCore
import SwiftUI

/// The Progress view (600 x 256): avatars and tabs, "Claude ● <headline>", the step checklist and the
/// tool card. The step list fades under the glass edge at the bottom.
struct ProgressContent: View {
    let model: IslandModel

    var body: some View {
        SlowClock { now in
            let quiet = Quiet.isQuiet(model.store.sessions, now: now)
            if model.nowPlaying.isActive {
                split(quiet: quiet)
            } else if quiet {
                napping
            } else {
                claudeOnly
            }
        }
    }

    /// Nothing has run for two minutes: Claude asleep instead of stale steps.
    private var napping: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Spacer(minLength: 12)
                TabButtons()
            }
            .frame(height: 30)
            NapScene()
                .padding(.bottom, 26)
        }
        .padding(.top, IslandGeometry.contentTopPadding(notch: model.notch))
        .padding(.horizontal, 24)
        .frame(width: IslandGeometry.progressSize.width, height: IslandGeometry.progressSize.height, alignment: .top)
    }

    private var claudeOnly: some View {
        let store = model.store
        let session = model.progressSession
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
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
                WhoLine(headline: session.headline, mascot: 27)
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
        .mask(Self.fade)
    }

    /// Media playing: the player on the left, Claude's steps on their own glass card on the right.
    private func split(quiet: Bool) -> some View {
        let store = model.store
        let session = model.progressSession
        let size = IslandGeometry.splitProgressSize
        let top = IslandGeometry.contentTopPadding(notch: model.notch)
        return HStack(alignment: .top, spacing: 14) {
            MediaCard(media: model.nowPlaying, glow: model)
                .frame(width: 344)

            VStack(alignment: .leading, spacing: 0) {
                if quiet {
                    NapScene(mascot: 54)
                } else if let session {
                    // The title line carries the session avatars at its right end.
                    HStack(spacing: 10) {
                        ClaudeTitleLine(session: session, includeChat: false)
                        Spacer(minLength: 6)
                        AvatarRow(sessions: Array(store.sessions.prefix(4)), ringID: session.id) { id in
                            model.avatarClicked(id)
                        }
                    }
                    .frame(height: 32)
                    .padding(.top, 2)
                    .id(session.id)
                    // The chat name on its own line, so it is never squeezed out.
                    if let chat = ClaudeTitleLine.chat(of: session) {
                        Text(chat)
                            .font(Theme.font(14, .semibold))
                            .tracking(Theme.em(-0.012, 14))
                            .foregroundStyle(Theme.Vibe.claudeName)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.leading, 2)
                            .padding(.top, 2)
                    }
                    Spacer().frame(height: 8)
                    StepList(session: session, textColor: Theme.Vibe.step, currentColor: Theme.Vibe.stepCurrent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .mask(Self.fade)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .background(GlowCard(model: model, radius: 22, hueBase: 14, hueSpread: 36, tint: GlassCard.claude))
        }
        .padding(.top, top - 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    private static let fade = LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.8),
                                                     .init(color: .black.opacity(0.35), location: 1)],
                                             startPoint: .top, endPoint: .bottom)
}

/// The split view's title: "Claude · <agent> · <chat>", one warm gradient across the whole line. The agent is the
/// session's project folder; the chat is its title, else the latest prompt.
struct ClaudeTitleLine: View {
    let session: Session
    /// Ends the line with the chat name (the split view puts it on its own line instead).
    var includeChat = true

    /// The chat's name: its title, else the latest prompt.
    static func chat(of session: Session) -> String? {
        let c = (session.title ?? session.lastPrompt)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return c?.isEmpty == false ? c : nil
    }

    private var chat: String? { includeChat ? Self.chat(of: session) : nil }

    var body: some View {
        HStack(spacing: 9) {
            Kishu(width: 25)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("Claude")
                    .font(Theme.font(18, .bold))
                    .tracking(Theme.em(-0.022, 18))
                    .fixedSize()
                Text("·").font(Theme.font(15, .bold))
                Text(session.name)
                    .font(Theme.font(15, .bold))
                    .tracking(Theme.em(-0.015, 15))
                    .lineLimit(1)
                    .layoutPriority(1)
                if let chat {
                    Text("·").font(Theme.font(15, .bold))
                    Text(chat)
                        .font(Theme.font(14.5, .semibold))
                        .tracking(Theme.em(-0.012, 14.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .foregroundStyle(Theme.Vibe.claudeName)
        }
    }
}

/// `.steps`: orange checks for completed steps, the current step dimmed with a play icon.
struct StepList: View {
    let session: Session
    var textColor: Color = .white.opacity(0.93)
    var currentColor: Color = .white.opacity(0.55)
    @Environment(\.notchAgentRender) private var render
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
                        .foregroundStyle(row.isCurrent ? currentColor : textColor)
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
    @Environment(\.notchAgentRender) private var render

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
    @Environment(\.notchAgentRender) private var render
    @ViewBuilder var content: (Date) -> Content

    var body: some View {
        if let now = render.frozenNow {
            content(now)
        } else {
            TimelineView(.periodic(from: .now, by: 0.05)) { ctx in content(ctx.date) }
        }
    }
}
