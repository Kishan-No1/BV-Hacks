// OWNER: workstream C (app-ui).
import NodCore
import SwiftUI

/// `.who`: mascot, "Claude", orange dot, the session headline in orange2.
struct WhoLine: View {
    let headline: String
    var clawd: CGFloat = 24

    var body: some View {
        HStack(spacing: 10) {
            Clawd(width: clawd)
            Text("Claude")
                .font(Theme.font(18, .bold))
                .tracking(Theme.em(-0.022, 18))
                .foregroundStyle(Theme.ink)
                .fixedSize()
            Circle().fill(Theme.orange).frame(width: 6, height: 6)
            Text(headline)
                .font(Theme.font(14.5, .semibold))
                .tracking(Theme.em(-0.012, 14.5))
                .foregroundStyle(Theme.orange2)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// `.glassy` shadows shared by avatars and tabs.
private struct Glassy: ViewModifier {
    func body(content: Content) -> some View {
        content
            .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
            .overlay(
                Circle().stroke(Color.white.opacity(0.16), lineWidth: 2)
                    .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.15)))
                    .clipShape(Circle())
            )
            .shadow(color: .black.opacity(0.8), radius: 3, y: 3)
    }
}

/// `.av`: 28 pt session avatar with a status dot; `.on` adds the orange ring.
struct Avatar: View {
    let session: Session
    let isOn: Bool

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: isOn ? [Color(hex: 0x3A2620), Color(hex: 0x23160F)]
                                                      : [Color(hex: 0x2A2A2E), Color(hex: 0x18181B)],
                                         startPoint: .top, endPoint: .bottom))
            Clawd(width: 15)
        }
        .frame(width: 28, height: 28)
        .modifier(Glassy())
        .overlay {
            if isOn { Circle().strokeBorder(Theme.orange.opacity(0.8), lineWidth: 1.5).padding(-1.5) }
        }
        .overlay(alignment: .topTrailing) {
            if let dot = Theme.dot(for: session.status) {
                ZStack {
                    Circle().fill(Color.black).frame(width: 11, height: 11)
                    Circle().fill(dot).frame(width: 7, height: 7)
                }
                .offset(x: 3, y: -3)
            }
        }
        .help(session.headline)
    }
}

/// `.avs`: one avatar per session (first-seen order).
struct AvatarRow: View {
    let sessions: [Session]
    let ringID: String?
    var onSelect: ((String) -> Void)?

    static let maxShown = 8

    var body: some View {
        HStack(spacing: 5) {
            ForEach(sessions.prefix(Self.maxShown)) { s in
                if let onSelect {
                    Button { onSelect(s.id) } label: { Avatar(session: s, isOn: s.id == ringID) }
                        .buttonStyle(PressScaleStyle(scale: 0.92))
                } else {
                    Avatar(session: s, isOn: s.id == ringID)
                }
            }
        }
        .fixedSize()
    }
}

/// `.tabs`: Progress (on, green) and Rules.
struct TabButtons: View {
    var body: some View {
        HStack(spacing: 7) {
            tab(on: true) { StrokeIcon(shape: ListShape(), size: 16, color: Theme.green) }
            tab(on: false) { StrokeIcon(shape: ShieldShape(), size: 16, color: .white.opacity(0.78)) }
        }
        .fixedSize()
    }

    private func tab<C: View>(on: Bool, @ViewBuilder _ icon: () -> C) -> some View {
        ZStack {
            Circle().fill(LinearGradient(colors: on ? [Theme.green.opacity(0.34), Theme.green.opacity(0.16)]
                                                    : [.white.opacity(0.16), .white.opacity(0.07)],
                                         startPoint: .top, endPoint: .bottom))
            icon()
        }
        .frame(width: 30, height: 30)
        .modifier(Glassy())
    }
}

/// `.pill`: "Low risk" / "Review" / "High risk".
struct RiskPill: View {
    let level: RiskLevel

