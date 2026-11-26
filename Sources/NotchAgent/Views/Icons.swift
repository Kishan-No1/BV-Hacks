// OWNER: workstream C (app-ui).
import SwiftUI

/// Kishu, the mascot shown for Claude everywhere: a plush dog (peach fur, floppy ears, happy closed eyes, a
/// blue collar and his red-and-white striped shirt), drawn on the old Clawd mascot's 18 x 13 grid so every
/// layout and the nightcap line up.
struct Kishu: View {
    var width: CGFloat = 20
    /// Wears the holiday nightcap: every mascot does, everywhere (see Nightcap).
    var festive: Bool = true

    var body: some View {
        KishuSprite(width: width)
            .overlay(alignment: .topLeading) {
                if festive { Nightcap(width: width) }
            }
            .accessibilityLabel("Kishu")
    }
}

/// Kishu in pixels: head, collar and the top of his shirt (18 x 13). His colors were picked from a photo of the
/// plush he is based on.
struct KishuSprite: View {
    var width: CGFloat
    var asleep = false

    static let awake = [
        "....pppppppppp....",
        "..pppppppppppppp..",
        ".EEppppppppppppEE.",
        "EEEppppppppppppEEE",
        "EEEppKppppppKppEEE",
        "EEEpKpKppppKpKpEEE",
        "EEEpppppNNpppppEEE",
        "EEEppppMppMppppEEE",
        ".EEpppppMMpppppEE.",
        ".EE.pppppppppp.EE.",
        "....BBBBBBBBBB....",
        "..ppRRRRRRRRRRpp..",
        "..ppWWWWYYWWWWpp..",
    ]
    /// Asleep: the happy arcs become flat lids.
    static let sleeping: [String] = {
        var rows = awake
        rows[4] = "EEEppppppppppppEEE"
        rows[5] = "EEEpKKKppppKKKpEEE"
        return rows
    }()
    static let colors: [Character: Color] = [
        "p": Color(hex: 0xFECEAF), "E": Color(hex: 0xD1A08A), "K": Color(hex: 0x281A1C), "N": Color(hex: 0x161214),
        "M": Color(hex: 0x462A28), "B": Color(hex: 0x2A458B), "R": Color(hex: 0xDA3F3C), "W": Color(hex: 0xFAE6DB),
        "Y": Color(hex: 0xE5B175),
    ]
    /// The face's pixels: left as holes in one-color versions (the menu-bar icon).
    static let face: Set<Character> = ["K", "N", "M"]

    var body: some View {
        let h = (width * 13 / 18).rounded()
        let rows = asleep ? Self.sleeping : Self.awake
        Canvas { ctx, size in
            let sx = size.width / 18, sy = size.height / 13
            for (y, line) in rows.enumerated() {
                for (x, ch) in line.enumerated() {
                    guard let c = Self.colors[ch] else { continue }
                    // Slight overlap so neighbouring pixels never show hairline seams.
                    ctx.fill(Path(CGRect(x: CGFloat(x) * sx, y: CGFloat(y) * sy, width: sx + 0.3, height: sy + 0.3)), with: .color(c))
                }
            }
        }
        .frame(width: width, height: h)
    }
}

/// The prototype's inline SVG icons (24 x 24 viewBox), ported to paths.
enum IconPath {
    static func scaled(_ rect: CGRect, _ build: (inout Path, (CGFloat, CGFloat) -> CGPoint) -> Void) -> Path {
        let s = min(rect.width, rect.height) / 24
        let ox = rect.minX + (rect.width - 24 * s) / 2, oy = rect.minY + (rect.height - 24 * s) / 2
        var p = Path()
        build(&p) { x, y in CGPoint(x: ox + x * s, y: oy + y * s) }
        return p
    }
}

/// `I.check` / `ok`: M4.5 12.5 l5 5 L19.5 6.5 (stroke 3).
struct CheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        IconPath.scaled(rect) { p, pt in
            p.move(to: pt(4.5, 12.5)); p.addLine(to: pt(9.5, 17.5)); p.addLine(to: pt(19.5, 6.5))
        }
    }
}

