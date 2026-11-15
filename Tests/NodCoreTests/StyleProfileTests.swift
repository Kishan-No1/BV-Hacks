// Learned style profile: StyleLearner (pure) and StyleProfileStore (JSON on disk, temp directories only).
import Foundation
import Testing
import NodCore

/// Whole-second timestamps one minute apart, so ISO 8601 round trips are exact.
private func at(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 60) }

private func outcome(_ n: Int, polished: String?, final: String, raw: String = "rough") -> StyleOutcome {
    StyleOutcome(raw: raw, polished: polished, final: final, at: at(n))
}

/// Applies the outcomes in order from `start`; returns the last profile and the changes of every step.
private func run(_ outcomes: [StyleOutcome], from start: StyleProfile = .empty) -> (profile: StyleProfile, steps: [[StyleChange]]) {
    var profile = start
    var steps: [[StyleChange]] = []
    for o in outcomes {
        let result = StyleLearner.learn(profile, outcome: o)
        profile = result.profile
        steps.append(result.changes)
    }
    return (profile, steps)
}

private func note(_ profile: StyleProfile, _ key: String) -> StyleNote? { profile.notes.first { $0.key == key } }

private func learnedKeys(_ changes: [StyleChange]) -> [String] {
    changes.compactMap { if case .learned(let n) = $0 { return n.key } else { return nil } }
}
private func droppedKeys(_ changes: [StyleChange]) -> [String] {
    changes.compactMap { if case .dropped(let n) = $0 { return n.key } else { return nil } }
}
private func reinforcedKeys(_ changes: [StyleChange]) -> [String] {
    changes.compactMap { if case .reinforced(let n) = $0 { return n.key } else { return nil } }
}

private func encode(_ profile: StyleProfile) throws -> Data {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try e.encode(profile)
}

private let addKey = "add:run tests after edits"
/// The user adds a line the polish did not have.
private let addedOnce = outcome(1, polished: "Fix the login bug.", final: "Fix the login bug. run tests after edits")
/// The polish has the line and the user deletes it.
private func deleted(_ n: Int, _ lead: String) -> StyleOutcome {
    outcome(n, polished: "\(lead) Run tests after edits.", final: lead)
}
/// The polish has the line and the user keeps it.
private func kept(_ n: Int, _ lead: String) -> StyleOutcome {
    outcome(n, polished: "\(lead) Run tests after edits.", final: "\(lead) Run tests after edits.")
}

// MARK: - Text helpers

@Suite struct StyleProfileHelperTests {
    @Test func segmentsSplitLinesBulletsAndSentences() {
        let text = "- Fix the bug. Then run tests!\n\n  * second item\n• third\n1. fourth\n2) fifth? yes\nplain v1.2 line"
        #expect(StyleLearner.segments(text) == [
            "Fix the bug.", "Then run tests!", "second item", "third", "fourth", "fifth?", "yes", "plain v1.2 line",
        ])
        #expect(StyleLearner.segments("") == [])
        #expect(StyleLearner.segments(" \n\t\n-\n") == [])
        // Not bullets: a flag, emphasis, a decimal.
        #expect(StyleLearner.segments("--verbose\n*bold*\n3.5 seconds") == ["--verbose", "*bold*", "3.5 seconds"])
    }

    @Test func normalizeLowercasesAndStripsQuotesAndTrailingPunctuation() {
        #expect(StyleLearner.normalize("  \"Run   Tests After\tEdits.\"  ") == "run tests after edits")
        #expect(StyleLearner.normalize("`Run tests`!?") == "run tests")
        #expect(StyleLearner.normalize("“Run tests”.") == "run tests")
        #expect(StyleLearner.normalize("Run `swift test`.") == "run `swift test`")
        #expect(StyleLearner.normalize("...") == "")
    }

    @Test func tokensAndJaccard() {
        #expect(StyleLearner.tokens("Fix the LOGIN-bug, v2!") == ["fix", "the", "login", "bug", "v2"])
        #expect(StyleLearner.jaccard(["a", "b"], ["a", "b"]) == 1)
        #expect(StyleLearner.jaccard(["a", "b", "c", "d"], ["a", "b", "c", "e"]) == 0.6)
        #expect(StyleLearner.jaccard(["a"], ["b"]) == 0)
        #expect(StyleLearner.jaccard([], []) == 0)
    }

    @Test func bulletedNeedsTwoBulletLines() {
        #expect(StyleLearner.isBulleted("- one\n- two"))
        #expect(StyleLearner.isBulleted("Intro\n1. one\n2) two"))
        #expect(!StyleLearner.isBulleted("- one\nplain"))
        #expect(!StyleLearner.isBulleted("One. Two. Three."))
        #expect(!StyleLearner.isBulleted(""))
    }
}

