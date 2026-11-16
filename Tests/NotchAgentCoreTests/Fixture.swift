// SHARED TEST HELPER - read-only for builders.
import Foundation
import NotchAgentCore

enum Fixture {
    /// Loads `Tests/NotchAgentCoreTests/Fixtures/<name>.json` from the test bundle.
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "Fixtures/\(name).json"])
        }
        return try Data(contentsOf: url)
    }

    static func event(_ name: String) throws -> HookEvent {
        try HookEvent.decode(try data(name))
    }

    static let all = [
        "session-start", "user-prompt-submit", "pre-tool-use-read", "post-tool-use-read",
        "pre-tool-use-bash", "post-tool-use-bash", "post-tool-use-edit", "post-tool-use-grep",
        "post-tool-use-failure-bash", "permission-request-bash-npm-test", "permission-request-edit",
        "permission-request-bash-rm-rf-outside", "permission-request-write-env", "permission-request-webfetch",
        "permission-request-ask-user-question", "notification-permission-prompt", "notification-idle-prompt",
        "stop", "session-end",
    ]

    /// The cwd every fixture uses.
    static let repo = "/Users/dev/code/acme-web"
    static let sessionID = "7f3c2a10-5b1e-4c7a-9d54-0e2b6a1f9c33"
}
