// OWNER: workstream C (app-ui).
import SwiftUI

/// A native take on the "Recursive Erosion" particle-sphere background (only its wrapper was available, not its
/// source, so this follows the name and description): a slowly turning sphere of particles that erodes in
/// bands at several scales. Eroding particles lift off the surface, swirl along it and fade, then settle back
/// as the bands drift on. Warm ivory into amber on near-black; the pointer pushes particles aside.
struct ParticleSphereView: View {
    let model: IslandModel
    /// The size this view fills.
    let size: CGSize
    /// Where this view's left edge sits within the island (for mapping the pointer), and the island's width.
    var islandOffsetX: CGFloat = 0
    var islandWidth: CGFloat? = nil
    @Environment(\.notchAgentRender) private var render

    var body: some View {
        ZStack {
            Color(hex: 0x0A0908)
            if render.animated {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                    sphere(time: ctx.date.timeIntervalSinceReferenceDate)
                }
            } else {
                sphere(time: 6)
            }
            RadialGradient(colors: [.clear, .black.opacity(0.55)], center: .center, startRadius: size.height * 0.35,
                           endRadius: max(size.width, size.height) * 0.7)
            LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.5), location: 0.16),
                                   .init(color: .clear, location: 0.32)], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func sphere(time: Double) -> some View {
        let s = IslandGeometry.expandedScale
        let originX = (IslandGeometry.canvas.width - (islandWidth ?? size.width) * s) / 2
        let pointer = model.pointer.map { CGPoint(x: ($0.x - originX) / s - islandOffsetX, y: $0.y / s) }
        return Canvas { ctx, canvasSize in
            // Bloom: the same particles, blurred, underneath, so the colors glow.
            ctx.drawLayer { bloom in
                bloom.addFilter(.blur(radius: 3))
                bloom.opacity = 0.75
                ParticleSphereField.draw(in: &bloom, size: canvasSize, time: time, pointer: pointer)
            }
            ParticleSphereField.draw(in: &ctx, size: canvasSize, time: time, pointer: pointer)
        }
    }
}

enum ParticleSphereField {
    static let count = 2600
    /// Unit vectors evenly spread over the sphere (a Fibonacci lattice), with a per-particle phase.
    static let points: [(x: Double, y: Double, z: Double, phase: Double)] = {
        let golden = Double.pi * (3 - 5.0.squareRoot())
        return (0..<count).map { i in
            let y = 1 - 2 * (Double(i) + 0.5) / Double(count)
            let r = (1 - y * y).squareRoot(), a = golden * Double(i)
            return (cos(a) * r, y, sin(a) * r, Double((i &* 2_654_435_761) % 1000) / 1000)
        }
    }()

    /// Front of the sphere, its far side, and eroding particles.
    private static let front = (r: 1.0, g: 0.9, b: 0.78)
    private static let back = (r: 1.0, g: 0.42, b: 0.26)
    private static let eroding = (r: 1.0, g: 0.24, b: 0.6)