// MARK: - Added lines

@Suite struct StyleProfileAddedLineTests {
    @Test func anAddedLineBecomesANoteAfterOneOutcome() throws {
        let r = run([addedOnce])
        #expect(r.steps[0].count == 1)
        let change = try #require(r.steps[0].first)
        #expect(change.chipText == "Learned: Add: “run tests after edits”")
        #expect(change.note.key == addKey)
        let n = try #require(note(r.profile, addKey))
        #expect(n.active)
        #expect(n.score == 1)
        #expect(n.count == 1)
        #expect(n.strikes == 0)
        #expect(n.updatedAt == at(1))
        #expect(r.profile.topNotes().map(\.text) == ["Add: “run tests after edits”"])
    }

    @Test func itIsReinforcedWhenThePolishHasItAndTheUserKeepsIt() throws {
        let r = run([addedOnce, kept(2, "Update the README.")])
        #expect(r.steps[1] == [.reinforced(try #require(note(r.profile, addKey)))])
        #expect(r.steps[1].compactMap(\.chipText).isEmpty)
        let n = try #require(note(r.profile, addKey))
        #expect(n.count == 2)
        #expect(n.score == 2)
        #expect(n.strikes == 0)
        #expect(n.updatedAt == at(2))
    }

    @Test func itIsReinforcedWhenTheUserAddsItAgain() throws {
        let again = outcome(2, polished: "Update the README.", final: "Update the README.\nRun tests after edits!")
        let r = run([addedOnce, again])
        #expect(reinforcedKeys(r.steps[1]) == [addKey])
        #expect(learnedKeys(r.steps[1]).isEmpty)
        // One +1 per outcome, even though rules 4, 5 and 6 all see the line.
        #expect(note(r.profile, addKey)?.count == 2)
        #expect(note(r.profile, addKey)?.text == "Add: “run tests after edits”")
    }

    @Test func aNearMatchReinforcesTheExistingNoteInsteadOfMakingANewOne() {
        // 5 of 6 tokens shared: above the 0.8 match line.
        let first = outcome(1, polished: "Fix the login bug.", final: "Fix the login bug. run all the tests after edits")
        let near = outcome(2, polished: "Update the README.", final: "Update the README. run all tests after edits")
        let r = run([first, near])
        #expect(reinforcedKeys(r.steps[1]) == ["add:run all the tests after edits"])
        #expect(r.profile.notes.filter { $0.key.hasPrefix("add:") }.count == 1)
    }

    @Test func oneDeletionDoesNotDropIt() throws {
        let r = run([addedOnce, deleted(2, "Update the README.")])
        #expect(r.steps[1].isEmpty)
        let n = try #require(note(r.profile, addKey))
        #expect(n.active)
        #expect(n.strikes == 1)
        #expect(n.score == 0)
        #expect(n.count == 1)
    }

    @Test func twoConsecutiveDeletionsDropIt() throws {
        let r = run([addedOnce, deleted(2, "Update the README."), deleted(3, "Rename the helper.")])
        #expect(droppedKeys(r.steps[2]) == [addKey])
        #expect(r.steps[2].compactMap(\.chipText).contains("Dropped: Add: “run tests after edits”"))
        #expect(note(r.profile, addKey) == nil)
        // Removed from the polish twice: the opposite note takes its place.
        #expect(learnedKeys(r.steps[2]) == ["omit:run tests after edits"])
    }

    @Test func aDeletionFollowedByAKeepResetsTheStrikes() throws {
        let r = run([addedOnce, deleted(2, "Update the README."), kept(3, "Rename the helper."),
                     deleted(4, "Bump the version.")])
        #expect(reinforcedKeys(r.steps[2]) == [addKey])
        #expect(droppedKeys(r.steps[3]).isEmpty)
        let n = try #require(note(r.profile, addKey))
        #expect(n.active)
        #expect(n.strikes == 1)
    }

