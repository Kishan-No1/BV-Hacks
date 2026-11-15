// OWNER: workstream B (bridge). The public signatures below are FROZEN; bodies are placeholders.
import Foundation

public enum HookServerError: Error, Equatable {
    case notImplemented
    case portInUse(UInt16)
    case failed(String)
}

/// Localhost-only HTTP server that receives Claude Code hook payloads.
///
/// Routes (HTTP/1.1, `Connection: close`):
/// - `GET /health` -> 200 `{"app":"nod","ok":true}`
/// - `POST /hook/<EventName>` with the hook JSON as body. The event name comes from the body's
///   `hook_event_name`, falling back to the path. The handler's `HookResponse` maps to:
///   `.ack` -> 200 `{"ok":true}`; `.decision(d)` -> 200 + `HookOutput.permissionRequest(d)`;
///   `.noDecision` -> 204 with an empty body.
/// - Undecodable body -> 400 (the hook script prints nothing for any non-200). Anything else -> 404.
///
/// The handler runs in a `Task` per request. For `PermissionRequest` it may suspend for minutes;
/// the connection is held open meanwhile. If the client disconnects first, the server CANCELS that
/// task (this is how `SessionStore.requestDecision` learns the request went away).
public final class HookServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HookEvent) async -> HookResponse

    public static let defaultPort: UInt16 = 47474

    private let requestedPort: UInt16
    private let handler: Handler

    /// - Parameter port: 0 binds any free port (tests).
    public init(port: UInt16 = HookServer.defaultPort, handler: @escaping Handler) {
        self.requestedPort = port
        self.handler = handler
    }

    /// The bound port while running, else nil.
    public var port: UInt16? { nil }

    /// Starts listening on 127.0.0.1 only. Returns the bound port once the listener is ready.
    /// Throws `HookServerError.portInUse` when the port is taken.
    @discardableResult
    public func start() async throws -> UInt16 {
        // SCAFFOLD PLACEHOLDER - workstream B implements this with Network.framework.
        _ = (requestedPort, handler)
        throw HookServerError.notImplemented
    }

    /// Stops listening and closes every open connection (held requests end with no decision). Idempotent.
    public func stop() {}
}
