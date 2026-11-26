// OWNER: workstream C (app-ui).
import AppKit
import SwiftUI

extension Theme {
    static let spotify = Color(hex: 0x1ED760)
}

/// Hover with Spotify active and no Claude session: the player alone.
struct MediaContent: View {
    let model: IslandModel

    var body: some View {
        MediaCard(media: model.nowPlaying, framed: false, titleTrailingInset: 58)
            // Nothing running in Claude: a tiny napping Claude beside the title.
            .overlay(alignment: .topTrailing) { MiniNap().offset(x: 8, y: -8) }
            .padding(.top, IslandGeometry.contentTopPadding(notch: model.notch) - 6)
            .padding(.horizontal, 22)
            .padding(.bottom, 16)
            .frame(width: IslandGeometry.mediaSize.width, height: IslandGeometry.mediaSize.height, alignment: .top)
    }
}

/// Collapsed while Spotify plays and Claude is quiet: the album art left of the notch, a green wave right of it.
struct CompactNowPlaying: View {
    let media: NowPlaying

    var body: some View {
        Ears {
            ArtworkView(image: media.artwork, size: 20, radius: 5)
        } right: {
            Wave(color: Theme.spotify)
        }
    }
}

/// The player: artwork, song, album, artist, a seekable progress bar and the transport controls.
/// `framed` puts it on its own glass card (the right half of the split Progress view).
struct MediaCard: View {
    let media: NowPlaying
    var framed: Bool = true
    /// Room kept clear right of the title block (for the mini nap).
    var titleTrailingInset: CGFloat = 0
    /// When set, the card's border glows where the pointer is (`GlowCard`).
    var glow: IslandModel? = nil
    @Environment(\.notchAgentRender) private var render

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let track = media.track {
                HStack(alignment: .center, spacing: 12) {
                    ArtworkView(image: media.artwork, size: 88, radius: 15)
                    // Centered over the song-length bar's text column.
                    VStack(alignment: .center, spacing: 4) {
                        Text(track.name)
                            .font(Theme.font(19, .bold))
                            .tracking(Theme.em(-0.018, 19))
                            .foregroundStyle(Theme.Vibe.songTitle)
                        if !track.album.isEmpty {
                            HStack(spacing: 5) {
                                Text("Album:").foregroundStyle(Theme.Vibe.lavenderGlow).fixedSize()
                                Text(track.album).foregroundStyle(Theme.Vibe.albumName)
                            }
                            .font(Theme.font(14, .semibold))
                        }
                        Text(track.artist)
                            .font(Theme.font(13.5, .semibold))
                            .foregroundStyle(Theme.Vibe.lavenderGlow)
                    }
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.trailing, titleTrailingInset)
                }
                Spacer(minLength: 10)
                ScrubBar(media: media)
                Spacer(minLength: 8)
                Controls(media: media)
                if let problem = media.problem {
                    Text(problem)
                        .font(Theme.font(10.5, .medium))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.top, 4)
                }
            }
        }
        .padding(framed ? 15 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            if framed {
                if let glow {
                    GlowCard(model: glow, radius: 22, hueBase: 125, hueSpread: 70, tint: GlassCard.player)
                } else {
                    GlassCard(radius: 22, tint: GlassCard.player)
                }
            }
        }
    }
}

/// A see-through glass card: no frosting (the system glass material greys out the data rain), a light ~15%
/// fill and a bright rim, so the rain still shows through behind the text.
struct GlassCard: View {
    var radius: CGFloat
    /// The fill, corner to corner (top-left to bottom-right); each color carries its own ~10-16% opacity.
    var tint: [Color] = GlassCard.neutral

    static let neutral = [Color.white.opacity(0.15), Color.white.opacity(0.11)]
    /// The player: Spotify green into rain cyan and violet.
    static let player = [Color(hex: 0x1ED760).opacity(0.17), Color(hex: 0x22E6FF).opacity(0.10),
                         Color(hex: 0x8A5CFF).opacity(0.15)]
    /// Claude: warm orange into rain pink and violet.
    static let claude = [Color(hex: 0xFF9A5C).opacity(0.17), Color(hex: 0xFF3D9A).opacity(0.10),
                         Color(hex: 0x8A5CFF).opacity(0.15)]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: tint, startPoint: .topLeading, endPoint: .bottomTrailing))
            // A soft sheen across the top, like light on glass.
            shape.fill(LinearGradient(colors: [.white.opacity(0.07), .white.opacity(0)], startPoint: .top,
                                      endPoint: UnitPoint(x: 0.5, y: 0.45)))
            // Rim light: bright along the top edge, fading down the sides.
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.06), .white.opacity(0.12)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 0.8)
        }
    }
}