    @Test func aPolishThatLeavesTheLineOutIsNotAStrike() throws {
        let unrelated = outcome(2, polished: "Update the README.", final: "Update the README.")
        let r = run([addedOnce, unrelated, unrelated])
        #expect(r.steps[1].isEmpty)
        #expect(note(r.profile, addKey)?.strikes == 0)
    }

    @Test func longAndOneWordLinesAreNotAdded() {
        let long = (1...17).map { "word\($0)" }.joined(separator: " ")
        let r = run([outcome(1, polished: "Fix the login bug.", final: "Fix the login bug.\nthanks\n\(long)")])
        #expect(r.profile.notes.isEmpty)
    }

    @Test func noteTextIsOneLineAndAtMostNinetyCharacters() throws {
        let line = (1...16).map { "longword\($0)" }.joined(separator: "\t ")
        let r = run([outcome(1, polished: "Fix the login bug.", final: "Fix the login bug.\n\(line)")])
        let n = try #require(r.profile.notes.first)
        #expect(n.text.count == 90)
        #expect(n.text.hasPrefix("Add: “longword1 longword2 "))
        #expect(n.text.hasSuffix("…”"))
        #expect(!n.text.contains("\n") && !n.text.contains("\t"))
        #expect(r.profile.notes.allSatisfy { $0.text.count <= 90 })
    }
}

// MARK: - Length and format

@Suite struct StyleProfileLengthAndFormatTests {
    /// 18 polished words cut down to 8.
    private func cut(_ n: Int, _ topic: String) -> StyleOutcome {
        outcome(n, polished: "Fix the \(topic) bug in the auth module. Cover the change with unit tests. Note it in the changelog.",
                final: "Fix the \(topic) bug in the auth module.")
    }
    /// 8 polished words expanded to 14.
    private func expanded(_ n: Int, _ topic: String) -> StyleOutcome {
        outcome(n, polished: "Fix the \(topic) bug in the auth module.",
                final: "Fix the \(topic) bug in the auth module. Cover \(topic) with unit tests too.")
    }

    @Test func shorterNeedsTwoOutcomes() throws {
        let r = run([cut(1, "login"), cut(2, "logout")])
        #expect(!learnedKeys(r.steps[0]).contains("length.shorter"))
        let first = try #require(note(run([cut(1, "login")]).profile, "length.shorter"))
        #expect(!first.active)
        #expect(first.score == 1)
        #expect(learnedKeys(r.steps[1]).contains("length.shorter"))
        let n = try #require(note(r.profile, "length.shorter"))
        #expect(n.active)
        #expect(n.text == "Keep prompts short; you usually cut the polish down.")
        #expect(r.profile.topNotes().contains { $0.key == "length.shorter" })
    }

    @Test func shortPolishesSayNothingAboutLength() {
        let r = run([outcome(1, polished: "Fix the login bug.", final: "Fix it."),
                     outcome(2, polished: "Fix the logout bug.", final: "Fix it now.")])
        #expect(!r.profile.notes.contains { $0.key.hasPrefix("length.") })
    }

    @Test func theLengthNoteFlipsWhenTheUserStartsExpanding() throws {
        let r = run([cut(1, "login"), cut(2, "logout"), expanded(3, "signup"), expanded(4, "billing")])
        // One expansion is a strike, not a flip.
        #expect(!droppedKeys(r.steps[2]).contains("length.shorter"))
        #expect(!learnedKeys(r.steps[2]).contains("length.longer"))
        #expect(learnedKeys(r.steps[3]).contains("length.longer"))
        #expect(droppedKeys(r.steps[3]) == ["length.shorter"])
        #expect(note(r.profile, "length.shorter") == nil)
        let n = try #require(note(r.profile, "length.longer"))
        #expect(n.active)
        #expect(n.text == "Give more detail; you usually expand the polish.")
    }

    @Test func keepingTheLengthReinforcesTheActiveLengthNote() throws {
        let same = outcome(3, polished: "Rename the session helper in the auth module now.",
                           final: "Rename the session helper in the auth module now.")
        let r = run([cut(1, "login"), cut(2, "logout"), same])
        #expect(reinforcedKeys(r.steps[2]) == ["length.shorter"])
        #expect(note(r.profile, "length.shorter")?.count == 3)
    }

