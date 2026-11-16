// CONTRACT FILE - read-only for builders. Report problems in open_issues.
// Verified against https://code.claude.com/docs/en/hooks on 2026-11-15 (Claude Code 2.1.325).
// Facts and quotes: docs/superpowers/plans/hook-contract.md
import Foundation

/// The `hook_event_name` of a Claude Code hook payload.
public enum HookEventName: Hashable, Sendable {
    case sessionStart, userPromptSubmit, preToolUse, postToolUse, postToolUseFailure
    case permissionRequest, notification, stop, subagentStop, sessionEnd
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "SessionStart": self = .sessionStart
        case "UserPromptSubmit": self = .userPromptSubmit
        case "PreToolUse": self = .preToolUse
        case "PostToolUse": self = .postToolUse
        case "PostToolUseFailure": self = .postToolUseFailure
        case "PermissionRequest": self = .permissionRequest
        case "Notification": self = .notification
        case "Stop": self = .stop
        case "SubagentStop": self = .subagentStop
        case "SessionEnd": self = .sessionEnd
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .sessionStart: return "SessionStart"
        case .userPromptSubmit: return "UserPromptSubmit"
        case .preToolUse: return "PreToolUse"
        case .postToolUse: return "PostToolUse"
        case .postToolUseFailure: return "PostToolUseFailure"
        case .permissionRequest: return "PermissionRequest"
        case .notification: return "Notification"
        case .stop: return "Stop"
        case .subagentStop: return "SubagentStop"
        case .sessionEnd: return "SessionEnd"
        case .other(let s): return s
        }
    }

    /// The events `scripts/install-hooks.sh` registers, in install order.
    public static let installed: [HookEventName] = [
        .sessionStart, .userPromptSubmit, .preToolUse, .postToolUse, .postToolUseFailure,
        .permissionRequest, .notification, .stop, .sessionEnd,
    ]
}

/// One decoded Claude Code hook payload (the JSON a command hook gets on stdin).
/// Unknown fields are ignored; every event-specific field is optional.
public struct HookEvent: Sendable, Equatable {
    // Common fields
    public var sessionID: String            // session_id
    public var eventName: HookEventName     // hook_event_name
    public var cwd: String                  // cwd ("" when absent)
    public var transcriptPath: String?      // transcript_path
    public var permissionMode: String?      // permission_mode: default|plan|acceptEdits|auto|dontAsk|bypassPermissions
    public var promptID: String?            // prompt_id
    public var agentID: String?             // agent_id (set when the hook fires inside a subagent)
    public var agentType: String?           // agent_type
    public var sessionTitle: String?        // session_title (custom title, when set)

    // SessionStart
    public var source: String?              // startup|resume|clear|compact|fork
    public var model: String?
    // UserPromptSubmit
    public var prompt: String?
    // PreToolUse / PostToolUse / PostToolUseFailure / PermissionRequest
    public var toolName: String?            // tool_name
    public var toolInput: JSONValue?        // tool_input
    public var toolUseID: String?           // tool_use_id (NOT sent on PermissionRequest)
    public var toolResponse: JSONValue?     // tool_response (PostToolUse)
    public var durationMs: Double?          // duration_ms
    public var error: String?               // PostToolUseFailure
    public var isInterrupt: Bool?           // is_interrupt
    public var permissionSuggestions: [JSONValue]?  // permission_suggestions (PermissionRequest)
    // Notification
    public var message: String?
    public var title: String?
    public var notificationType: String?    // notification_type: permission_prompt|idle_prompt|...
    // Stop
    public var stopHookActive: Bool?        // stop_hook_active
    public var lastAssistantMessage: String?  // last_assistant_message
    // SessionEnd
    public var reason: String?              // clear|resume|logout|prompt_input_exit|other

    public init(sessionID: String, eventName: HookEventName, cwd: String) {
        self.sessionID = sessionID
        self.eventName = eventName
        self.cwd = cwd
    }

    public enum DecodeError: Error, Equatable {
        case notAnObject
        case missingSessionID
        case missingEventName
    }

