// OWNER: workstream B (bridge). The public signatures below are FROZEN (additions are fine).
import Foundation
import Network

public enum HookServerError: Error, Equatable {
    case notImplemented
    case portInUse(UInt16)
    case failed(String)
}

/// Localhost-only HTTP server that receives Claude Code hook payloads.
///
/// Routes (HTTP/1.1, `Connection: close`):
/// - `GET /health` -> 200 `{"app":"notchAgent","ok":true}`
/// - `POST /hook/<EventName>` with the hook JSON as body. The event name comes from the body's
///   `hook_event_name`, falling back to the path. The handler's `HookResponse` maps to:
///   `.ack` -> 200 `{"ok":true}`; `.decision(d)` -> 200 + `HookOutput.permissionRequest(d)`;
///   `.noDecision` -> 204 with an empty body.
/// - Undecodable body -> 400 (the hook script prints nothing for any non-200). Anything else -> 404.
///
/// Only local tools may talk to it, never a web page the user happens to have open: a request with an
/// `Origin` header or a `Host` other than `127.0.0.1` / `localhost` (DNS rebinding) is refused with 403,
/// and a POST must be `Content-Type: application/json` (415 otherwise), which a page cannot send without
/// a CORS preflight that is never answered.
///
/// The handler runs in a `Task` per request. For `PermissionRequest` it may suspend for minutes;
/// the connection is held open meanwhile. If the client disconnects first, the server CANCELS that
/// task (this is how `SessionStore.requestDecision` learns the request went away).
public final class HookServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HookEvent) async -> HookResponse

    public static let defaultPort: UInt16 = 47474
    /// Largest request body accepted (413 above it).
    public static let maxBodyBytes = HTTPRequestParser.defaultMaxBodyBytes

    private let requestedPort: UInt16
    private let handler: Handler
    private let queue = DispatchQueue(label: "app.notchagent.hook-server")
    private let queueKey = DispatchSpecificKey<Bool>()

    // Guarded by `lock`.
    private let lock = NSLock()
    private var listener: NWListener?
    private var boundPort: UInt16?
    private var startContinuation: CheckedContinuation<UInt16, Error>?
    private var listenerCancelled: DispatchSemaphore?
    private var connections: [ObjectIdentifier: HookConnection] = [:]

    /// - Parameter port: 0 binds any free port (tests).
    public init(port: UInt16 = HookServer.defaultPort, handler: @escaping Handler) {
        self.requestedPort = port
        self.handler = handler
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        listener?.cancel()
    }

    /// The bound port while running, else nil.
    public var port: UInt16? {
        lock.lock(); defer { lock.unlock() }
        return boundPort
    }

    /// Number of open client connections (held permission requests included).
    public var openConnectionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return connections.count
    }

    /// Starts listening on 127.0.0.1 only. Returns the bound port once the listener is ready.
    /// Throws `HookServerError.portInUse` when the port is taken. Calling it while running returns the port.
    @discardableResult
    public func start() async throws -> UInt16 {
        let (isListening, running) = lock.withLock { (listener != nil, boundPort) }
        if isListening {
            if let running { return running }
            throw HookServerError.failed("start() is already in progress")
        }

        guard let nwPort = NWEndpoint.Port(rawValue: requestedPort) else {
            throw HookServerError.failed("invalid port \(requestedPort)")
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        parameters.acceptLocalOnly = true

        let newListener: NWListener
        do {
            newListener = try NWListener(using: parameters)
        } catch {
            throw mapError(error)
        }
        let cancelled = DispatchSemaphore(value: 0)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            lock.lock()
            if listener != nil {  // lost a race with a concurrent start()
                lock.unlock()
                cont.resume(throwing: HookServerError.failed("start() is already in progress"))
                return
            }
            listener = newListener
            startContinuation = cont
            listenerCancelled = cancelled
            lock.unlock()

            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                guard let self, let newListener else { return }
                self.listenerStateChanged(newListener, state, cancelled: cancelled)
            }
            newListener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.accept(connection)
            }
            newListener.start(queue: queue)
        }
    }

    /// Stops listening and closes every open connection (held requests end with no decision). Idempotent.
    /// Returns once the listening socket is closed, so the same port can be bound again right away.
    public func stop() {
        lock.lock()
        let oldListener = listener
        let cancelled = listenerCancelled
        let pendingStart = startContinuation
        let open = Array(connections.values)
        listener = nil
        boundPort = nil
        startContinuation = nil
        listenerCancelled = nil
        connections.removeAll()
        lock.unlock()

        pendingStart?.resume(throwing: HookServerError.failed("stopped"))
        if !open.isEmpty { onQueue { for c in open { c.close() } } }
        guard let oldListener else { return }
        oldListener.cancel()
        if !isOnQueue { _ = cancelled?.wait(timeout: .now() + 1) }
    }

    // MARK: Routing (pure, unit-tested)

    enum Route: Equatable {
        case respond(HTTPResponse)
        case hook(HookEvent)
    }

    static let healthBody = #"{"app":"notchAgent","ok":true}"#
    static let ackBody = #"{"ok":true}"#
    private static let hookPrefix = "/hook/"

    /// The refusal for a request that did not come from a local tool, or nil when it may be routed.
    /// `port` is the bound port; nil skips the port part of the Host check.
    static func rejection(for request: HTTPRequest, port: UInt16?) -> HTTPResponse? {
        let forbidden = HTTPResponse.json(403, #"{"ok":false,"error":"local requests only"}"#)
        // Browsers add Origin to every cross-origin request and to every POST; curl and the hook never do.
        if request.header("origin") != nil { return forbidden }
        if let site = request.header("sec-fetch-site")?.lowercased(), site != "none", site != "same-origin" { return forbidden }
        guard let host = request.header("host")?.lowercased(), isLoopbackHost(host, port: port) else { return forbidden }
        if request.method == "POST" {
            let type = request.header("content-type")?.lowercased() ?? ""
            let media = type.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if media != "application/json" {
                return .json(415, #"{"ok":false,"error":"Content-Type must be application/json"}"#)
            }
        }
        return nil
    }

    /// `127.0.0.1`, `localhost` or `[::1]`, alone or with `:<port>` (which must be the bound port).
    static func isLoopbackHost(_ host: String, port: UInt16?) -> Bool {
        for name in ["127.0.0.1", "localhost", "[::1]"] {
            if host == name { return true }
            if host.hasPrefix(name + ":") {
                let given = host.dropFirst(name.count + 1)
                guard let n = UInt16(given) else { return false }
                return port == nil || n == port
            }
        }
        return false
    }

    static func route(_ request: HTTPRequest) -> Route {
        switch (request.method, request.path) {
        case ("GET", "/health"), ("HEAD", "/health"):
            return .respond(.json(200, healthBody))
        case ("POST", let path) where path.hasPrefix(hookPrefix):
            let name = String(path.dropFirst(hookPrefix.count))
            guard !name.contains("/") else { return .respond(HTTPResponse(status: 404)) }
            do {
                return .hook(try HookEvent.decode(request.body, fallbackEventName: name.isEmpty ? nil : name))
            } catch {
                return .respond(.json(400, #"{"ok":false,"error":"undecodable hook payload"}"#))
            }
        default:
            return .respond(HTTPResponse(status: 404))
        }
    }

    static func httpResponse(for response: HookResponse) -> HTTPResponse {
        switch response {
        case .ack: return .json(200, ackBody)
        case .decision(let decision): return .json(200, HookOutput.permissionRequest(decision))
        case .noDecision: return HTTPResponse(status: 204)
        }
    }

    // MARK: Internals (on `queue`)

    private func listenerStateChanged(_ l: NWListener, _ state: NWListener.State, cancelled: DispatchSemaphore) {
        switch state {
        case .ready:
            lock.lock()
            guard listener === l else { lock.unlock(); return }
            let port = l.port?.rawValue ?? requestedPort
            boundPort = port
            let cont = startContinuation
            startContinuation = nil
            lock.unlock()
            cont?.resume(returning: port)

        case .failed(let error), .waiting(let error):
            // Before .ready, .waiting means the bind failed: give up instead of retrying silently.
            // After .ready, only .failed ends the listener.
            lock.lock()
            let isCurrent = listener === l
            let cont = isCurrent ? startContinuation : nil
            let giveUp = isCurrent && (cont != nil || isFailure(state))
            if giveUp {
                listener = nil
                boundPort = nil
                startContinuation = nil
                listenerCancelled = nil
            }
            lock.unlock()
            if giveUp { l.cancel() }
            cont?.resume(throwing: mapError(error))

        case .cancelled:
            cancelled.signal()
            lock.lock()
            let isCurrent = listener === l
            let cont = isCurrent ? startContinuation : nil
            if isCurrent {
                listener = nil
                boundPort = nil
                startContinuation = nil
                listenerCancelled = nil
            }
            lock.unlock()
            cont?.resume(throwing: HookServerError.failed("listener cancelled"))

        default:
            break
        }
    }

    private func isFailure(_ state: NWListener.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func accept(_ nw: NWConnection) {
        let connection = HookConnection(connection: nw, queue: queue, handler: handler,
                                        maxBodyBytes: Self.maxBodyBytes, port: { [weak self] in self?.port }) { [weak self] c in
            self?.forget(c)
        }
        lock.lock()
        guard listener != nil else {
            lock.unlock()
            nw.cancel()
            return
        }
        connections[ObjectIdentifier(connection)] = connection
        lock.unlock()
        connection.start()
    }

    private func forget(_ connection: HookConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    private var isOnQueue: Bool { DispatchQueue.getSpecific(key: queueKey) == true }

    private func onQueue(_ work: () -> Void) {
        if isOnQueue { work() } else { queue.sync(execute: work) }
    }

    private func mapError(_ error: Error) -> HookServerError {
        if let nw = error as? NWError, case .posix(let code) = nw, code == .EADDRINUSE {
            return .portInUse(requestedPort)
        }
        if let posix = error as? POSIXError, posix.code == .EADDRINUSE {
            return .portInUse(requestedPort)
        }
        return .failed(String(describing: error))
    }
}