    static func draw(in ctx: inout GraphicsContext, size: CGSize, time t: Double, pointer: CGPoint?) {
        ctx.blendMode = .plusLighter
        let cx = size.width / 2, cy = size.height * 0.56
        let radius = min(size.width, size.height) * 0.36
        let spin = t * 0.16, tilt = 0.38
        let (sy, cyw) = (sin(spin), cos(spin)), (st, ct) = (sin(tilt), cos(tilt))
        // The erosion threshold breathes, so the sphere is eaten away and rebuilt in turn.
        let threshold = 0.45 + 0.12 * sin(t * 0.21)

        // Bucket by brightness and color (front, back, eroding) so each bucket is one fill.
        let levels = 6, hues = 3
        var paths = [Path](repeating: Path(), count: levels * hues)

        for p in points {
            // Erosion: fractal noise at several scales, drifting across the surface over time.
            let n = fbm3(p.x * 1.7 + t * 0.06, p.y * 1.7 - t * 0.04, p.z * 1.7 + t * 0.05)
            let e = smoothstep(threshold, threshold + 0.16, n)
            // Eroding particles lift off and swirl along the surface (a tangent around the y axis).
            let lift = 1 + e * (0.55 + 0.35 * p.phase)
            let swirl = e * (0.5 + 0.4 * p.phase) * (1 + 0.3 * sin(t * 0.7 + p.phase * 6.28))
            var x = p.x * lift - p.z * swirl, y = p.y * lift + e * 0.18 * sin(t + p.phase * 6.28), z = p.z * lift + p.x * swirl
            // Turn the sphere, then tilt it toward the viewer.
            let rx = x * cyw + z * sy, rz = -x * sy + z * cyw
            x = rx; z = rz
            let ry = y * ct - z * st, rz2 = y * st + z * ct
            y = ry; z = rz2
            var sx = cx + x * radius, syy = cy - y * radius
            if let pt = pointer {
                let dx = sx - pt.x, dy = syy - pt.y, d2 = dx * dx + dy * dy
                if d2 < 60 * 60 && d2 > 0.01 {
                    let d = d2.squareRoot(), push = (60 - d) / 60 * 16
                    sx += dx / d * push; syy += dy / d * push
                }
            }
            let depth = (z + 1.6) / 3.2   // 0 at the back, 1 at the front
            let alpha = max(0, (0.38 + 0.62 * depth) * (1 - e * 0.55))
            guard alpha > 0.03 else { continue }
            let dot = (1.1 + 1.4 * depth) * (1 - e * 0.25)
            let level = min(levels - 1, Int(alpha * Double(levels)))
            let hue = e > 0.35 ? 2 : (depth > 0.5 ? 0 : 1)
            paths[level * hues + hue].addEllipse(in: CGRect(x: sx - dot / 2, y: syy - dot / 2, width: dot, height: dot))
        }
        for level in 0..<levels {
            let a = min(1, (Double(level) + 0.5) / Double(levels) * 1.1)
            for (hue, c) in [front, back, eroding].enumerated() {
                let path = paths[level * hues + hue]
                guard !path.isEmpty else { continue }
                ctx.fill(path, with: .color(Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: a)))
            }
        }
    }

    // MARK: Noise

    private static func hash(_ x: Int, _ y: Int, _ z: Int) -> Double {
        var n = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263 &+ z &* 1_442_695_041)
        n = (n ^ (n >> 13)) &* 1_274_126_177
        n ^= n >> 16
        return Double(n) / Double(UInt32.max)
    }

    private static func noise3(_ x: Double, _ y: Double, _ z: Double) -> Double {
        let ix = x.rounded(.down), iy = y.rounded(.down), iz = z.rounded(.down)
        var fx = x - ix, fy = y - iy, fz = z - iz
        fx = fx * fx * (3 - 2 * fx); fy = fy * fy * (3 - 2 * fy); fz = fz * fz * (3 - 2 * fz)
        let i = Int(ix), j = Int(iy), k = Int(iz)
        func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
        let x00 = lerp(hash(i, j, k), hash(i + 1, j, k), fx), x10 = lerp(hash(i, j + 1, k), hash(i + 1, j + 1, k), fx)
        let x01 = lerp(hash(i, j, k + 1), hash(i + 1, j, k + 1), fx), x11 = lerp(hash(i, j + 1, k + 1), hash(i + 1, j + 1, k + 1), fx)
        return lerp(lerp(x00, x10, fy), lerp(x01, x11, fy), fz)
    }

    /// Three octaves: the "recursive" part, so erosion bites at a coarse, a medium and a fine scale.
    private static func fbm3(_ x: Double, _ y: Double, _ z: Double) -> Double {
        var v = 0.0, a = 0.55, px = x, py = y, pz = z
        for _ in 0..<3 {
            v += a * noise3(px, py, pz)
            px = px * 2.1 + 3.1; py = py * 2.1 + 1.7; pz = pz * 2.1 + 5.3
            a *= 0.5
        }
        return v / 0.9625
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }
}