    /// Decodes a hook payload. `fallbackEventName` is used when the body has no
    /// `hook_event_name` (for example the event name taken from the URL path `/hook/<Event>`).
    public static func decode(_ data: Data, fallbackEventName: String? = nil) throws -> HookEvent {
        let json = try JSONValue.parse(data)
        guard case .object = json else { throw DecodeError.notAnObject }
        guard let sid = json.string("session_id"), !sid.isEmpty else { throw DecodeError.missingSessionID }
        guard let name = json.string("hook_event_name") ?? fallbackEventName, !name.isEmpty else {
            throw DecodeError.missingEventName
        }
        var e = HookEvent(sessionID: sid, eventName: HookEventName(rawValue: name), cwd: json.string("cwd") ?? "")
        e.transcriptPath = json.string("transcript_path")
        e.permissionMode = json.string("permission_mode")
        e.promptID = json.string("prompt_id")
        e.agentID = json.string("agent_id")
        e.agentType = json.string("agent_type")
        e.sessionTitle = json.string("session_title")
        e.source = json.string("source")
        e.model = json.string("model")
        e.prompt = json.string("prompt")
        e.toolName = json.string("tool_name")
        e.toolInput = json["tool_input"]
        e.toolUseID = json.string("tool_use_id")
        e.toolResponse = json["tool_response"]
        e.durationMs = json["duration_ms"]?.numberValue
        e.error = json.string("error")
        e.isInterrupt = json["is_interrupt"]?.boolValue
        e.permissionSuggestions = json["permission_suggestions"]?.arrayValue
        e.message = json.string("message")
        e.title = json.string("title")
        e.notificationType = json.string("notification_type")
        e.stopHookActive = json["stop_hook_active"]?.boolValue
        e.lastAssistantMessage = json.string("last_assistant_message")
        e.reason = json.string("reason")
        return e
    }
}

/// The user's answer to a permission request.
public enum Decision: Sendable, Equatable {
    case allow
    /// `message` is shown to Claude as the reason ("tells Claude why the permission was denied").
    case deny(message: String?)

    public var isAllow: Bool { self == .allow }
}

/// Builds the exact JSON Claude Code expects on a hook's stdout.
public enum HookOutput {
    public static let defaultDenyMessage = "Denied from notchAgent."

    /// PermissionRequest decision:
    /// `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`
    /// or `{"...":{"decision":{"behavior":"deny","message":"..."}}}`. Never sets `interrupt`,
    /// `updatedInput` or `updatedPermissions`.
    public static func permissionRequest(_ decision: Decision) -> Data {
        // Built by hand so the bytes match hook-contract.md section 3 exactly (key order included).
        let d: String
        switch decision {
        case .allow:
            d = #"{"behavior":"allow"}"#
        case .deny(let message):
            d = #"{"behavior":"deny","message":"# + jsonString(message ?? defaultDenyMessage) + "}"
        }
        return Data((#"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":"# + d + "}}").utf8)
    }

    /// `s` as a JSON string literal, quotes included.
    private static func jsonString(_ s: String) -> String {
        String(decoding: encode(.string(s)), as: UTF8.self)
    }

    /// Fallback shape for a PreToolUse hook (not installed by default; kept for reference/tests):
    /// `permissionDecision` is `allow`, `deny`, or `ask` when there is no decision.
    public static func preToolUse(_ decision: Decision?, reason: String = "Decided in notchAgent") -> Data {
        let value: String
        switch decision {
        case .allow?: value = "allow"
        case .deny?: value = "deny"
        case nil: value = "ask"
        }
        let out: JSONValue = ["hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": .string(value),
            "permissionDecisionReason": .string(reason),
        ]]
        return encode(out)
    }

    private static func encode(_ v: JSONValue) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(v)) ?? Data("{}".utf8)
    }
}

/// What the HTTP server sends back for one hook POST.
public enum HookResponse: Sendable, Equatable {
    /// Non-permission event accepted. HTTP 200, body `{"ok":true}`. The hook script prints nothing.
    case ack
    /// PermissionRequest answered. HTTP 200, body = `HookOutput.permissionRequest(decision)`.
    case decision(Decision)
    /// PermissionRequest not answered (timeout, pass-through tool, notchAgent declined to decide).
    /// HTTP 204, empty body, so the hook prints nothing and Claude Code shows its own prompt.
    case noDecision
}