    @Test func bulletsRewrittenAsSentencesBecomeANote() throws {
        let r = run([
            outcome(1, polished: "- Fix the login bug\n- Rename the helper", final: "Fix the login bug. Rename the helper."),
            outcome(2, polished: "- Update the README\n- Bump the version", final: "Update the README. Bump the version."),
        ])
        #expect(r.steps[0].isEmpty)
        #expect(learnedKeys(r.steps[1]) == ["format.sentences"])
        #expect(note(r.profile, "format.sentences")?.text == "Write plain sentences, not bullet lists.")
    }

    @Test func theFormatNoteFlipsAndIsReinforcedOnlyByItsOwnFormat() throws {
        let toSentences = [
            outcome(1, polished: "- Fix the login bug\n- Rename the helper", final: "Fix the login bug. Rename the helper."),
            outcome(2, polished: "- Update the README\n- Bump the version", final: "Update the README. Bump the version."),
        ]
        // Sentences in, sentences out: reinforced.
        let plain = outcome(3, polished: "Remove the dead flag.", final: "Remove the dead flag.")
        var r = run(toSentences + [plain])
        #expect(reinforcedKeys(r.steps[2]) == ["format.sentences"])
        // Bullets in, bullets out: the sentences note is left alone.
        let bullets = outcome(3, polished: "- Remove the dead flag\n- Simplify the parser", final: "- Remove the dead flag\n- Simplify the parser")
        r = run(toSentences + [bullets])
        #expect(r.steps[2].isEmpty)
        #expect(note(r.profile, "format.sentences")?.strikes == 0)
        // The user starts turning sentences into bullets: flips after two.
        r = run(toSentences + [
            outcome(3, polished: "Remove the dead flag. Simplify the parser.", final: "- Remove the dead flag\n- Simplify the parser"),
            outcome(4, polished: "Extract the reducer. Document the cache.", final: "- Extract the reducer\n- Document the cache"),
        ])
        #expect(!droppedKeys(r.steps[2]).contains("format.sentences"))
        #expect(learnedKeys(r.steps[3]) == ["format.bullets"])
        #expect(droppedKeys(r.steps[3]) == ["format.sentences"])
        #expect(note(r.profile, "format.bullets")?.text == "Use a short bullet list for the steps.")
    }
}

// MARK: - Removed lines, fillers, verbs

@Suite struct StyleProfileEditSignalTests {
    private let omitKey = "omit:let me know if you have questions"
    private func removed(_ n: Int, _ lead: String) -> StyleOutcome {
        outcome(n, polished: "\(lead) Let me know if you have questions.", final: lead)
    }

    @Test func aPolishedLineRemovedTwiceBecomesAnOmitNote() throws {
        let r = run([removed(1, "Fix the login bug."), removed(2, "Update the README.")])
        #expect(!r.steps[0].contains { $0.note.key.hasPrefix("omit:") })
        #expect(run([removed(1, "Fix the login bug.")]).profile.removedCounts["let me know if you have questions"] == 1)
        #expect(learnedKeys(r.steps[1]).contains(omitKey))
        let n = try #require(note(r.profile, omitKey))
        #expect(n.active)
        #expect(n.text == "Leave out: “Let me know if you have questions”")
        #expect(r.profile.removedCounts["let me know if you have questions"] == 2)
    }

    @Test func removingItAgainReinforcesTheOmitNote() {
        let r = run([removed(1, "Fix the login bug."), removed(2, "Update the README."), removed(3, "Bump the version.")])
        #expect(reinforcedKeys(r.steps[2]).contains(omitKey))
    }

    @Test func anOmitNoteIsDroppedWhenTheUserSendsTheLineTwice() {
        func sent(_ n: Int, _ lead: String) -> StyleOutcome {
            outcome(n, polished: lead, final: "\(lead) Let me know if you have questions.")
        }
        let r = run([removed(1, "Fix the login bug."), removed(2, "Update the README."),
                     sent(3, "Bump the version."), sent(4, "Remove the flag.")])
        #expect(!droppedKeys(r.steps[2]).contains(omitKey))
        #expect(droppedKeys(r.steps[3]).contains(omitKey))
        #expect(r.profile.removedCounts["let me know if you have questions"] == 0)
    }

    @Test func aFillerRemovedFromASurvivingLineBecomesAnOmitWordNote() throws {
        let r = run([outcome(1, polished: "Please fix the login bug.", final: "Fix the login bug.")])
        #expect(learnedKeys(r.steps[0]) == ["omit-word:please"])
        #expect(note(r.profile, "omit-word:please")?.text == "Don't say “please”.")
        #expect(r.steps[0].first?.chipText == "Learned: Don't say “please”.")
    }

