// The learned style profile's learner. Pure, local and deterministic: the same outcomes always give the
// same profile, byte for byte. No network, no randomness, no clock (every timestamp is `outcome.at`).
// Nothing here logs or prints: the profile holds the user's prompts.
import Foundation

public enum StyleLearner {
    /// A profile keeps at most this many notes; the weakest and oldest go first.
    public static let maxNotes = 40
    /// Notes are one line and at most this long.
    public static let maxNoteLength = 90
    /// A polished line and a final line are "the same line" from this token overlap up.
    static let alignThreshold = 0.5
    /// A line matches an existing note from this token overlap up.
    static let noteMatchThreshold = 0.8
    /// The polish must have at least this many words before its length says anything.
    static let minWordsForLength = 8
    /// Lines of this many words can become an "Add:" note.
    static let addableWords = 2...16
    /// A verb is "preferred" once it opened this many sent lines.
    static let preferredVerbCount = 3

    /// Politeness and padding the user may strip from the polish.
    static let fillers: [String] = [
        "please", "kindly", "thank you", "thanks", "make sure to", "be sure to", "ensure that", "carefully",
        "thoroughly", "comprehensive", "if possible", "as needed", "additionally", "furthermore",
    ]
    private static let fillerTokens: [(phrase: String, tokens: [String])] = fillers.map { ($0, tokens($0)) }

    /// Verbs that open a coding prompt.
    static let verbs: Set<String> = [
        "add", "fix", "update", "refactor", "remove", "delete", "rename", "write", "run", "check", "make", "create",
        "implement", "test", "investigate", "find", "explain", "review", "resolve", "address", "modify", "change",
        "move", "extract", "replace", "clean", "simplify", "document", "debug", "verify", "ensure", "use", "keep",
        "avoid", "build", "deploy", "revert", "merge", "split", "convert", "migrate", "optimize", "improve", "handle",
        "support", "show", "list", "summarize", "describe", "analyze", "compare", "generate", "install", "configure",
        "enable", "disable", "validate", "format", "lint", "bump", "upgrade",
    ]

    // MARK: - Text helpers

