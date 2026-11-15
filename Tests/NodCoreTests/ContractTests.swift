// SHARED CONTRACT TESTS - read-only for builders. They pin the hook wire format.
import Foundation
import Testing
import NodCore

@Suite struct HookPayloadContractTests {
    @Test func everyFixtureDecodes() throws {
        for name in Fixture.all {
            let e = try Fixture.event(name)
            #expect(e.sessionID == Fixture.sessionID, "\(name)")
            #expect(e.cwd == Fixture.repo, "\(name)")
            if case .other(let raw) = e.eventName { Issue.record("\(name): unknown event \(raw)") }
        }
    }

    @Test func permissionRequestFields() throws {
        let e = try Fixture.event("permission-request-bash-npm-test")
        #expect(e.eventName == .permissionRequest)
        #expect(e.toolName == "Bash")
        #expect(e.toolInput?.string("command") == "npm test -- src/auth")
        #expect(e.toolUseID == nil)  // PermissionRequest has no tool_use_id
        #expect(e.permissionSuggestions?.count == 1)
        #expect(e.permissionMode == "default")
    }

    @Test func editRequestCarriesOldAndNewStrings() throws {
        let e = try Fixture.event("permission-request-edit")
        #expect(e.toolInput?.string("file_path") == "\(Fixture.repo)/src/auth/session.ts")
        #expect(e.toolInput?.string("old_string")?.contains("SessionError") == true)
        #expect(e.toolInput?.string("new_string")?.contains("refreshAndRetry") == true)
    }

    @Test func eventSpecificFields() throws {
        #expect(try Fixture.event("session-start").source == "startup")
        #expect(try Fixture.event("user-prompt-submit").prompt == "add token refresh to auth")
        #expect(try Fixture.event("notification-permission-prompt").notificationType == "permission_prompt")
        #expect(try Fixture.event("stop").lastAssistantMessage?.isEmpty == false)
        #expect(try Fixture.event("session-end").reason == "prompt_input_exit")
        let failure = try Fixture.event("post-tool-use-failure-bash")
        #expect(failure.eventName == .postToolUseFailure)
        #expect(failure.error?.hasPrefix("Exit code 1") == true)
        #expect(try Fixture.event("post-tool-use-bash").durationMs == 4187)
    }

    @Test func unknownFieldsAndEventsAreTolerated() throws {
        let data = Data(#"{"session_id":"s1","hook_event_name":"PostToolBatch","cwd":"/tmp","brand_new_field":{"a":[1,2]}}"#.utf8)
        let e = try HookEvent.decode(data)
        #expect(e.eventName == .other("PostToolBatch"))
    }

    @Test func eventNameFallsBackToThePath() throws {
        let data = Data(#"{"session_id":"s1","cwd":"/tmp"}"#.utf8)
        #expect(try HookEvent.decode(data, fallbackEventName: "Stop").eventName == .stop)
        #expect(throws: HookEvent.DecodeError.missingEventName) { try HookEvent.decode(data) }
        #expect(throws: HookEvent.DecodeError.missingSessionID) { try HookEvent.decode(Data(#"{"hook_event_name":"Stop"}"#.utf8)) }
    }

    @Test func eventNamesRoundTrip() {
        for name in HookEventName.installed { #expect(HookEventName(rawValue: name.rawValue) == name) }
        #expect(HookEventName.installed.contains(.permissionRequest))
    }
}

@Suite struct HookOutputContractTests {
    @Test func allowOutputMatchesTheDocs() throws {
        let json = try JSONValue.parse(HookOutput.permissionRequest(.allow))
        let expected: JSONValue = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": ["behavior": "allow"]]]
        #expect(json == expected)
    }

    @Test func denyOutputCarriesAMessageAndNeverInterrupts() throws {
        let json = try JSONValue.parse(HookOutput.permissionRequest(.deny(message: "Not that folder")))
        let decision = json["hookSpecificOutput"]?["decision"]
        #expect(decision?.string("behavior") == "deny")
        #expect(decision?.string("message") == "Not that folder")
        #expect(decision?["interrupt"] == nil)
        let fallback = try JSONValue.parse(HookOutput.permissionRequest(.deny(message: nil)))
        #expect(fallback["hookSpecificOutput"]?["decision"]?.string("message") == HookOutput.defaultDenyMessage)
    }

    @Test func preToolUseFallbackShape() throws {
        let ask = try JSONValue.parse(HookOutput.preToolUse(nil))
        #expect(ask["hookSpecificOutput"]?.string("permissionDecision") == "ask")
        #expect(ask["hookSpecificOutput"]?.string("hookEventName") == "PreToolUse")
    }
}

@Suite struct ModelContractTests {
    @Test func riskLevelsOrderAndRaise() {
        #expect(RiskLevel.low < .review && RiskLevel.review < .high)
        #expect(RiskLevel.low.raised == .review && RiskLevel.high.raised == .high)
    }

    @Test func highRiskDefaultsToDeny() {
        let high = PendingRequest(sessionID: "s", toolName: "Bash", toolInput: [:], cwd: "/r",
                                  assessment: Assessment(level: .high, title: "x"), receivedAt: Date())
        let low = PendingRequest(sessionID: "s", toolName: "Bash", toolInput: [:], cwd: "/r",
                                 assessment: Assessment(level: .low, title: "x"), receivedAt: Date())
        #expect(high.defaultDecision == .deny(message: nil) && high.requiresHoldToAllow)
        #expect(low.defaultDecision == .allow && !low.requiresHoldToAllow)
    }

    @Test func diffSummary() {
        let d = DiffPreview(fileName: "a.ts", filePath: "/r/a.ts", added: 12, removed: 4, lines: [], moreFiles: 1)
        #expect(d.summary == "+12 −4 · and 1 more file")
    }
}