    @Test func multiWordFillersMatchOnWordBoundaries() {
        let r = run([
            outcome(1, polished: "Make sure to update the changelog file.", final: "Update the changelog file."),
            // "pleased" is not "please"; an untouched line teaches nothing.
            outcome(2, polished: "Explain why users are pleased here.", final: "Explain why users are pleased here."),
        ])
        #expect(learnedKeys(r.steps[0]) == ["omit-word:make sure to"])
        #expect(r.steps[1].isEmpty)
    }

    @Test func anOmitWordNoteIsDroppedWhenTheUserKeepsSayingIt() {
        let r = run([
            outcome(1, polished: "Please fix the login bug.", final: "Fix the login bug."),
            outcome(2, polished: nil, final: "please update the README"),
            outcome(3, polished: "Rename the helper.", final: "Please rename the helper."),
        ])
        #expect(r.steps[1].isEmpty)
        #expect(note(run([
            outcome(1, polished: "Please fix the login bug.", final: "Fix the login bug."),
            outcome(2, polished: nil, final: "please update the README"),
        ]).profile, "omit-word:please")?.strikes == 1)
        #expect(droppedKeys(r.steps[2]) == ["omit-word:please"])
        #expect(note(r.profile, "omit-word:please") == nil)
    }

    @Test func aLeadingVerbSwapBecomesAVerbNote() throws {
        let r = run([outcome(1, polished: "Resolve the login bug.", final: "Fix the login bug.")])
        #expect(learnedKeys(r.steps[0]) == ["verb:resolve>fix"])
        #expect(note(r.profile, "verb:resolve>fix")?.text == "Say “fix” rather than “resolve”.")
    }

    @Test func aVerbNoteIsDroppedWhenTheUserUsesTheOldVerbTwice() {
        let r = run([
            outcome(1, polished: "Resolve the login bug.", final: "Fix the login bug."),
            outcome(2, polished: nil, final: "Resolve the merge conflict"),
            outcome(3, polished: nil, final: "Resolve the flaky test"),
        ])
        #expect(r.steps[1].isEmpty)
        #expect(droppedKeys(r.steps[2]) == ["verb:resolve>fix"])
    }

    @Test func aSwapToAWordOutsideTheLexiconIsNotAVerbNote() {
        let r = run([outcome(1, polished: "Resolve the login bug.", final: "Squash the login bug.")])
        #expect(!r.profile.notes.contains { $0.key.hasPrefix("verb:") })
    }
}

// MARK: - Signals that need no polish

@Suite struct StyleProfileRawSendTests {
    @Test func verbsTopAppearsAtCountThree() throws {
        let sends = [
            outcome(1, polished: nil, final: "Fix the login bug"),
            outcome(2, polished: nil, final: "Fix the flaky test"),
            outcome(3, polished: nil, final: "Fix the build"),
        ]
        let r = run(sends)
        #expect(r.steps[0].isEmpty)
        #expect(r.steps[1].isEmpty)
        #expect(learnedKeys(r.steps[2]) == ["verbs.top"])
        let n = try #require(note(r.profile, "verbs.top"))
        #expect(n.active)
        #expect(n.text == "Prefers the verbs: fix.")
        #expect(r.profile.verbCounts == ["fix": 3])
        // Same verbs, same text: no new chip.
        let more = run([outcome(4, polished: nil, final: "Fix the docs")], from: r.profile)
        #expect(more.steps[0].isEmpty)
        #expect(note(more.profile, "verbs.top")?.updatedAt == at(4))
    }

    @Test func verbsTopListsUpToThreeVerbsByCountThenName() throws {
        var sends: [StyleOutcome] = []
        var n = 0
        for (verb, times) in [("update", 3), ("add", 3), ("fix", 4), ("run", 3), ("check", 2)] {
            for i in 0..<times {
                n += 1
                sends.append(outcome(n, polished: nil, final: "\(verb) thing number \(n) variant \(i)"))
            }
        }
        let r = run(sends)
        #expect(note(r.profile, "verbs.top")?.text == "Prefers the verbs: fix, add, run.")
    }