/// A native port of the "spotlight card": a glass card whose border lights up around the pointer, with a soft
/// spot on the surface and a blurred halo outside. The hue drifts with the pointer's x position
/// (`hueBase` + x fraction x `hueSpread`, in degrees). Reads the pointer itself, so only this view redraws
/// as the mouse moves.
struct GlowCard: View {
    let model: IslandModel
    var radius: CGFloat
    var hueBase: Double
    var hueSpread: Double
    var tint: [Color] = GlassCard.neutral
    /// Size of the spotlight, like the component's `--size`.
    var spotlight: CGFloat = 200

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        GeometryReader { geo in
            let frame = geo.frame(in: .named(IslandCanvas.space))
            let pointer = model.pointer
            let local = pointer.map { CGPoint(x: $0.x - frame.minX, y: $0.y - frame.minY) } ?? .zero
            let center = UnitPoint(x: local.x / max(frame.width, 1), y: local.y / max(frame.height, 1))
            let xp = (pointer?.x ?? 0) / IslandGeometry.canvas.width
            let hue = ((hueBase + xp * hueSpread) / 360).truncatingRemainder(dividingBy: 1)
            let tint = Color(hue: hue, saturation: 1, brightness: 1)
            let lit = pointer != nil
            ZStack {
                GlassCard(radius: radius, tint: self.tint)
                // The spot on the surface (--bg-spot-opacity .1).
                shape.fill(RadialGradient(colors: [tint.opacity(0.12), .clear], center: center, startRadius: 0,
                                          endRadius: spotlight))
                    .opacity(lit ? 1 : 0)
                // Halo just outside the edge (the inner [data-glow], blurred).
                shape.strokeBorder(RadialGradient(colors: [tint.opacity(0.9), .clear], center: center, startRadius: 0,
                                                  endRadius: spotlight * 0.75), lineWidth: 4)
                    .blur(radius: 7)
                    .opacity(lit ? 0.7 : 0)
                // The colored border (::before) and its white-hot core (::after).
                shape.strokeBorder(RadialGradient(colors: [tint, .clear], center: center, startRadius: 0,
                                                  endRadius: spotlight * 0.75), lineWidth: 1.6)
                    .brightness(0.25)
                    .opacity(lit ? 1 : 0)
                shape.strokeBorder(RadialGradient(colors: [.white.opacity(0.95), .clear], center: center, startRadius: 0,
                                                  endRadius: spotlight * 0.5), lineWidth: 1.1)
                    .opacity(lit ? 1 : 0)
            }
            .animation(.easeOut(duration: 0.25), value: lit)
        }
        // Lifts a touch under the pointer.
        .scaleEffect(model.pointer.map { _ in 1.006 } ?? 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.55), value: model.pointer == nil)
        .allowsHitTesting(false)
    }
}

struct ArtworkView: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                // No album art (or only a browser's logo): a gradient tile in the rain's colors, never an app icon.
                ZStack {
                    LinearGradient(colors: [Color(hex: 0x8A5CFF), Color(hex: 0xFF3D9A)], startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                    RadialGradient(colors: [Color(hex: 0x22E6FF).opacity(0.55), .clear], center: .bottomLeading,
                                   startRadius: 0, endRadius: size * 0.9)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.44, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .shadow(color: .black.opacity(0.25), radius: size * 0.05)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}

/// "0:32 ━━━━━━━━ -8:59"; click to seek.
private struct ScrubBar: View {
    let media: NowPlaying

    var body: some View {
        LiveDate { now in
            let duration = media.track?.duration ?? 0
            let pos = media.position(at: now)
            let fraction = duration > 0 ? pos / duration : 0
            HStack(spacing: 9) {
                Text(Self.time(pos))
                    .frame(width: 34, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.16))
                        Capsule().fill(LinearGradient(colors: [Theme.spotify.opacity(0.8), Theme.spotify],
                                                      startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(4, geo.size.width * fraction))
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { p in
                        media.seek(toFraction: p.x / max(geo.size.width, 1))
                    }
                }
                .frame(height: 14)
                Text(duration > 0 ? "-" + Self.time(duration - pos) : "")
                    .frame(width: 40, alignment: .trailing)
            }
            .font(Theme.font(12.5, .semibold))
            .monospacedDigit()
            .foregroundStyle(Theme.Vibe.time)
        }
    }

    static func time(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded(.down)))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Shuffle, previous, play/pause, next, repeat.
private struct Controls: View {
    let media: NowPlaying

    var body: some View {
        HStack(spacing: 0) {
            ControlButton(symbol: "shuffle", size: 14, active: media.shuffling) { media.toggleShuffle() }
            Spacer(minLength: 0)
            ControlButton(symbol: "backward.end.fill", size: 17) { media.previous() }
            Spacer(minLength: 0)
            Button { media.playPause() } label: {
                ZStack {
                    Circle().fill(LinearGradient(colors: [Theme.spotify, Color(hex: 0x17B04E)],
                                                 startPoint: .top, endPoint: .bottom))
                    Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.6)
                    Image(systemName: media.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.black.opacity(0.85))
                        .offset(x: media.isPlaying ? 0 : 1.5)
                }
                .frame(width: 42, height: 42)
                .shadow(color: Theme.spotify.opacity(0.35), radius: 10, y: 2)
                .contentShape(Circle())
            }
            .buttonStyle(PressScaleStyle(scale: 0.9))
            Spacer(minLength: 0)
            ControlButton(symbol: "forward.end.fill", size: 17) { media.next() }
            Spacer(minLength: 0)
            ControlButton(symbol: "repeat", size: 14, active: media.repeating) { media.toggleRepeat() }
        }
        .padding(.horizontal, 6)
    }
}

private struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    var active: Bool = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: .semibold))
                    .foregroundStyle(active ? Theme.spotify : .white.opacity(hover ? 1 : 0.82))
                Circle().fill(active ? Theme.spotify : .clear).frame(width: 4, height: 4)
            }
            .frame(width: 34, height: 38)
            .background(Circle().fill(.white.opacity(hover ? 0.08 : 0)).frame(width: 34, height: 34).offset(y: -3))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.88))
        .onHover { hover = $0 }
    }
}

/// A hairline glass rim around the expanded island (sides and bottom), for the player's states.
struct GlassRim: View {
    let radius: CGFloat

    var body: some View {
        IslandShape(radius: radius)
            .stroke(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white.opacity(0.10), location: 0.35),
                                           .init(color: .white.opacity(0.26), location: 1)],
                                   startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
            .allowsHitTesting(false)
    }
}
