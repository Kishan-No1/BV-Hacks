// OWNER: workstream C (app-ui).
import NotchAgentCore
import SwiftUI

/// Colors and type from the prototype's CSS (`.nd { --orange ... }`).
enum Theme {
    static let orange = Color(hex: 0xD97757)
    static let orange2 = Color(hex: 0xE8916E)
    static let green = Color(hex: 0x30D158)
    static let amber = Color(hex: 0xFFB340)
    static let red = Color(hex: 0xFF453A)
    static let ink = Color.white
    static let ink2 = Color.white.opacity(0.55)
    static let ink3 = Color.white.opacity(0.32)
    static let card = Color.white.opacity(0.055)

    /// Text colors for the panels over the data rain: warm on Claude's card, cool on the player.
    enum Vibe {
        static let claudeName = LinearGradient(colors: [Color(hex: 0xFFC49B), Color(hex: 0xFF7FB0)],
                                               startPoint: .leading, endPoint: .trailing)
        static let step = Color(hex: 0xFFE6D8).opacity(0.94)
        static let stepCurrent = Color(hex: 0xFFB8D2).opacity(0.62)
        static let label = Color(hex: 0xB9A8FF).opacity(0.85)
        static let songTitle = LinearGradient(colors: [Color(hex: 0xB8FFD9), Color(hex: 0x7FE9FF)],
                                              startPoint: .leading, endPoint: .trailing)
        /// "Album:" and the artist: lavender into rain pink.
        static let lavenderGlow = LinearGradient(colors: [Color(hex: 0xC9B8FF), Color(hex: 0xFF9AD5)],
                                                 startPoint: .leading, endPoint: .trailing)
        /// The album name: green into rain cyan.
        static let albumName = LinearGradient(colors: [Color(hex: 0x5CFF9D), Color(hex: 0x22E6FF)],
                                              startPoint: .leading, endPoint: .trailing)
        static let time = Color(hex: 0xA9E8F2).opacity(0.7)
    }

    /// system-ui (SF Pro).
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    /// ui-monospace (SF Mono), the prototype's `<code>`.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// CSS letter-spacing in em -> SwiftUI tracking in points.
    static func em(_ em: CGFloat, _ size: CGFloat) -> CGFloat { em * size }

    static func dot(for status: SessionStatus) -> Color? {
        switch status {
        case .working: return orange
        case .needsYou: return amber
        case .done: return green
        case .idle: return nil
        }
    }

    static func color(for level: RiskLevel) -> Color {
        switch level {
        case .low: return green
        case .review: return amber
        case .high: return red
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Text with `backtick` spans in SF Mono.
struct InlineCodeText: View {
    let text: String
    var font: Font
    var codeFont: Font
    var tracking: CGFloat = 0

    var body: some View {
        Text(Self.attributed(text, font: font, codeFont: codeFont))
            .tracking(tracking)
    }

    static func attributed(_ text: String, font: Font, codeFont: Font) -> AttributedString {
        var out = AttributedString()
        for seg in InlineCode.segments(text) {
            var a = AttributedString(seg.text)
            a.font = seg.isCode ? codeFont : font
            out += a
        }
        return out
    }
}

/// The card surface: `.card { background: rgba(255,255,255,.055); border-radius: 16px; inset highlights }`.
struct CardBackground: View {
    var radius: CGFloat = 16

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.fill(Theme.card)
            .overlay(shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5))
            .overlay(alignment: .top) {
                // inset 0 1px 0 rgba(255,255,255,.09)
                shape.stroke(Color.white.opacity(0.09), lineWidth: 2)
                    .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.12)))
                    .clipShape(shape)
            }
    }
}

extension View {
    /// Cuts `mask` out of this view (used so the glow never shows through the island itself, like a CSS box-shadow).
    func reverseMask<Mask: View>(alignment: Alignment = .top, @ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: alignment) {
                    mask().blendMode(.destinationOut)
                }
                .compositingGroup()
        }
    }
}