    var body: some View {
        let c = Theme.color(for: level)
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(level.label).font(Theme.font(11.5, .bold))
        }
        .foregroundStyle(c)
        .padding(.vertical, 4)
        .padding(.leading, 8)
        .padding(.trailing, 9)
        .background(Capsule().fill(c.opacity(level == .high ? 0.17 : 0.14)))
        .fixedSize()
    }
}

/// `.chip`: red reason chips for high risk.
struct ReasonChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.font(11.5, .semibold))
            .foregroundStyle(Color(hex: 0xFFB3AD))
            .padding(.vertical, 4)
            .padding(.horizontal, 9)
            .background(Capsule().fill(Theme.red.opacity(0.10)))
            .overlay(Capsule().strokeBorder(Theme.red.opacity(0.25), lineWidth: 0.5))
            .fixedSize()
    }
}

struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.965
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Liquid-glass buttons

enum CapsuleKind {
    case neutral   // .btn
    case primary   // .btn.pri (white)
    case red       // .btn.red
    case ghost     // .btn.ghost
}

/// `.kb`: the ⌥↵ / ⌥⌫ key hint.
struct KeyHint: View {
    let text: String
    let onPrimary: Bool
    var body: some View {
        Text(text)
            .font(Theme.font(10.5, .semibold))
            .padding(.vertical, 3)
            .padding(.horizontal, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(onPrimary ? Color.black.opacity(0.08) : Color.white.opacity(0.14)))
            .opacity(0.6)
            .fixedSize()
    }
}

/// The capsule surface for each button kind (prototype `.btn` gradients and inset highlights).
struct CapsuleSurface: View {
    let kind: CapsuleKind
    @Environment(\.nodRender) private var render

    var body: some View {
        let capsule = Capsule(style: .continuous)
        ZStack {
            if render.nativeGlass && (kind == .neutral || kind == .ghost) {
                capsule.fill(Color.clear).glassEffect(.clear, in: capsule)
            }
            capsule.fill(fill)
            // ::before sheen on the top half.
            capsule.fill(LinearGradient(colors: [.white.opacity(sheen), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                .frame(height: 15)
                .padding(.horizontal, 8)
                .padding(.top, 1)
                .frame(maxHeight: .infinity, alignment: .top)
            capsule.strokeBorder(Color.white.opacity(ring), lineWidth: 0.5)
            // inset 0 1px 0 (top highlight)
            capsule.stroke(Color.white.opacity(topHighlight), lineWidth: 2)
                .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.2)))
                .clipShape(capsule)
            if kind == .primary || kind == .red {
                // inset 0 -2px 3-4px rgba(0,0,0,.10-.16)
                capsule.stroke(Color.black.opacity(kind == .red ? 0.16 : 0.10), lineWidth: 4)
                    .mask(LinearGradient(colors: [.clear, .white], startPoint: UnitPoint(x: 0.5, y: 0.75), endPoint: .bottom))
                    .clipShape(capsule)
                    .blur(radius: 1)
            }
        }
        .shadow(color: shadowColor, radius: shadowRadius, y: shadowY)
    }

    private var fill: LinearGradient {
        switch kind {
        case .neutral:
            return LinearGradient(stops: [.init(color: .white.opacity(0.17), location: 0), .init(color: .white.opacity(0.07), location: 0.55),
                                          .init(color: .white.opacity(0.10), location: 1)], startPoint: .top, endPoint: .bottom)
        case .primary:
            return LinearGradient(stops: [.init(color: .white, location: 0), .init(color: Color(hex: 0xF1F1F4), location: 0.55),
                                          .init(color: Color(hex: 0xDCDCE2), location: 1)], startPoint: .top, endPoint: .bottom)
        case .red:
            return LinearGradient(stops: [.init(color: Color(hex: 0xFF6A60), location: 0), .init(color: Color(hex: 0xFF453A), location: 0.55),
                                          .init(color: Color(hex: 0xE2382E), location: 1)], startPoint: .top, endPoint: .bottom)
        case .ghost:
            return LinearGradient(colors: [.white.opacity(0.08), .white.opacity(0.03)], startPoint: .top, endPoint: .bottom)
        }
    }