    /// Lines without their bullet markers, split into sentences. Empty pieces are dropped.
    public static func segments(_ text: String) -> [String] {
        var out: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let body = stripBullet(String(line)).text
            var current = ""
            let chars = Array(body)
            for (i, c) in chars.enumerated() {
                current.append(c)
                // A sentence ends at ". ", "? " or "! ": "v1.2" and "session.ts" stay whole.
                if ".?!".contains(c), i + 1 < chars.count, chars[i + 1].isWhitespace {
                    let piece = current.trimmingCharacters(in: .whitespaces)
                    if !piece.isEmpty { out.append(piece) }
                    current = ""
                }
            }
            let piece = current.trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { out.append(piece) }
        }
        return out
    }

    /// Lowercased, without surrounding quotes or trailing punctuation, whitespace collapsed.
    public static func normalize(_ segment: String) -> String {
        var s = collapse(segment).lowercased()
        while true {
            let before = s
            while let last = s.last, trailingPunctuation.contains(last) || last.isWhitespace { s.removeLast() }
            if s.count >= 2, let first = s.first, let last = s.last, openingQuotes.contains(first), closingQuotes.contains(last) {
                s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
            if s == before { break }
        }
        return s
    }

    /// Lowercased runs of letters and digits, in order.
    public static func tokens(_ segment: String) -> [String] {
        segment.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    /// Shared words over all words. Two empty lists share nothing.
    public static func jaccard(_ a: [String], _ b: [String]) -> Double {
        let x = Set(a), y = Set(b)
        let union = x.union(y).count
        return union == 0 ? 0 : Double(x.intersection(y).count) / Double(union)
    }

    /// At least two lines start with a bullet marker ("-", "*", "•", "1.", "1)").
    public static func isBulleted(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).filter { stripBullet(String($0)).wasBullet }.count >= 2
    }

    private static let trailingPunctuation: Set<Character> = [".", ";", ":", "!", "?", ","]
    private static let openingQuotes: Set<Character> = ["\"", "'", "`", "“", "‘"]
    private static let closingQuotes: Set<Character> = ["\"", "'", "`", "”", "’"]

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// "- item" -> "item". A marker counts only when whitespace or the end of the line follows it, so
    /// "--verbose", "*bold*" and "3.5 seconds" are left alone.
    private static func stripBullet(_ line: String) -> (text: String, wasBullet: Bool) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return ("", false) }
        var rest: Substring?
        if first == "-" || first == "*" || first == "•" {
            rest = trimmed.dropFirst()
        } else if first.isASCII, first.isNumber {
            let afterDigits = trimmed.drop { $0.isASCII && $0.isNumber }
            if let mark = afterDigits.first, mark == "." || mark == ")" { rest = afterDigits.dropFirst() }
        }
        guard let rest, rest.first.map(\.isWhitespace) ?? true else { return (trimmed, false) }
        return (rest.trimmingCharacters(in: .whitespaces), true)
    }

    /// The segment as it is quoted in a note: one line, no trailing punctuation.
    private static func display(_ segment: String) -> String {
        var s = collapse(segment)
        while let last = s.last, trailingPunctuation.contains(last) { s.removeLast() }
        return s
    }

    /// `Add: “content”`, truncated with "…" so the whole note is at most `maxNoteLength` characters.
    private static func quoted(_ prefix: String, _ content: String) -> String {
        let open = "\(prefix)“", close = "”"
        let room = maxNoteLength - open.count - close.count
        let body = content.count > room ? content.prefix(max(0, room - 1)) + "…" : Substring(content)
        return open + body + close
    }

    private struct Segment {
        var text: String
        var norm: String
        var tokens: [String]
    }

    private static func parse(_ text: String) -> [Segment] {
        segments(text).compactMap { s in
            let t = tokens(s)
            let n = normalize(s)
            return t.isEmpty || n.isEmpty ? nil : Segment(text: s, norm: n, tokens: t)
        }
    }

    private static func contains(_ tokens: [String], phrase: [String]) -> Bool {
        guard !phrase.isEmpty, tokens.count >= phrase.count else { return false }
        for start in 0...(tokens.count - phrase.count) where Array(tokens[start..<(start + phrase.count)]) == phrase {
            return true
        }
        return false
    }

    /// The first word once leading fillers are gone: "Please fix the bug" opens with "fix".
    private static func leadingWord(_ tokens: [String]) -> String? {
        var rest = tokens[...]
        var stripped = true
        while stripped {
            stripped = false
            for filler in fillerTokens where rest.count > filler.tokens.count && Array(rest.prefix(filler.tokens.count)) == filler.tokens {
                rest = rest.dropFirst(filler.tokens.count)
                stripped = true
            }
        }
        return rest.first
    }

    private static func matches(_ line: String, _ segment: Segment) -> Bool {
        segment.norm == line || jaccard(tokens(line), segment.tokens) >= noteMatchThreshold
    }

    // MARK: - Learning

    /// Returns the updated profile and what changed: learned notes, then dropped, then reinforced, each by key.
    public static func learn(_ profile: StyleProfile, outcome: StyleOutcome) -> (profile: StyleProfile, changes: [StyleChange]) {
        var state = State(profile: profile, at: outcome.at)
        let polishedText = outcome.polished.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let final = parse(outcome.final)
        let finalTokens = tokens(outcome.final)

        if let polishedText {
            let polished = parse(polishedText)
            learnLength(&state, polishedWords: tokens(polishedText).count, finalWords: finalTokens.count)
            learnFormat(&state, polishedBulleted: isBulleted(polishedText), finalBulleted: isBulleted(outcome.final))
            learnEdits(&state, polished: polished, final: final)
            learnAddedLines(&state, polished: polished, final: final)
            judgeExistingNotes(&state, polished: polished, final: final, finalTokens: finalTokens)
        } else {
            judgeExistingNotes(&state, polished: nil, final: final, finalTokens: finalTokens)
        }
        // A line the user sends again is no longer "a line they keep removing".
        for f in final where (state.profile.removedCounts[f.norm] ?? 0) > 0 { state.profile.removedCounts[f.norm] = 0 }
        learnRecurringLines(&state, final: final, finalTokens: finalTokens)
        learnVerbs(&state, final: final)

        state.profile.outcomes.append(outcome)
        if state.profile.outcomes.count > StyleProfile.maxOutcomes {
            state.profile.outcomes.removeFirst(state.profile.outcomes.count - StyleProfile.maxOutcomes)
        }
        return state.finish()
    }

    /// Rule 1. The user cut the polish down, or expanded it.
    private static func learnLength(_ state: inout State, polishedWords: Int, finalWords: Int) {
        guard polishedWords >= minWordsForLength else { return }
        let ratio = Double(finalWords) / Double(polishedWords)
        if ratio <= 0.75 {
            state.bump("length.shorter", text: "Keep prompts short; you usually cut the polish down.", threshold: 2)
            state.strike("length.longer")
        } else if ratio >= 1.25 {
            state.bump("length.longer", text: "Give more detail; you usually expand the polish.", threshold: 2)
            state.strike("length.shorter")
        } else {
            for key in ["length.longer", "length.shorter"] where state.isActive(key) { state.bump(key, text: "", threshold: 2) }
        }
    }

    /// Rule 2. Bullets rewritten as sentences, or the other way round.
    private static func learnFormat(_ state: inout State, polishedBulleted: Bool, finalBulleted: Bool) {
        let sentences = "format.sentences", bullets = "format.bullets"
        if polishedBulleted, !finalBulleted {
            state.bump(sentences, text: "Write plain sentences, not bullet lists.", threshold: 2)
            state.strike(bullets)
        } else if !polishedBulleted, finalBulleted {
            state.bump(bullets, text: "Use a short bullet list for the steps.", threshold: 2)
            state.strike(sentences)
        } else {
            let key = finalBulleted ? bullets : sentences
            if state.isActive(key) { state.bump(key, text: "", threshold: 2) }
        }
    }

    /// Rule 3. Polished lines the user removed, fillers they stripped, verbs they swapped.
    private static func learnEdits(_ state: inout State, polished: [Segment], final: [Segment]) {
        for p in polished {
            var best: (segment: Segment, score: Double)?
            for f in final {
                let score = jaccard(p.tokens, f.tokens)
                if score > (best?.score ?? -1) { best = (f, score) }
            }
            guard let best, best.score >= alignThreshold else {
                let count = (state.profile.removedCounts[p.norm] ?? 0) + 1
                state.profile.removedCounts[p.norm] = count
                if count >= 2 { state.bump("omit:\(p.norm)", text: quoted("Leave out: ", display(p.text)), threshold: 1) }
                continue
            }
            let f = best.segment
            guard p.text != f.text else { continue }
            for filler in fillerTokens where contains(p.tokens, phrase: filler.tokens) && !contains(f.tokens, phrase: filler.tokens) {
                state.bump("omit-word:\(filler.phrase)", text: "Don't say “\(filler.phrase)”.", threshold: 1)
            }
            if let from = leadingWord(p.tokens), let to = leadingWord(f.tokens), from != to, verbs.contains(from), verbs.contains(to) {
                state.bump("verb:\(from)>\(to)", text: "Say “\(to)” rather than “\(from)”.", threshold: 1)
            }
        }
    }

    /// Rule 4. Short lines the user wrote that the polish did not have.
    private static func learnAddedLines(_ state: inout State, polished: [Segment], final: [Segment]) {
        for f in final where addableWords.contains(f.tokens.count) {
            guard !polished.contains(where: { jaccard($0.tokens, f.tokens) >= alignThreshold }) else { continue }
            state.bumpAdd(for: f)
        }
    }

    /// Rule 5. Notes that already existed: kept lines reinforce them, removed or contradicted ones strike them.
    private static func judgeExistingNotes(_ state: inout State, polished: [Segment]?, final: [Segment], finalTokens: [String]) {
        for key in state.existingKeys.sorted() {
            if let line = key.strip(prefix: "add:") {
                if final.contains(where: { matches(line, $0) }) {
                    state.bump(key, text: "", threshold: 1)
                } else if let polished, polished.contains(where: { matches(line, $0) }) {
                    state.strike(key)
                }
            } else if let line = key.strip(prefix: "omit:") {
                if final.contains(where: { matches(line, $0) }), state.strike(key) { state.profile.removedCounts[line] = 0 }
            } else if let filler = key.strip(prefix: "omit-word:") {
                if contains(finalTokens, phrase: tokens(filler)) { state.strike(key) }
            } else if let swap = key.strip(prefix: "verb:"), let from = swap.split(separator: ">").first {
                if final.contains(where: { leadingWord($0.tokens) == String(from) }) { state.strike(key) }
            }
        }
    }

    /// Rule 6. A standing line: one the user sent before, inside a different prompt.
    private static func learnRecurringLines(_ state: inout State, final: [Segment], finalTokens: [String]) {
        // A one-line prompt sent twice is the same task again, not a standing instruction.
        guard final.count >= 2 else { return }
        var earlier = Set<String>()
        for old in state.profile.outcomes where jaccard(tokens(old.final), finalTokens) < noteMatchThreshold {
            for s in parse(old.final) { earlier.insert(s.norm) }
        }
        for f in final where addableWords.contains(f.tokens.count) && earlier.contains(f.norm) {
            state.bumpAdd(for: f)
        }
    }

    /// Rule 7. Which verbs open the user's sent lines.
    private static func learnVerbs(_ state: inout State, final: [Segment]) {
        var counted = Set<String>()
        for f in final {
            guard let verb = leadingWord(f.tokens), verbs.contains(verb) else { continue }
            state.profile.verbCounts[verb, default: 0] += 1
            counted.insert(verb)
        }
        let top = state.profile.verbCounts.filter { $0.value >= preferredVerbCount }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(3).map(\.key)
        guard !top.isEmpty else { return }
        state.setVerbsNote(text: "Prefers the verbs: \(top.joined(separator: ", ")).", touched: !counted.isDisjoint(with: top))
    }

    // MARK: - Bookkeeping

    private struct State {
        var profile: StyleProfile
        let at: Date
        var notes: [String: StyleNote] = [:]
        /// Keys of the notes that existed before this outcome: only those can be struck.
        let existingKeys: Set<String>
        private var bumped = Set<String>()
        private var struck = Set<String>()
        private var learned = Set<String>()
        private var reinforced = Set<String>()
        private var dropped: [StyleNote] = []

        init(profile: StyleProfile, at: Date) {
            self.profile = profile
            self.at = at
            // A hand-edited file can repeat a key: the first one wins.
            for note in profile.notes where notes[note.key] == nil { notes[note.key] = note }
            existingKeys = Set(notes.keys)
        }

        func isActive(_ key: String) -> Bool { notes[key]?.active ?? false }

        /// One piece of evidence for a note. At most one per key and outcome. `text` is only used for a new note.
        mutating func bump(_ key: String, text: String, threshold: Int) {
            guard !bumped.contains(key), !struck.contains(key) else { return }
            if var note = notes[key] {
                bumped.insert(key)
                note.score += 1
                note.count += 1
                note.strikes = 0
                note.updatedAt = at
                if note.active {
                    reinforced.insert(key)
                } else if note.score >= threshold {
                    note.active = true
                    learned.insert(key)
                }
                notes[key] = note
            } else if !text.isEmpty {
                bumped.insert(key)
                let active = threshold <= 1
                notes[key] = StyleNote(key: key, text: text, score: 1, count: 1, strikes: 0, active: active, updatedAt: at)
                if active { learned.insert(key) }
            }
        }

        /// An "Add:" note for a line of the final text: the existing note it matches, else a new one. A line
        /// the profile was told to leave out only cancels that note (rule 5); it does not flip to "Add:" at once.
        mutating func bumpAdd(for segment: Segment) {
            let keys = existingKeys.sorted()
            if keys.contains(where: { key in key.strip(prefix: "omit:").map { StyleLearner.matches($0, segment) } ?? false }) { return }
            if let key = keys.first(where: { key in key.strip(prefix: "add:").map { StyleLearner.matches($0, segment) } ?? false }) {
                bump(key, text: "", threshold: 1)
            } else {
                bump("add:\(segment.norm)", text: StyleLearner.quoted("Add: ", StyleLearner.display(segment.text)), threshold: 1)
            }
        }

        /// The user removed or contradicted what the note asks for. Two in a row drop it. Returns true on a drop.
        @discardableResult
        mutating func strike(_ key: String) -> Bool {
            guard existingKeys.contains(key), !struck.contains(key), !bumped.contains(key), var note = notes[key] else { return false }
            struck.insert(key)
            note.strikes += 1
            note.score -= 1
            note.updatedAt = at
            if note.strikes >= 2 {
                notes[key] = nil
                if note.active { dropped.append(note) }
                return true
            }
            notes[key] = note
            return false
        }

        mutating func setVerbsNote(text: String, touched: Bool) {
            let key = "verbs.top"
            if var note = notes[key] {
                if note.text != text || !note.active {
                    note.text = text
                    note.active = true
                    note.updatedAt = at
                    learned.insert(key)
                } else if touched {
                    note.updatedAt = at
                }
                notes[key] = note
            } else {
                notes[key] = StyleNote(key: key, text: text, score: 1, count: 1, strikes: 0, active: true, updatedAt: at)
                learned.insert(key)
            }
        }

        func finish() -> (profile: StyleProfile, changes: [StyleChange]) {
            var kept = notes
            if kept.count > StyleLearner.maxNotes {
                // Inactive notes go first (weakest, then oldest), then the active ones seen least and longest ago.
                let order = kept.values.sorted { a, b in
                    if a.active != b.active { return !a.active }
                    let x = a.active ? a.count : a.score, y = b.active ? b.count : b.score
                    if x != y { return x < y }
                    if a.updatedAt != b.updatedAt { return a.updatedAt < b.updatedAt }
                    return a.key < b.key
                }
                for note in order.prefix(kept.count - StyleLearner.maxNotes) { kept[note.key] = nil }
            }
            var result = profile
            result.notes = kept.values.sorted { $0.key < $1.key }
            var changes: [StyleChange] = []
            changes += learned.sorted().compactMap { notes[$0].map(StyleChange.learned) }
            changes += dropped.sorted { $0.key < $1.key }.map(StyleChange.dropped)
            changes += reinforced.sorted().compactMap { notes[$0].map(StyleChange.reinforced) }
            return (result, changes)
        }
    }
}

private extension String {
    func strip(prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