    @Test func withoutAPolishOnlyRecurrenceAndVerbsAreLearned() {
        // A long raw prompt, then a short bulleted one: no length, format, add or omit signals.
        let r = run([
            outcome(1, polished: nil, final: "Fix the login bug in the auth module and cover it with tests please."),
            outcome(2, polished: nil, final: "- Rename the helper\n- Bump the version"),
        ])
        #expect(r.steps.allSatisfy { $0.isEmpty })
        #expect(r.profile.notes.isEmpty)
        #expect(r.profile.removedCounts.isEmpty)
        #expect(r.profile.verbCounts == ["fix": 1, "rename": 1, "bump": 1])
        #expect(r.profile.outcomes.count == 2)
    }

    @Test func aLineRecurringAcrossTwoRawSendsBecomesAnAddNote() throws {
        let r = run([
            outcome(1, polished: nil, final: "Fix the login bug.\nrun tests after edits"),
            outcome(2, polished: nil, final: "Update the README. Run tests after edits."),
        ])
        #expect(r.steps[0].isEmpty)
        #expect(r.steps[1].count == 1)
        #expect(r.steps[1].first?.chipText == "Learned: Add: “Run tests after edits”")
        #expect(note(r.profile, addKey)?.active == true)
        // A third send reinforces it once.
        let more = run([outcome(3, polished: nil, final: "Bump the version. run tests after edits")], from: r.profile)
        #expect(reinforcedKeys(more.steps[0]) == [addKey])
        #expect(note(more.profile, addKey)?.count == 2)
    }

    @Test func emptyStringsDoNotCrash() {
        let r = run([
            StyleOutcome(raw: "", polished: "", final: "", at: at(1)),
            StyleOutcome(raw: "", polished: nil, final: "", at: at(2)),
            StyleOutcome(raw: " \n ", polished: "\n\n", final: " . ", at: at(3)),
            StyleOutcome(raw: "x", polished: "", final: "Fix the login bug.", at: at(4)),
            StyleOutcome(raw: "x", polished: "Fix the login bug.", final: "", at: at(5)),
        ])
        #expect(r.profile.outcomes.count == 5)
        #expect(r.profile.notes.allSatisfy { !$0.text.isEmpty })
    }
}

// MARK: - Profile shape

@Suite struct StyleProfileShapeTests {
    private var varied: [StyleOutcome] {
        [
            addedOnce,
            outcome(2, polished: "Please resolve the logout bug. Let me know if you have questions.", final: "Fix the logout bug."),
            outcome(3, polished: "- Update the README\n- Bump the version", final: "Update the README. Bump the version. run tests after edits"),
            outcome(4, polished: nil, final: "Fix the flaky test\nrun tests after edits"),
            outcome(5, polished: "Fix the signup bug in the auth module. Cover the change with unit tests. Let me know if you have questions.",
                    final: "Fix the signup bug in the auth module."),
            outcome(6, polished: "- Rename the helper\n- Simplify the parser\n- Run tests after edits.", final: "Rename the helper. Simplify the parser."),
            outcome(7, polished: "Fix the billing bug in the auth module. Cover the change with unit tests. Thanks for the help.",
                    final: "Fix the billing bug in the auth module."),
            outcome(8, polished: nil, final: ""),
            outcome(9, polished: "Kindly fix the cache bug.", final: "Fix the cache bug.\n- keep the diff small"),
        ]
    }

    @Test func theSameOutcomesGiveByteIdenticalJSON() throws {
        let a = run(varied), b = run(varied)
        #expect(a.profile == b.profile)
        #expect(a.steps == b.steps)
        let bytes = try encode(a.profile)
        #expect(bytes == (try encode(b.profile)))
        #expect(!a.profile.notes.isEmpty)
        // Stable through a decode and re-encode as well.
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        #expect(try encode(d.decode(StyleProfile.self, from: bytes)) == bytes)
    }

    @Test func notesAreSortedByKeyAndTimestampsComeFromTheOutcome() {
        let r = run(varied)
        #expect(r.profile.notes.map(\.key) == r.profile.notes.map(\.key).sorted())
        #expect(Set(r.profile.notes.map(\.key)).count == r.profile.notes.count)
        let stamps = Set(varied.map(\.at))
        #expect(r.profile.notes.allSatisfy { stamps.contains($0.updatedAt) })
        #expect(r.profile.notes.allSatisfy { !$0.text.contains("\n") && $0.text.count <= 90 })
    }

