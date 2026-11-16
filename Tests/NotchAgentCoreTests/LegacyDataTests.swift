import Foundation
import Testing
@testable import NotchAgentCore

@Suite("Data folder from before the rename")
struct LegacyDataTests {
    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("notch-agent-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test func theOldFolderMovesToTheNewName() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let old = base.appendingPathComponent("Nod")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data(#"{"rules":[]}"#.utf8).write(to: old.appendingPathComponent("rules.json"))

        #expect(LegacyData.migrate(base: base))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        let moved = base.appendingPathComponent("notchAgent/rules.json")
        #expect(try Data(contentsOf: moved) == Data(#"{"rules":[]}"#.utf8))
        #expect(!LegacyData.migrate(base: base), "a second run does nothing")
    }

    @Test func anExistingNewFolderIsNeverOverwritten() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        for name in ["Nod", "notchAgent"] {
            let dir = base.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(name.utf8).write(to: dir.appendingPathComponent("rules.json"))
        }
        #expect(!LegacyData.migrate(base: base))
        #expect(try Data(contentsOf: base.appendingPathComponent("notchAgent/rules.json")) == Data("notchAgent".utf8))
        #expect(try Data(contentsOf: base.appendingPathComponent("Nod/rules.json")) == Data("Nod".utf8))
    }

    @Test func nothingToMoveIsANoOp() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(!LegacyData.migrate(base: base))
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
    }
}
