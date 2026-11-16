// OWNER: workstream A (core-logic).
import Foundation
import Testing
import NotchAgentCore

@Suite struct DiffPreviewTests {
    private let path = "/Users/dev/code/acme-web/src/auth/session.ts"

    @Test func commonLeadingAndTrailingLinesAreDropped() {
        let d = DiffPreviewBuilder.edit(filePath: path, oldString: "a\nb\nc\nd", newString: "a\nB\nC\nd")
        #expect(d.fileName == "session.ts")
        #expect(d.filePath == path)
        #expect(d.removed == 2)
        #expect(d.added == 2)
        #expect(d.lines == [
            DiffLine(kind: .removed, text: "b"), DiffLine(kind: .removed, text: "c"),
            DiffLine(kind: .added, text: "B"), DiffLine(kind: .added, text: "C"),
        ])
        #expect(d.moreFiles == 0)
    }

    @Test func pureInsertionKeepsTheOldLineAsContext() {
        let d = DiffPreviewBuilder.edit(filePath: path, oldString: "x", newString: "new\nx")
        #expect(d.added == 1)
        #expect(d.removed == 0)
        #expect(d.lines == [DiffLine(kind: .added, text: "new")])
    }

    @Test func pureDeletion() {
        let d = DiffPreviewBuilder.edit(filePath: path, oldString: "a\nb\nc", newString: "a\nc")
        #expect(d.added == 0)
        #expect(d.removed == 1)
        #expect(d.lines == [DiffLine(kind: .removed, text: "b")])
    }

    @Test func identicalStringsGiveAnEmptyDiff() {
        let d = DiffPreviewBuilder.edit(filePath: path, oldString: "same\nlines", newString: "same\nlines")
        #expect(d.added == 0 && d.removed == 0 && d.lines.isEmpty)
    }

    @Test func atMostThreeRemovedThenThreeAdded() {
        let old = (1...10).map { "old \($0)" }.joined(separator: "\n")
        let new = (1...8).map { "new \($0)" }.joined(separator: "\n")
        let d = DiffPreviewBuilder.edit(filePath: path, oldString: old, newString: new)
        #expect(d.removed == 10)
        #expect(d.added == 8)
        #expect(d.lines.map(\.kind) == [DiffLine.Kind.removed, .removed, .removed, .added, .added, .added])
        #expect(d.lines[0].text == "old 1")
        #expect(d.lines[3].text == "new 1")
    }

    @Test func longLinesAreCutTo120Characters() {
        let long = String(repeating: "x", count: 300)
        let d = DiffPreviewBuilder.edit(filePath: path, oldString: "", newString: long)
        #expect(d.lines.count == 1)
        #expect(d.lines[0].text.count == 120)
        #expect(d.lines[0].text.hasSuffix("…"))
    }

    @Test func overlappingPrefixAndSuffixDoNotDoubleCount() {
        // "a" is both a common prefix and a common suffix candidate.
        let d = DiffPreviewBuilder.edit(filePath: path, oldString: "a", newString: "a\na")
        #expect(d.added == 1)
        #expect(d.removed == 0)
    }

    @Test func windowsLineEndingsAreNormalized() {
        let d = DiffPreviewBuilder.edit(filePath: path, oldString: "a\r\nb", newString: "a\r\nc")
        #expect(d.removed == 1 && d.added == 1)
        #expect(d.lines == [DiffLine(kind: .removed, text: "b"), DiffLine(kind: .added, text: "c")])
    }

    @Test func writeAddsEveryLineAndShowsFour() {
        let d = DiffPreviewBuilder.write(filePath: "/r/.env.local", content: "1\n2\n3\n4\n5\n6\n")
        #expect(d.fileName == ".env.local")
        #expect(d.added == 6)
        #expect(d.removed == 0)
        #expect(d.lines == ["1", "2", "3", "4"].map { DiffLine(kind: .added, text: $0) })
    }

    @Test func writeOfEmptyContent() {
        let d = DiffPreviewBuilder.write(filePath: "/r/empty.txt", content: "")
        #expect(d.added == 0 && d.lines.isEmpty)
    }

    @Test func multiEditSumsCountsAndPreviewsTheFirstEdit() {
        let d = DiffPreviewBuilder.multiEdit(filePath: path, edits: [
            (old: "a\nb", new: "a\nB"),
            (old: "x", new: "y\nz"),
        ])
        #expect(d.removed == 2)
        #expect(d.added == 3)
        #expect(d.lines == [DiffLine(kind: .removed, text: "b"), DiffLine(kind: .added, text: "B")])
    }

    @Test func requestFixtureDiff() throws {
        let e = try Fixture.event("permission-request-edit")
        let d = try #require(RiskEngine().assess(toolName: "Edit", toolInput: e.toolInput ?? .null, cwd: e.cwd).diff)
        #expect(d.summary == "+1 −0")
        #expect(d.lines == [DiffLine(kind: .added, text: "  if (res.status === 401) return refreshAndRetry(token);")])
    }
}