    @Test func changesAreOrderedLearnedThenDroppedThenReinforcedEachByKey() {
        for step in run(varied).steps {
            func rank(_ c: StyleChange) -> Int {
                switch c { case .learned: return 0; case .dropped: return 1; case .reinforced: return 2 }
            }
            let order = step.map { "\(rank($0))|\($0.note.key)" }
            #expect(order == order.sorted())
        }
        // One step with all three kinds.
        let r = run([
            addedOnce,
            // "Simplify", not a third "Fix": three would also teach the preferred-verbs note in step 4.
            outcome(2, polished: "Please simplify the cache layer.", final: "Simplify the cache layer."),
            outcome(3, polished: nil, final: "please update the README"),
            outcome(4, polished: "Resolve the logout bug. Run tests after edits.", final: "Please fix the logout bug. Run tests after edits."),
        ])
        #expect(r.steps[3].map(\.note.key) == ["verb:resolve>fix", "omit-word:please", addKey])
        #expect(learnedKeys(r.steps[3]) == ["verb:resolve>fix"])
        #expect(droppedKeys(r.steps[3]) == ["omit-word:please"])
        #expect(reinforcedKeys(r.steps[3]) == [addKey])
    }

    @Test func outcomesAreCappedAtFifty() {
        let many = (1...60).map { outcome($0, polished: nil, final: "unique line number \($0)") }
        let r = run(many)
        #expect(StyleProfile.maxOutcomes == 50)
        #expect(r.profile.outcomes.count == 50)
        #expect(r.profile.outcomes.first?.final == "unique line number 11")
        #expect(r.profile.outcomes.last?.final == "unique line number 60")
    }

    @Test func notesAreCappedAtForty() {
        // Every outcome adds one new line; the first one is kept alive by repeating it.
        let many = (1...60).map {
            outcome($0, polished: "Fix the login bug.", final: "Fix the login bug.\nalways keep rule \($0) alive\nrun tests after edits")
        }
        let r = run(many)
        #expect(r.profile.notes.count == 40)
        // The reinforced note survives; the oldest single-sighting notes went first.
        #expect(note(r.profile, addKey)?.count == 60)
        #expect(note(r.profile, "add:always keep rule 60 alive") != nil)
        #expect(note(r.profile, "add:always keep rule 1 alive") == nil)
        #expect(r.steps.allSatisfy { droppedKeys($0).isEmpty })
    }

    @Test func topNotesReturnsOnlyActiveNotesInOrder() {
        let r = run([
            // "run tests after edits" three times, "keep the diff small" twice, a length note still inactive.
            outcome(1, polished: "Fix the login bug.", final: "Fix the login bug. run tests after edits"),
            outcome(2, polished: "Fix the logout bug.", final: "Fix the logout bug. run tests after edits. keep the diff small"),
            outcome(3, polished: "Fix the signup bug in the auth module. Cover the change with unit tests. Note it in the changelog.",
                    final: "Fix the signup bug. run tests after edits. keep the diff small"),
            outcome(4, polished: "Rename the helper.", final: "Rename the helper. use small commits"),
        ])
        #expect(note(r.profile, "length.shorter")?.active == false)
        let top = r.profile.topNotes()
        #expect(top.allSatisfy { $0.active })
        #expect(Array(top.map(\.key).prefix(2)) == [addKey, "add:keep the diff small"])
        #expect(!top.contains { $0.key == "length.shorter" })
        #expect(r.profile.topNotes(limit: 1).map(\.key) == [addKey])
        #expect(r.profile.topNotes(limit: 0).isEmpty)
        // Equal counts: the most recent first.
        let tail = top.filter { $0.count == 1 }
        #expect(tail.map(\.updatedAt) == tail.map(\.updatedAt).sorted(by: >))
    }

    @Test func aHandEditedProfileWithDuplicateKeysDoesNotCrash() {
        let dup = StyleNote(key: addKey, text: "Add: “run tests after edits”", score: 1, count: 1, active: true, updatedAt: at(0))
        let start = StyleProfile(notes: [dup, dup])
        let r = run([kept(1, "Update the README.")], from: start)
        #expect(r.profile.notes.filter { $0.key == addKey }.count == 1)
        #expect(reinforcedKeys(r.steps[0]) == [addKey])
    }
}

// MARK: - Store

