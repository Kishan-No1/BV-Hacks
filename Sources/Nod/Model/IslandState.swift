// OWNER: workstream C (app-ui).
import Foundation
import NodCore

/// What the island shows. Derived by a pure function from the store snapshot, hover and the visible toast.
enum IslandState: Equatable {
    case idle
    case working
    case attention
    case progress
    case request(PendingRequest)
    case toast(Toast.Kind)

    /// Priority: request > toast > progress (hover) > attention > working > idle.
    static func derive(sessions: [Session], currentRequest: PendingRequest?, visibleToast: Toast.Kind?,
                       isHovering: Bool, forceProgress: Bool = false) -> IslandState {
        if let currentRequest { return .request(currentRequest) }
        if let visibleToast { return .toast(visibleToast) }
        if (isHovering || forceProgress) && !sessions.isEmpty { return .progress }
        if sessions.contains(where: { $0.status == .needsYou }) { return .attention }
        if sessions.contains(where: { $0.status == .working }) { return .working }
        return .idle
    }

    @MainActor
    static func derive(store: SessionStore, visibleToast: Toast.Kind?, isHovering: Bool, forceProgress: Bool = false) -> IslandState {
        derive(sessions: store.sessions, currentRequest: store.currentRequest, visibleToast: visibleToast,
               isHovering: isHovering, forceProgress: forceProgress)
    }

    /// Progress and requests open into the big rounded island with the glass edge.
    var isExpanded: Bool {
        switch self {
        case .progress, .request: return true
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
        case .toast(let k): return "toast-\(k.rawValue)"
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
        case .toast(let k): return "toast(\(k.rawValue))"
        default: return identity
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