struct CheckIcon: View {
    var size: CGFloat = 14
    var color: Color = Theme.orange
    var body: some View {
        CheckShape()
            .stroke(color, style: StrokeStyle(lineWidth: 3 * size / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

/// `I.play` (filled).
struct PlayShape: Shape {
    func path(in rect: CGRect) -> Path {
        IconPath.scaled(rect) { p, pt in
            p.move(to: pt(7, 4.8))
            p.addLine(to: pt(7, 19.2))
            p.addCurve(to: pt(8.6, 20.0), control1: pt(7, 20.0), control2: pt(7.9, 20.5))
            p.addLine(to: pt(19.6, 12.8))
            p.addCurve(to: pt(19.6, 11.2), control1: pt(20.2, 12.4), control2: pt(20.2, 11.6))
            p.addLine(to: pt(8.6, 4.0))
            p.addCurve(to: pt(7, 4.8), control1: pt(7.9, 3.5), control2: pt(7, 4))
            p.closeSubpath()
        }
    }
}

/// `I.doc` (filled, even-odd: folded corner and two text lines are holes).
struct DocShape: Shape {
    func path(in rect: CGRect) -> Path {
        IconPath.scaled(rect) { p, pt in
            let k: CGFloat = 0.5523 * 2
            p.move(to: pt(6, 2)); p.addLine(to: pt(14, 2)); p.addLine(to: pt(20, 8)); p.addLine(to: pt(20, 20))
            p.addCurve(to: pt(18, 22), control1: pt(20, 20 + k), control2: pt(18 + k, 22))
            p.addLine(to: pt(6, 22))
            p.addCurve(to: pt(4, 20), control1: pt(6 - k, 22), control2: pt(4, 20 + k))
            p.addLine(to: pt(4, 4))
            p.addCurve(to: pt(6, 2), control1: pt(4, 4 - k), control2: pt(6 - k, 2))
            p.closeSubpath()
            p.move(to: pt(13, 3.5)); p.addLine(to: pt(13, 9)); p.addLine(to: pt(18.5, 9)); p.closeSubpath()
            p.addRect(CGRect(origin: pt(8, 13), size: CGSize(width: pt(16, 0).x - pt(8, 0).x, height: pt(0, 14.6).y - pt(0, 13).y)))
            p.addRect(CGRect(origin: pt(8, 17), size: CGSize(width: pt(16, 0).x - pt(8, 0).x, height: pt(0, 18.6).y - pt(0, 17).y)))
        }
    }
}

/// `I.list` (stroke 2): a checked box, a circle, two lines.
struct ListShape: Shape {
    func path(in rect: CGRect) -> Path {
        IconPath.scaled(rect) { p, pt in
            let o = pt(3, 4), e = pt(9, 10)
            p.addRoundedRect(in: CGRect(x: o.x, y: o.y, width: e.x - o.x, height: e.y - o.y),
                             cornerSize: CGSize(width: (e.x - o.x) * 1.6 / 6, height: (e.x - o.x) * 1.6 / 6))
            p.move(to: pt(4.6, 7)); p.addLine(to: pt(5.7, 8.1)); p.addLine(to: pt(7.6, 6))
            let c = pt(6, 17), r = pt(9, 17).x - c.x
            p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            p.move(to: pt(13, 7)); p.addLine(to: pt(21, 7))
            p.move(to: pt(13, 17)); p.addLine(to: pt(21, 17))
        }
    }
}

/// `I.shield` (stroke 2).
struct ShieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        IconPath.scaled(rect) { p, pt in
            p.move(to: pt(12, 3)); p.addLine(to: pt(19.5, 6)); p.addLine(to: pt(19.5, 11.5))
            p.addCurve(to: pt(12, 21), control1: pt(19.5, 16.1), control2: pt(16.3, 19.8))
            p.addCurve(to: pt(4.5, 11.5), control1: pt(7.7, 19.8), control2: pt(4.5, 16.1))
            p.addLine(to: pt(4.5, 6)); p.closeSubpath()
            p.move(to: pt(9, 12)); p.addLine(to: pt(11, 14)); p.addLine(to: pt(15, 10))
        }
    }
}

struct StrokeIcon<S: Shape>: View {
    let shape: S
    var size: CGFloat
    var color: Color
    var body: some View {
        shape
            .stroke(color, style: StrokeStyle(lineWidth: 2 * size / 24, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
    }
}

/// The red ✕ for failed steps.
struct CrossShape: Shape {
    func path(in rect: CGRect) -> Path {
        IconPath.scaled(rect) { p, pt in
            p.move(to: pt(6, 6)); p.addLine(to: pt(18, 18))
            p.move(to: pt(18, 6)); p.addLine(to: pt(6, 18))
        }
    }
}