@Suite struct StyleProfileStoreTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nod-style-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func defaultFileIsStyleJSONInApplicationSupport() {
        #expect(StyleProfileStore.defaultFileURL.path.hasSuffix("/Nod/style.json"))
    }

    @Test func roundTripsThroughATempFile() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("support/Nod/style.json")
        let store = StyleProfileStore(fileURL: url)
        #expect(store.profile == .empty)
        let changes = store.record(addedOnce)
        #expect(changes.compactMap(\.chipText) == ["Learned: Add: “run tests after edits”"])
        store.record(kept(2, "Update the README."))

        let reloaded = StyleProfileStore(fileURL: url)
        #expect(reloaded.profile == store.profile)
        #expect(reloaded.profile.outcomes.count == 2)
        #expect(reloaded.profile.topNotes().map(\.key) == [addKey])
        // The file is the same bytes as encoding the profile: pretty, sorted keys, ISO 8601 dates.
        let bytes = try Data(contentsOf: url)
        #expect(bytes == (try encode(store.profile)))
        #expect(String(decoding: bytes, as: UTF8.self).contains("\"at\" : \"2023-11-14T22:14:20Z\""))
        // Nothing else is left next to it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["style.json"])
    }

    @Test func theFileIsOnlyReadableByTheUser() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("style.json")
        let store = StyleProfileStore(fileURL: url)
        func mode() throws -> Int {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        store.record(addedOnce)
        #expect(try mode() == 0o600)
        // A file that was left wide open is tightened by the next save.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        store.record(kept(2, "Update the README."))
        #expect(try mode() == 0o600)
        store.reset()
        #expect(try mode() == 0o600)
    }

    @Test func aCorruptOrMissingFileMeansAnEmptyProfile() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(StyleProfileStore(fileURL: dir.appendingPathComponent("missing.json")).profile == .empty)
        for (i, junk) in ["{ not json", "", "[]", "{\"version\":1}", "{\"notes\":\"nope\"}"].enumerated() {
            let url = dir.appendingPathComponent("corrupt-\(i).json")
            try Data(junk.utf8).write(to: url)
            let store = StyleProfileStore(fileURL: url)
            #expect(store.profile == .empty)
            // And it recovers: the next outcome replaces the junk.
            store.record(addedOnce)
            #expect(StyleProfileStore(fileURL: url).profile == store.profile)
        }
    }

    @Test func inMemoryStoreWorksWithoutAFile() {
        let store = StyleProfileStore(fileURL: nil)
        #expect(store.profile == .empty)
        #expect(store.record(addedOnce).count == 1)
        #expect(store.record(kept(2, "Update the README.")).compactMap(\.chipText).isEmpty)
        #expect(store.profile.topNotes().first?.count == 2)
        store.reset()
        #expect(store.profile == .empty)
    }

    @Test func resetEmptiesAndSaves() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("style.json")
        let store = StyleProfileStore(fileURL: url)
        store.record(addedOnce)
        #expect(!store.profile.notes.isEmpty)
        store.reset()
        #expect(store.profile == .empty)
        #expect(StyleProfileStore(fileURL: url).profile == .empty)
        #expect(try Data(contentsOf: url) == (try encode(.empty)))
    }

    @Test func aFailedSaveKeepsTheProfileInMemory() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // The parent "directory" is a plain file, so nothing can be written under it.
        let blocker = dir.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let store = StyleProfileStore(fileURL: blocker.appendingPathComponent("Nod/style.json"))
        #expect(store.record(addedOnce).count == 1)
        #expect(store.profile.topNotes().map(\.key) == [addKey])
        store.reset()
        #expect(store.profile == .empty)
        #expect(try Data(contentsOf: blocker) == Data("x".utf8))
    }

    @Test func theSameOutcomesWriteByteIdenticalFiles() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a/style.json"), b = dir.appendingPathComponent("b/style.json")
        for url in [a, b] {
            let store = StyleProfileStore(fileURL: url)
            for o in [addedOnce, deleted(2, "Update the README."), kept(3, "Rename the helper."),
                      outcome(4, polished: nil, final: "Fix the flaky test\nrun tests after edits")] {
                store.record(o)
            }
        }
        #expect(try Data(contentsOf: a) == (try Data(contentsOf: b)))
    }

    @Test func concurrentRecordsAreSerialized() async {
        let store = StyleProfileStore(fileURL: nil)
        await withTaskGroup(of: Void.self) { group in
            for i in 1...40 {
                group.addTask { store.record(outcome(i, polished: nil, final: "Fix thing number \(i)")) }
            }
        }
        #expect(store.profile.outcomes.count == 40)
        #expect(store.profile.verbCounts["fix"] == 40)
    }
}
