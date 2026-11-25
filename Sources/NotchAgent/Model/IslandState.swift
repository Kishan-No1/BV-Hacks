// OWNER: workstream C (app-ui).
import Foundation
import NotchAgentCore

/// What the island shows. Derived by a pure function from the store snapshot, hover and the visible toast.
enum IslandState: Equatable {
    case idle
    case working
    case attention
    case progress
    case request(PendingRequest)
    /// Claude waits on the user in its own UI (a question, a plan, its permission dialog). Pops open.
    case input(sessionID: String, Attention)
    case toast(Toast.Kind)
    /// The prompt composer. The user opened it, so it stays on top; a request that arrives meanwhile waits.
    case composer(ComposerLayout)
    /// Collapsed: Spotify is playing and Claude is quiet (album art + a green wave).
    case nowPlaying
    /// Hover with Spotify active and no Claude session: the player alone.
    case media

    /// Priority: composer > request > input > toast > progress/media (hover) > attention > working > nowPlaying > idle.
    /// `dismissedInputs` holds `inputKey`s the user closed; those fall back to the attention dot.
    static func derive(sessions: [Session], currentRequest: PendingRequest?, visibleToast: Toast.Kind?,
                       isHovering: Bool, forceProgress: Bool = false, composer: ComposerLayout? = nil,
                       dismissedInputs: Set<String> = [], mediaActive: Bool = false,
                       mediaPlaying: Bool = false) -> IslandState {
        if let composer { return .composer(composer) }
        if let currentRequest { return .request(currentRequest) }
        // The oldest waiting question first, like the request queue.
        if let s = sessions
            .filter({ $0.status == .needsYou && $0.attention != nil })
            .filter({ !dismissedInputs.contains(inputKey(sessionID: $0.id, $0.attention!)) })
            .min(by: { $0.attention!.since < $1.attention!.since }) {
            return .input(sessionID: s.id, s.attention!)
        }
        if let visibleToast { return .toast(visibleToast) }
        if isHovering || forceProgress {
            // With Spotify active, Progress splits: Claude on the left, the player on the right.
            if !sessions.isEmpty { return .progress }
            if mediaActive { return .media }
            // Nothing at all: Progress still opens, to Claude asleep.
            return .progress
        }
        if sessions.contains(where: { $0.status == .needsYou }) { return .attention }
        if sessions.contains(where: { $0.status == .working }) { return .working }
        if mediaPlaying { return .nowPlaying }
        return .idle
    }

    @MainActor
    static func derive(store: SessionStore, visibleToast: Toast.Kind?, isHovering: Bool, forceProgress: Bool = false,
                       composer: ComposerLayout? = nil, dismissedInputs: Set<String> = [],
                       mediaActive: Bool = false, mediaPlaying: Bool = false) -> IslandState {
        derive(sessions: store.sessions, currentRequest: store.currentRequest, visibleToast: visibleToast,
               isHovering: isHovering, forceProgress: forceProgress, composer: composer, dismissedInputs: dismissedInputs,
               mediaActive: mediaActive, mediaPlaying: mediaPlaying)
    }

    /// Identifies one wait: the same session asking again later is a new card.
    static func inputKey(sessionID: String, _ a: Attention) -> String {
        "\(sessionID)@\(a.since.timeIntervalSince1970)"
    }

    /// Progress and requests open into the big rounded island with the glass edge.
    var isExpanded: Bool {
        switch self {
        case .progress, .request, .composer, .input, .media: return true
        default: return false
        }
    }

    /// The colored glow under the island: red for high risk, amber for review. Never an outline.
    var glowRisk: RiskLevel? {
        guard case .request(let r) = self, r.assessment.level != .low else { return nil }
        return r.assessment.level
    }

    /// Progress lets the step list slide under the glass; requests float their buttons above it.
    var glassOverContent: Bool { self == .progress }

    /// Content identity: a change swaps the content with the blur + scale transition.
    var identity: String {
        switch self {
        case .idle: return "idle"
        case .working: return "working"
        case .attention: return "attention"
        case .progress: return "progress"
        case .request(let r): return "request-\(r.id.uuidString)"
        case .input(let id, let a): return "input-\(Self.inputKey(sessionID: id, a))"
        case .toast(let k): return "toast-\(k.rawValue)"
        // One identity for every layout: the card resizes, the text fields are never rebuilt.
        case .composer: return "composer"
        case .nowPlaying: return "now-playing"
        case .media: return "media"
        }
    }

    var logName: String {
        switch self {
        case .request(let r):
            let level: String
            switch r.assessment.level {
            case .low: level = "low"
            case .review: level = "review"
            case .high: level = "high"
            }
            return "request(\(level)) \(r.toolName): \(r.assessment.title)"
        case .input(_, let a): return "input(\(a.kind.rawValue)): \(a.title)"
        case .toast(let k): return "toast(\(k.rawValue))"
        case .composer(let l): return "composer(\(l.rawValue))"
        default: return identity
        }
    }
}

/// How tall the composer card is: the draft field, the draft plus the polished pane, or the short "Sent" card.
enum ComposerLayout: String, Equatable {
    case draft, polished, sent

    /// Card height below the notch.
    var bodyHeight: CGFloat {
        switch self {
        case .draft: return 232
        case .polished: return 292
        case .sent: return 160
        }
    }
}

/// Shows each new store toast for ~1.1 s. Pure value type; the model drives expiry with a timer.
struct ToastClock: Equatable {
    static let duration: TimeInterval = 1.1

    struct Shown: Equatable {
        var id: UUID
        var kind: Toast.Kind
        var until: Date
    }

    private(set) var lastSeenID: UUID?
    private(set) var visible: Shown?

    /// Feeds the store's latest toast. Returns true when a toast starts showing.
    mutating func observe(_ toast: Toast?, now: Date) -> Bool {
        guard let toast, toast.id != lastSeenID else { return false }
        lastSeenID = toast.id
        visible = Shown(id: toast.id, kind: toast.kind, until: now.addingTimeInterval(Self.duration))
        return true
    }

    /// Treats `toast` as already shown (used when switching stores, so a stale toast never pops up).
    mutating func markSeen(_ toast: Toast?) {
        lastSeenID = toast?.id
    }

    mutating func expire(now: Date) {
        if let v = visible, now >= v.until { visible = nil }
    }

    func visibleKind(at now: Date) -> Toast.Kind? {
        guard let v = visible, now < v.until else { return nil }
        return v.kind
    }
}
