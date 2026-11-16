// SHARED TEST HELPER - read-only for builders.
// Loads the shared fixtures from Tests/NotchAgentCoreTests/Fixtures by source path (no bundle needed).
import Foundation
import NotchAgentCore

enum BridgeFixture {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // NotchAgentBridgeTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root

    static let fixturesDir: URL = repoRoot.appendingPathComponent("Tests/NotchAgentCoreTests/Fixtures")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: fixturesDir.appendingPathComponent("\(name).json"))
    }

    static func event(_ name: String) throws -> HookEvent {
        try HookEvent.decode(try data(name))
    }

    static let repo = "/Users/dev/code/acme-web"
    static let sessionID = "7f3c2a10-5b1e-4c7a-9d54-0e2b6a1f9c33"
}
