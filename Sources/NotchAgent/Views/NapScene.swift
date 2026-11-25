// OWNER: workstream C (app-ui).
import NotchAgentCore
import SwiftUI

/// Nothing has run for a while: Progress shows Claude asleep instead of stale steps.
enum Quiet {
    /// How long every session must have been silent (and none working or waiting on you).
    static let after: TimeInterval = 2 * 60

    static func isQuiet(_ sessions: [Session], now: Date) -> Bool {
        if sessions.contains(where: { $0.status == .working || $0.status == .needsYou }) { return false }
        guard let last = sessions.map(\.lastEventAt).max() else { return true }
        return now.timeIntervalSince(last) > after
    }
}

/// Re-evaluates `content` every few seconds (frozen in snapshots), for states that change with time.
struct SlowClock<Content: View>: View {
    @Environment(\.notchAgentRender) private var render
    @ViewBuilder var content: (Date) -> Content

    var body: some View {
        if let now = render.frozenNow {
            content(now)
        } else {
            TimelineView(.periodic(from: .now, by: 5)) { ctx in content(ctx.date) }
        }
    }
}

/// The empty state: the Claude mascot asleep (eyes shut, breathing slowly), "z"s drifting up, and a line of text.
struct NapScene: View {
    var mascot: CGFloat = 58

    var body: some View {
        VStack(spacing: 12) {
            AnimationClock { t in
                ZStack(alignment: .topTrailing) {
                    SleepingClawd(width: mascot)
                        // Slow breathing: a gentle rise and fall from the feet.
                        .scaleEffect(x: 1 + 0.015 * sin(t * 2 * .pi / 3.2),
                                     y: 1 - 0.045 * (0.5 + 0.5 * sin(t * 2 * .pi / 3.2)), anchor: .bottom)
                    Snores(time: t)
                        .offset(x: mascot * 0.42, y: -mascot * 0.36)
                }
                .frame(width: mascot * 1.9, height: mascot * 1.15, alignment: .bottom)
            }
            VStack(spacing: 4) {
                Text("Nothing's running right now")
                    .font(Theme.font(15.5, .bold))
                    .tracking(Theme.em(-0.015, 15.5))
                    .foregroundStyle(Theme.Vibe.claudeName)
                Text(mascot < 50 ? "Claude is napping. Start a chat to wake it." : "Claude is curled up for a nap. Start a chat to wake it.")
                    .font(Theme.font(12.5, .semibold))
                    .foregroundStyle(Theme.Vibe.label)
            }
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The mascot with its eyes shut: the eye gaps filled, and a short dark lid line under each.
struct SleepingClawd: View {
    let width: CGFloat

    var body: some View {
        let h = (width * 13 / 18).rounded()
        let sx = width / 18, sy = h / 13
        ZStack(alignment: .topLeading) {
            ClawdShape().fill(Theme.orange)
            // Fill the open eyes (the gaps at x 5 and 12 in row 2.5).
            Rectangle().fill(Theme.orange).frame(width: 1 * sx, height: 2.5 * sy).offset(x: 5 * sx, y: 2.5 * sy)
            Rectangle().fill(Theme.orange).frame(width: 1 * sx, height: 2.5 * sy).offset(x: 12 * sx, y: 2.5 * sy)
            // Closed lids: little dark dashes.
            Capsule().fill(Color.black.opacity(0.7)).frame(width: 2.2 * sx, height: 0.55 * sy).offset(x: 4.4 * sx, y: 4.0 * sy)
            Capsule().fill(Color.black.opacity(0.7)).frame(width: 2.2 * sx, height: 0.55 * sy).offset(x: 11.4 * sx, y: 4.0 * sy)
        }
        .frame(width: width, height: h)
        .shadow(color: Theme.orange.opacity(0.35), radius: 10)
        .accessibilityLabel("Claude, asleep")
    }
}

/// The small version beside the song title: the mascot asleep with its z's, nothing else.
struct MiniNap: View {
    var body: some View {
        AnimationClock { t in
            ZStack(alignment: .topTrailing) {
                SleepingClawd(width: 32)
                    .scaleEffect(x: 1 + 0.015 * sin(t * 2 * .pi / 3.2),
                                 y: 1 - 0.05 * (0.5 + 0.5 * sin(t * 2 * .pi / 3.2)), anchor: .bottom)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                Snores(time: t)
                    .scaleEffect(0.75, anchor: .bottomLeading)
                    .offset(x: 30, y: 4)
            }
            .frame(width: 58, height: 46, alignment: .bottomLeading)
        }
        .accessibilityLabel("Nothing's running in Claude")
    }
}

/// Three "z"s rising and fading in turn.
struct Snores: View {
    let time: Double
    static let period = 2.7

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(0..<3, id: \.self) { i in
                let p = ((time / Self.period) + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                Text("z")
                    .font(.system(size: 9 + CGFloat(p) * 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.Vibe.claudeName)
                    .opacity(p < 0.15 ? p / 0.15 : 1 - (p - 0.15) / 0.85)
                    .offset(x: CGFloat(p) * 16 + CGFloat(sin(p * .pi * 2)) * 2, y: -CGFloat(p) * 24)
            }
        }
        .frame(width: 30, height: 30, alignment: .bottomLeading)
    }
}
