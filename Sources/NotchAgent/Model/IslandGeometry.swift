// OWNER: workstream C (app-ui).
import CoreGraphics
import Foundation
import NotchAgentCore
import SwiftUI

/// The notch the island hugs: the real one, or a simulated 185 x 32 notch on screens without one.
struct NotchMetrics: Equatable {
    var width: CGFloat
    var height: CGFloat
    /// Horizontal center of the notch in screen coordinates.
    var centerX: CGFloat
    var hasHardwareNotch: Bool

    static let simulated = NotchMetrics(width: 185, height: 32, centerX: 0, hasHardwareNotch: false)

    /// notch width = frame.width - auxiliaryTopLeftArea.width - auxiliaryTopRightArea.width; height = safeAreaInsets.top.
    static func from(screenFrame: CGRect, safeAreaTop: CGFloat, auxLeftWidth: CGFloat?, auxRightWidth: CGFloat?) -> NotchMetrics {
        if safeAreaTop > 0, let l = auxLeftWidth, let r = auxRightWidth {
            let w = screenFrame.width - l - r
            if w > 40 {
                return NotchMetrics(width: w, height: safeAreaTop, centerX: screenFrame.minX + l + w / 2, hasHardwareNotch: true)
            }
        }
        return NotchMetrics(width: simulated.width, height: simulated.height, centerX: screenFrame.midX, hasHardwareNotch: false)
    }
}

/// Sizes from the prototype (`S` table in docs/design/prototype.html).
enum IslandGeometry {
    /// Fixed panel canvas: big enough for the largest island plus its glow, so the window never resizes.
    static let canvas = CGSize(width: 760, height: 420)
    /// The outward curves where the island meets the top edge.
    static let shoulder: CGFloat = 10
    static let expandedRadius: CGFloat = 34
    static let compactRadius: CGFloat = 10
    /// The open island is drawn at this scale (layout sizes below stay in design points). The collapsed island
    /// keeps full size so it still covers the hardware notch.
    static let expandedScale: CGFloat = 0.88

    static func visualSize(_ size: CGSize, _ state: IslandState) -> CGSize {
        state.isExpanded ? CGSize(width: size.width * expandedScale, height: size.height * expandedScale) : size
    }

    static let progressSize = CGSize(width: 600, height: 256)
    /// Progress with Spotify active: Claude on the left half, the player on the right.
    static let splitProgressSize = CGSize(width: 730, height: 282)
    /// Where the split view's two backdrops meet: the middle of the gap between the player and Claude cards.
    static let splitSeam: CGFloat = 367
    /// The player alone (hover with no Claude session).
    static let mediaSize = CGSize(width: 440, height: 246)
    static let requestWidth: CGFloat = 560
    /// Used until a request card has been measured.
    static let fallbackRequestHeight: CGFloat = 236

    /// Extra width over the notch for compact states (prototype: notch 185 -> working 272, done 310, allowed 290).
    static func compactExtraWidth(for kind: Toast.Kind) -> CGFloat {
        switch kind {
        case .done: return 125
        case .allowed, .denied: return 105
        case .autoAllowed: return 145
        }
    }

    /// Height of the "needs your input" card: header, title, detail card, optional options row, buttons.
    static func inputHeight(_ a: Attention, notch: NotchMetrics) -> CGFloat {
        let base = contentTopPadding(notch: notch) + 30 + 40 + 56 + 46 + 18
        return base + (a.options.isEmpty ? 0 : 36)
    }

    static func size(for state: IslandState, notch: NotchMetrics, requestHeight: CGFloat? = nil, split: Bool = false) -> CGSize {
        switch state {
        case .idle: return CGSize(width: notch.width, height: notch.height)
        case .working, .attention, .nowPlaying: return CGSize(width: notch.width + 87, height: notch.height)
        case .toast(let k): return CGSize(width: notch.width + compactExtraWidth(for: k), height: notch.height)
        case .progress: return split ? splitProgressSize : progressSize
        case .media: return mediaSize
        case .request: return CGSize(width: requestWidth, height: requestHeight ?? fallbackRequestHeight)
        case .input(_, let a): return CGSize(width: requestWidth, height: inputHeight(a, notch: notch))
        case .composer(let layout): return CGSize(width: requestWidth, height: notch.height + layout.bodyHeight)
        }
    }

    static func cornerRadius(for state: IslandState) -> CGFloat {
        state.isExpanded ? expandedRadius : compactRadius
    }

    /// Top padding of expanded content: the notch height plus 12 (prototype `.xp { padding-top: 44px }`).
    static func contentTopPadding(notch: NotchMetrics) -> CGFloat { notch.height + 12 }

    /// The panel frame: top center of the screen, fixed canvas size.
    static func panelFrame(screenFrame: CGRect, centerX: CGFloat) -> CGRect {
        CGRect(x: (centerX - canvas.width / 2).rounded(), y: screenFrame.maxY - canvas.height,
               width: canvas.width, height: canvas.height)
    }

    /// The island's clickable area in screen coordinates (the island plus its shoulders).
    static func hitRect(islandSize: CGSize, panelFrame: CGRect) -> CGRect {
        CGRect(x: panelFrame.midX - islandSize.width / 2 - shoulder, y: panelFrame.maxY - islandSize.height,
               width: islandSize.width + shoulder * 2, height: islandSize.height)
    }
}

/// Which spring a size change uses (prototype `OPEN`, `NUDGE`, `CLOSE`).
enum IslandMotion: Equatable {
    /// `reveal`: a hover-open, without overshoot. `open`: a pop-up (request, question), with a little bounce.
    case open, reveal, nudge, close

    static func kind(from: IslandState, to: IslandState, fromSize: CGSize, toSize: CGSize) -> IslandMotion {
        if to.isExpanded { return to == .progress || to == .media ? .reveal : .open }
        return toSize.width * toSize.height > fromSize.width * fromSize.height ? .nudge : .close
    }

    var animation: Animation {
        switch self {
        // A little overshoot: the island lands like jelly (the wobble itself is `Jelly`).
        case .open: return .spring(response: 0.52, dampingFraction: 0.68)
        // Unhurried: the island glides open under the pointer.
        case .reveal: return .spring(response: 0.78, dampingFraction: 0.95)
        case .nudge: return .spring(response: 0.42, dampingFraction: 0.7)
        // Unhurried, so the island settles back instead of snapping shut.
        case .close: return .spring(response: 0.65, dampingFraction: 1.0)
        }
    }
}

/// Hover timing from the prototype: open Progress after 120 ms, close 220 ms after the pointer leaves.
enum HoverTiming {
    static let openDelay: TimeInterval = 0.12
    /// The pointer must be off the island this long before it retracts.
    static let closeDelay: TimeInterval = 0.5
}
