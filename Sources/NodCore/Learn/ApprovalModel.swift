import Foundation

/// What the request card says about the user's own habit for a request like this one. Advisory only:
/// it never answers a request, never changes the default action, and never touches the hold-to-allow.
public struct ApprovalPrediction: Sendable, Equatable {
    /// The model's probability that the user allows this request, 0...1.
    public var allowProbability: Double
    /// Decisions the model has learned from so far.
    public var decisions: Int
    /// The risk level of the request, so the chip can say when the habit and the risk read-out disagree.
    public var level: RiskLevel

    public init(allowProbability: Double, decisions: Int, level: RiskLevel) {
        self.allowProbability = allowProbability; self.decisions = decisions; self.level = level
    }

    public var likelyAllow: Bool { allowProbability >= 0.5 }

    /// How sure the model is of its leaning, 50...100.
    public var percent: Int { Int((max(allowProbability, 1 - allowProbability) * 100).rounded()) }

    /// The habit and the risk read-out disagree: a low or review request the user would likely deny,
    /// or a high one they would likely allow.
    public var unusual: Bool { likelyAllow == (level == .high) }

    /// Chip text: "Likely allow · 94%", "Likely deny · 81%", "Unusual for you · 78% deny".
    public var label: String {
        let verb = likelyAllow ? "allow" : "deny"
        return unusual ? "Unusual for you · \(percent)% \(verb)" : "Likely \(verb) · \(percent)%"
    }
}

/// The features one request is described by: short strings such as `tool:Bash`, `cmd:npm`, `level:low`,
/// `reason:read-only`. Lexical only, like the risk engine: built from the hook payload and the assessment,
/// never from the disk.
public enum ApprovalFeatures {
    public static func extract(toolName: String, toolInput: JSONValue, cwd: String, assessment: Assessment) -> [String] {
        var f = ["bias", "tool:\(toolName)", "level:\(assessment.level)"]
        f += assessment.reasons.map { "reason:\($0.lowercased())" }
        let repo = LexicalPath.lastComponent(cwd)
        if !repo.isEmpty, repo != "/" { f.append("repo:\(repo)") }

        if toolName == "Bash", let raw = toolInput.string("command") {
            let command = RulesStore.normalizedCommand(raw.trimmingCharacters(in: .whitespacesAndNewlines))
            // The program and its prefix, past any `VAR=value` assignments: `NODE_ENV=test npm test` -> `npm`.
            let words = command.split(separator: " ").map(String.init).drop(while: BashClassifier.isAssignment)
            if let first = words.first { f.append("cmd:\(LexicalPath.lastComponent(first))") }
            if let prefix = RulesStore.bashPrefix(words.joined(separator: " ")), prefix.contains(" ") { f.append("prefix:\(prefix)") }
            if RulesStore.hasShellOperators(command) { f.append("shell-operators") }
        } else if RiskEngine.editTools.contains(toolName) {
            let path = toolInput.string("file_path") ?? toolInput.string("notebook_path") ?? ""
            let ext = (path as NSString).pathExtension.lowercased()
            if !ext.isEmpty { f.append("ext:\(ext)") }
        } else if toolName == "WebFetch", let host = TextKit.host(of: toolInput.string("url") ?? "") {
            f.append("host:\(host.lowercased())")
        } else if let mcp = TextKit.mcpParts(toolName) {
            f.append("mcp:\(mcp.server)")
        }

        var seen = Set<String>()
        return f.filter { seen.insert($0).inserted }
    }
}

/// Online logistic regression over binary features, trained one decision at a time with AdaGrad
/// (a per-feature learning rate that shrinks as a feature is seen more) and L2 regularization.
///
/// The logit starts from a fixed prior taken from the risk level, so before the model has learned
/// anything a high-risk request leans towards deny. Learned weights move it from there.
/// Pure value type: `ApprovalModelStore` persists it.
public struct ApprovalModel: Codable, Sendable, Equatable {
    public var weights: [String: Double]
    /// AdaGrad's running sum of squared gradients, per feature.
    public var gradientSquares: [String: Double]
    /// How many decisions each feature appeared in (used to prune rare features).
    public var counts: [String: Int]
    public var decisions: Int
    public var allows: Int

    public static let empty = ApprovalModel(weights: [:], gradientSquares: [:], counts: [:], decisions: 0, allows: 0)

    public init(weights: [String: Double], gradientSquares: [String: Double], counts: [String: Int], decisions: Int, allows: Int) {
        self.weights = weights; self.gradientSquares = gradientSquares; self.counts = counts
        self.decisions = decisions; self.allows = allows
    }

    /// No chip until the model has seen this many decisions.
    public static let minDecisions = 5
    /// No chip unless the model leans at least this far one way (as a percent).
    public static let minPercent = 60
    static let learningRate = 0.35
    static let l2 = 0.005
    /// Features kept at most; the rarest are dropped past this.
    static let maxFeatures = 4000

    /// The starting logit for a risk level: low leans allow, high leans deny.
    static func prior(_ level: RiskLevel) -> Double {
        switch level {
        case .low: return 1.0
        case .review: return 0.5
        case .high: return -1.5
        }
    }

    /// P(allow) for a request with these features.
    public func probability(_ features: [String], level: RiskLevel) -> Double {
        let z = Self.prior(level) + features.reduce(0) { $0 + (weights[$1] ?? 0) }
        return 1 / (1 + exp(-z))
    }

    /// The chip for a request, or nil while the model has too little data or no clear leaning.
    public func predict(_ features: [String], level: RiskLevel) -> ApprovalPrediction? {
        guard decisions >= Self.minDecisions else { return nil }
        let p = ApprovalPrediction(allowProbability: probability(features, level: level), decisions: decisions, level: level)
        return p.percent >= Self.minPercent ? p : nil
    }

    /// One step of stochastic gradient descent on the log loss for one decision.
    public mutating func learn(_ features: [String], level: RiskLevel, allowed: Bool) {
        let error = probability(features, level: level) - (allowed ? 1 : 0)
        for k in features {
            let w = weights[k] ?? 0
            let g = error + Self.l2 * w
            let g2 = (gradientSquares[k] ?? 0) + g * g
            gradientSquares[k] = g2
            weights[k] = w - Self.learningRate * g / (sqrt(g2) + 1e-8)
            counts[k, default: 0] += 1
        }
        decisions += 1
        if allowed { allows += 1 }
        prune()
    }

    /// Keeps the file small: past `maxFeatures`, drops the least-seen features (never `bias`).
    private mutating func prune() {
        guard weights.count > Self.maxFeatures else { return }
        let keep = Self.maxFeatures * 9 / 10
        let drop = weights.keys.filter { $0 != "bias" }
            .sorted { (counts[$0] ?? 0, $0) < (counts[$1] ?? 0, $1) }
            .prefix(weights.count - keep)
        for k in drop {
            weights[k] = nil
            gradientSquares[k] = nil
            counts[k] = nil
        }
    }
}