    private var sheen: Double {
        switch kind {
        case .primary: return 0.9
        case .red: return 0.22
        case .neutral: return 0.22
        case .ghost: return 0.12
        }
    }

    private var ring: Double { kind == .primary ? 0.9 : kind == .red ? 0.25 : 0.16 }
    private var topHighlight: Double { kind == .primary ? 1 : kind == .red ? 0.45 : 0.30 }
    private var shadowColor: Color {
        switch kind {
        case .primary: return .white.opacity(0.22)
        case .red: return Theme.red.opacity(0.6)
        default: return .black.opacity(0.7)
        }
    }
    private var shadowRadius: CGFloat { kind == .red ? 8 : 6 }
    private var shadowY: CGFloat { kind == .red ? 6 : 5 }
}

/// A 34 pt glass capsule button with a label and an optional key hint.
struct CapsuleButton<Label: View>: View {
    let kind: CapsuleKind
    var keyHint: String?
    let action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                label()
                if let keyHint { KeyHint(text: keyHint, onPrimary: kind == .primary) }
            }
            .font(Theme.font(13.5, kind == .ghost ? .medium : .semibold))
            .tracking(Theme.em(-0.01, 13.5))
            .foregroundStyle(kind == .primary ? Color.black : kind == .ghost ? Color.white.opacity(0.82) : Color.white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(CapsuleSurface(kind: kind))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle())
    }
}

/// "Hold to allow": a red fill grows over 0.9 s while pressed and resets on release (prototype `data-a="hold"`).
struct HoldToAllowButton: View {
    static let holdDuration: TimeInterval = 0.9
    let onComplete: () -> Void
    @State private var progress: CGFloat = 0
    @State private var fired = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                CapsuleSurface(kind: .neutral)
                LinearGradient(colors: [Color(hex: 0xFF6A60, opacity: 0.85), Color(hex: 0xE2382E, opacity: 0.85)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: geo.size.width * progress)
                    .clipShape(Capsule(style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipShape(Capsule(style: .continuous))
                Text("Hold to allow")
                    .font(Theme.font(13.5, .semibold))
                    .tracking(Theme.em(-0.01, 13.5))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 34)
        .contentShape(Capsule())
        .onLongPressGesture(minimumDuration: Self.holdDuration, maximumDistance: 60) {
            guard !fired else { return }
            fired = true
            Log.debug("hold-to-allow: completed")
            onComplete()
        } onPressingChanged: { pressing in
            if pressing {
                fired = false
                var t = Transaction(); t.disablesAnimations = true
                withTransaction(t) { progress = 0 }
                withAnimation(.linear(duration: Self.holdDuration)) { progress = 1 }
            } else if !fired {
                withAnimation(.timingCurve(0.2, 0.9, 0.25, 1, duration: 0.35)) { progress = 0 }
            }
        }
        .accessibilityLabel("Hold to allow")
        .accessibilityAddTraits(.isButton)
    }
}

/// Lays out buttons with CSS flex weights (`.btn { flex: 1 }`, `.btn.wide { flex: 1.45 }`), gap 8.
struct FlexRow: Layout {
    var weights: [CGFloat]
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 512
        let h = subviews.map { $0.sizeThatFits(ProposedViewSize(width: 100, height: nil)).height }.max() ?? 0
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let n = subviews.count
        guard n > 0 else { return }
        let ws = (0..<n).map { $0 < weights.count ? weights[$0] : 1 }
        let total = ws.reduce(0, +)
        let avail = bounds.width - spacing * CGFloat(n - 1)
        var x = bounds.minX
        for (i, sv) in subviews.enumerated() {
            let w = avail * ws[i] / total
            sv.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w + spacing
        }
    }
}
