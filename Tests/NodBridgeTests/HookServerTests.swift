// OWNER: workstream B (bridge). A REAL loopback HookServer on port 0, driven with URLSession and raw NWConnection.
import Foundation
import Network
import Testing
@testable import NodCore

// MARK: - Shared test helpers (used by the other NodBridgeTests files too)

/// Polls `condition` every 10 ms until it holds or `timeout` passes.
func eventually(
    timeout: Duration = .seconds(5),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Records what a test handler saw.
actor Recorder {
    private(set) var events: [HookEvent] = []
    private(set) var started = 0
    private(set) var cancelled = 0
    private(set) var finished = 0

    func record(_ e: HookEvent) { events.append(e) }
    func didStart() { started += 1 }
    func didCancel() { cancelled += 1 }
    func didFinish() { finished += 1 }
    var eventNames: [String] { events.map(\.eventName.rawValue) }
}

/// Holds handler calls (keyed by session id) until the test releases them.
actor Gate {
    private var waiters: [String: CheckedContinuation<HookResponse, Never>] = [:]

    func hold(_ key: String) async -> HookResponse {
        await withCheckedContinuation { waiters[key] = $0 }
    }

    func isHolding(_ key: String) -> Bool { waiters[key] != nil }
    var holdingCount: Int { waiters.count }

    func release(_ key: String, with response: HookResponse) {
        waiters.removeValue(forKey: key)?.resume(returning: response)
    }
}

/// A handler that sleeps (cancellably) for a long time and records whether it was cancelled.
func sleepingHandler(_ recorder: Recorder, seconds: Double = 30) -> HookServer.Handler {
    { event in
        await recorder.record(event)
        await recorder.didStart()
        do {
            try await Task.sleep(for: .seconds(seconds))
        } catch {
            await recorder.didCancel()
            return .noDecision
        }
        await recorder.didFinish()
        return .noDecision
    }
}

struct HTTPReply: Sendable {
    var status: Int
    var body: Data
    var headers: [String: String]  // lowercased names

    var bodyString: String { String(decoding: body, as: UTF8.self) }
}

enum HTTPClient {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 120
        c.httpMaximumConnectionsPerHost = 16
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.connectionProxyDictionary = [:]
        return URLSession(configuration: c)
    }()

    static func request(_ method: String, port: UInt16, path: String, body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        r.httpMethod = method
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    static func send(_ method: String, port: UInt16, path: String, body: Data? = nil) async throws -> HTTPReply {
        let (data, response) = try await session.data(for: request(method, port: port, path: path, body: body))
        let http = response as! HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http.allHeaderFields { headers[String(describing: k).lowercased()] = String(describing: v) }
        return HTTPReply(status: http.statusCode, body: data, headers: headers)
    }

    static func post(port: UInt16, event: String, body: Data) async throws -> HTTPReply {
        try await send("POST", port: port, path: "/hook/\(event)", body: body)
    }
}

/// A raw TCP client, for split writes and for closing the socket at a precise moment.
final class RawClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "nod.tests.raw-client")

    init(port: UInt16) {
        connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func connect() async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { cont.resume() }
                case .failed(let e), .waiting(let e): if once.take() { cont.resume(throwing: e) }
                case .cancelled: if once.take() { cont.resume(throwing: CancellationError()) }
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    /// Reads until the server closes the connection.
    func receiveAll() async throws -> Data {
        var all = Data()
        while true {
            let (chunk, done): (Data, Bool) = try await withCheckedThrowingContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let error, (data ?? Data()).isEmpty, !isComplete { cont.resume(throwing: error); return }
                    cont.resume(returning: (data ?? Data(), isComplete || error != nil))
                }
            }
            all.append(chunk)
            if done { return all }
        }
    }

    func close() { connection.cancel() }

    /// Splits a raw HTTP response into status and body.
    static func parse(_ raw: Data) -> HTTPReply? {
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: raw[raw.startIndex..<sep.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return HTTPReply(status: status, body: Data(raw[sep.upperBound...]), headers: headers)
    }
}

/// Resume-once guard for continuations fed by callbacks that can fire more than once.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Returns a copy of a fixture with `session_id` replaced.
func fixture(_ name: String, sessionID: String? = nil, removing keys: [String] = []) throws -> Data {
    let data = try BridgeFixture.data(name)
    guard sessionID != nil || !keys.isEmpty else { return data }
    var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    if let sessionID { obj["session_id"] = sessionID }
    for k in keys { obj.removeValue(forKey: k) }
    return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
}

/// Starts a server on an ephemeral loopback port.
func startServer(_ handler: @escaping HookServer.Handler) async throws -> (HookServer, UInt16) {
    let server = HookServer(port: 0, handler: handler)
    let port = try await server.start()
    return (server, port)
}

// MARK: - HookServer over real sockets

@Suite(.timeLimit(.minutes(1))) struct HookServerTests {
    @Test func healthReportsTheApp() async throws {
        let (server, port) = try await startServer { _ in .ack }
        defer { server.stop() }
        #expect(port != 0)
        #expect(server.port == port)
        let reply = try await HTTPClient.send("GET", port: port, path: "/health")
        #expect(reply.status == 200)
        #expect(reply.bodyString == #"{"app":"nod","ok":true}"#)
        #expect(reply.headers["content-type"] == "application/json")
        #expect(reply.headers["connection"]?.lowercased() == "close")
    }

    @Test func nonPermissionEventIsAcknowledgedAndReachesTheHandler() async throws {
        let recorder = Recorder()
        let (server, port) = try await startServer { event in
            await recorder.record(event)
            return .ack
        }
        defer { server.stop() }
        let reply = try await HTTPClient.post(port: port, event: "PreToolUse", body: try BridgeFixture.data("pre-tool-use-bash"))
        #expect(reply.status == 200)
        #expect(reply.bodyString == #"{"ok":true}"#)
        let events = await recorder.events
        #expect(events.count == 1)
        #expect(events.first?.eventName == .preToolUse)
        #expect(events.first?.toolName == "Bash")
        #expect(events.first?.sessionID == BridgeFixture.sessionID)
    }

    @Test func eventNameFallsBackToThePath() async throws {
        let recorder = Recorder()
        let (server, port) = try await startServer { event in
            await recorder.record(event)
            return .ack
        }
        defer { server.stop() }
        let body = try fixture("stop", removing: ["hook_event_name"])
        let reply = try await HTTPClient.post(port: port, event: "Stop", body: body)
        #expect(reply.status == 200)
        #expect(await recorder.events.first?.eventName == .stop)
    }

    @Test func heldPermissionRequestReturnsTheAllowJSONOnceTheHandlerResumes() async throws {
        let gate = Gate()
        let (server, port) = try await startServer { event in await gate.hold(event.sessionID) }
        defer { server.stop() }
        let body = try BridgeFixture.data("permission-request-bash-npm-test")
        let call = Task { try await HTTPClient.post(port: port, event: "PermissionRequest", body: body) }
        #expect(await eventually { await gate.isHolding(BridgeFixture.sessionID) })
        try await Task.sleep(for: .milliseconds(150))
        await gate.release(BridgeFixture.sessionID, with: .decision(.allow))
        let reply = try await call.value
        #expect(reply.status == 200)
        #expect(reply.body == HookOutput.permissionRequest(.allow))
        #expect(reply.bodyString == #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#)
        #expect(reply.headers["content-type"] == "application/json")
    }

    @Test func denyReturnsTheDenyJSON() async throws {
        let (server, port) = try await startServer { _ in .decision(.deny(message: "Not now")) }
        defer { server.stop() }
        let reply = try await HTTPClient.post(port: port, event: "PermissionRequest",
                                              body: try BridgeFixture.data("permission-request-bash-rm-rf-outside"))
        #expect(reply.status == 200)
        #expect(reply.body == HookOutput.permissionRequest(.deny(message: "Not now")))
        #expect(reply.headers["content-type"] == "application/json")
    }

    @Test func noDecisionIs204WithAnEmptyBody() async throws {
        let (server, port) = try await startServer { _ in .noDecision }
        defer { server.stop() }
        let reply = try await HTTPClient.post(port: port, event: "PermissionRequest",
                                              body: try BridgeFixture.data("permission-request-edit"))
        #expect(reply.status == 204)
        #expect(reply.body.isEmpty)
    }

    @Test func undecodableBodiesAre400AndNeverReachTheHandler() async throws {
        let recorder = Recorder()
        let (server, port) = try await startServer { event in
            await recorder.record(event)
            return .ack
        }
        defer { server.stop() }
        #expect(try await HTTPClient.post(port: port, event: "PreToolUse", body: Data("{not json".utf8)).status == 400)
        #expect(try await HTTPClient.post(port: port, event: "PreToolUse", body: Data("[1,2]".utf8)).status == 400)
        #expect(try await HTTPClient.post(port: port, event: "PreToolUse", body: Data(#"{"hook_event_name":"Stop"}"#.utf8)).status == 400)
        #expect(try await HTTPClient.post(port: port, event: "PreToolUse", body: Data()).status == 400)
        #expect(await recorder.events.isEmpty)
    }

    @Test func unknownRoutesAre404() async throws {
        let (server, port) = try await startServer { _ in .ack }
        defer { server.stop() }
        #expect(try await HTTPClient.send("GET", port: port, path: "/nope").status == 404)
        #expect(try await HTTPClient.send("GET", port: port, path: "/hook/PreToolUse").status == 404)
        #expect(try await HTTPClient.send("POST", port: port, path: "/other", body: Data("{}".utf8)).status == 404)
        #expect(try await HTTPClient.send("POST", port: port, path: "/health", body: Data("{}".utf8)).status == 404)
    }

    @Test func healthIgnoresAQueryString() async throws {
        let (server, port) = try await startServer { _ in .ack }
        defer { server.stop() }
        #expect(try await HTTPClient.send("GET", port: port, path: "/health?probe=1").status == 200)
    }

    @Test func aClientThatCancelsItsRequestCancelsTheHandlerTask() async throws {
        let recorder = Recorder()
        let (server, port) = try await startServer(sleepingHandler(recorder))
        defer { server.stop() }
        let body = try BridgeFixture.data("permission-request-bash-npm-test")
        let call = Task { try await HTTPClient.post(port: port, event: "PermissionRequest", body: body) }
        #expect(await eventually { await recorder.started == 1 })
        call.cancel()
        _ = try? await call.value
        #expect(await eventually { await recorder.cancelled == 1 })
        #expect(await recorder.finished == 0)
    }

    @Test func aRawClientClosingTheSocketCancelsTheHandlerTask() async throws {
        let recorder = Recorder()
        let (server, port) = try await startServer(sleepingHandler(recorder))
        defer { server.stop() }
        let body = try BridgeFixture.data("permission-request-bash-npm-test")
        let client = RawClient(port: port)
        try await client.connect()
        try await client.send(Data("POST /hook/PermissionRequest HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body)
        #expect(await eventually { await recorder.started == 1 })
        client.close()
        #expect(await eventually { await recorder.cancelled == 1 })
    }

    @Test func twoConcurrentHeldRequestsAreAnsweredIndependently() async throws {
        let gate = Gate()
        let (server, port) = try await startServer { event in await gate.hold(event.sessionID) }
        defer { server.stop() }
        let bodyA = try fixture("permission-request-bash-npm-test", sessionID: "session-A")
        let bodyB = try fixture("permission-request-edit", sessionID: "session-B")
        let callA = Task { try await HTTPClient.post(port: port, event: "PermissionRequest", body: bodyA) }
        let callB = Task { try await HTTPClient.post(port: port, event: "PermissionRequest", body: bodyB) }
        #expect(await eventually { await gate.holdingCount == 2 })

        await gate.release("session-B", with: .decision(.deny(message: "B denied")))
        let replyB = try await callB.value
        #expect(replyB.status == 200)
        #expect(replyB.body == HookOutput.permissionRequest(.deny(message: "B denied")))
        #expect(await gate.isHolding("session-A"))

        await gate.release("session-A", with: .decision(.allow))
        let replyA = try await callA.value
        #expect(replyA.status == 200)
        #expect(replyA.body == HookOutput.permissionRequest(.allow))
    }

    @Test func startingOnAPortInUseThrowsPortInUse() async throws {
        let (first, port) = try await startServer { _ in .ack }
        defer { first.stop() }
        let second = HookServer(port: port) { _ in .ack }
        await #expect(throws: HookServerError.portInUse(port)) { try await second.start() }
        #expect(second.port == nil)
        // The first server is unaffected.
        #expect(try await HTTPClient.send("GET", port: port, path: "/health").status == 200)
    }

    @Test func stopThenStartAgainWorks() async throws {
        let server = HookServer(port: 0) { _ in .ack }
        let first = try await server.start()
        #expect(try await server.start() == first, "start() while running returns the bound port")
        server.stop()
        server.stop()  // idempotent
        #expect(server.port == nil)
        let second = try await server.start()
        #expect(server.port == second)
        #expect(try await HTTPClient.send("GET", port: second, path: "/health").status == 200)
        server.stop()

        // The exact same port can be bound again right after stop().
        let again = HookServer(port: second) { _ in .ack }
        #expect(try await again.start() == second)
        #expect(try await HTTPClient.send("GET", port: second, path: "/health").status == 200)
        again.stop()
    }

    @Test func stopEndsHeldRequestsAndCancelsTheirHandlers() async throws {
        let recorder = Recorder()
        let (server, port) = try await startServer(sleepingHandler(recorder))
        let body = try BridgeFixture.data("permission-request-bash-npm-test")
        let call = Task { try await HTTPClient.post(port: port, event: "PermissionRequest", body: body) }
        #expect(await eventually { await recorder.started == 1 })
        server.stop()
        #expect(await eventually { await recorder.cancelled == 1 })
        let result = await call.result
        if case .success(let reply) = result { Issue.record("expected a dropped connection, got \(reply.status)") }
    }

    @Test func aBodySplitAcrossTCPSegmentsIsParsed() async throws {
        let recorder = Recorder()
        let (server, port) = try await startServer { event in
            await recorder.record(event)
            return .ack
        }
        defer { server.stop() }
        let body = try BridgeFixture.data("post-tool-use-bash")
        let head = "POST /hook/PostToolUse HTTP/1.1\r\nHost: 127.0.0.1\r\ncontent-type: application/json\r\ncontent-length: \(body.count)\r\n\r\n"
        let mid = body.count / 2
        let client = RawClient(port: port)
        try await client.connect()
        // Head split mid-line, then the body in two writes with pauses in between.
        let headData = Data(head.utf8)
        try await client.send(headData.prefix(20))
        try await Task.sleep(for: .milliseconds(40))
        try await client.send(headData.dropFirst(20) + body.prefix(mid))
        try await Task.sleep(for: .milliseconds(80))
        try await client.send(body.dropFirst(mid))
        let raw = try await client.receiveAll()
        client.close()
        let reply = try #require(RawClient.parse(raw))
        #expect(reply.status == 200)
        #expect(reply.bodyString == #"{"ok":true}"#)
        #expect(reply.headers["content-length"] == "11")
        let events = await recorder.events
        #expect(events.count == 1)
        #expect(events.first?.eventName == .postToolUse)
        #expect(events.first?.durationMs == 4187)
    }

    @Test func expect100ContinueIsHonored() async throws {
        let (server, port) = try await startServer { _ in .ack }
        defer { server.stop() }
        let body = try BridgeFixture.data("session-start")
        let client = RawClient(port: port)
        try await client.connect()
        try await client.send(Data("POST /hook/SessionStart HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nExpect: 100-continue\r\nContent-Length: \(body.count)\r\n\r\n".utf8))
        try await Task.sleep(for: .milliseconds(50))
        try await client.send(body)
        let raw = String(decoding: try await client.receiveAll(), as: UTF8.self)
        client.close()
        #expect(raw.hasPrefix("HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 200 OK\r\n"))
        #expect(raw.hasSuffix(#"{"ok":true}"#))
    }

    @Test func anOversizedBodyIsRejectedWith413() async throws {
        let recorder = Recorder()
        let (server, port) = try await startServer { event in
            await recorder.record(event)
            return .ack
        }
        defer { server.stop() }
        let client = RawClient(port: port)
        try await client.connect()
        try await client.send(Data("POST /hook/PostToolUse HTTP/1.1\r\nHost: x\r\nContent-Length: \(2 * 1024 * 1024)\r\n\r\n{".utf8))
        let reply = try #require(RawClient.parse(try await client.receiveAll()))
        client.close()
        #expect(reply.status == 413)
        #expect(await recorder.events.isEmpty)
    }

    @Test func aBigButAllowedBodyIsAccepted() async throws {
        let recorder = Recorder()
        let (server, port) = try await startServer { event in
            await recorder.record(event)
            return .ack
        }
        defer { server.stop() }
        var obj = try JSONSerialization.jsonObject(with: try BridgeFixture.data("post-tool-use-read")) as! [String: Any]
        obj["tool_response"] = ["content": String(repeating: "x", count: 600_000)]
        let body = try JSONSerialization.data(withJSONObject: obj)
        let reply = try await HTTPClient.post(port: port, event: "PostToolUse", body: body)
        #expect(reply.status == 200)
        #expect(await recorder.events.count == 1)
    }

    @Test func manySequentialRequestsAllSucceed() async throws {
        let recorder = Recorder()
        let (server, port) = try await startServer { event in
            await recorder.record(event)
            return .ack
        }
        defer { server.stop() }
        let body = try BridgeFixture.data("pre-tool-use-read")
        for _ in 0..<25 {
            #expect(try await HTTPClient.post(port: port, event: "PreToolUse", body: body).status == 200)
        }
        #expect(await recorder.events.count == 25)
    }
}

// MARK: - Pure parsing and routing (no sockets)

@Suite struct HTTPParsingTests {
    @Test func parsesACompleteRequest() throws {
        let raw = Data("POST /hook/Stop?x=1 HTTP/1.1\r\nHost: a\r\nCONTENT-LENGTH: 2\r\nX-Thing:  spaced  \r\n\r\n{}".utf8)
        guard case .complete(let req) = HTTPRequestParser.parse(raw) else {
            Issue.record("expected a complete request"); return
        }
        #expect(req.method == "POST")
        #expect(req.path == "/hook/Stop")
        #expect(req.header("content-length") == "2")
        #expect(req.header("X-THING") == "spaced")
        #expect(req.body == Data("{}".utf8))
    }

    @Test func waitsForTheRestOfTheHeadAndBody() {
        #expect(HTTPRequestParser.parse(Data("POST /hook/Stop HTTP/1.1\r\nContent-Le".utf8))
            == .incomplete(headComplete: false, expectsContinue: false))
        #expect(HTTPRequestParser.parse(Data("POST /hook/Stop HTTP/1.1\r\nContent-Length: 5\r\n\r\n{}".utf8))
            == .incomplete(headComplete: true, expectsContinue: false))
        #expect(HTTPRequestParser.parse(Data("POST /x HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n".utf8))
            == .incomplete(headComplete: true, expectsContinue: true))
    }

    @Test func rejectsMalformedRequests() {
        #expect(HTTPRequestParser.parse(Data("garbage\r\n\r\n".utf8)) == .invalid(status: 400))
        #expect(HTTPRequestParser.parse(Data("POST /x HTTP/1.1\r\nContent-Length: abc\r\n\r\n".utf8)) == .invalid(status: 400))
        #expect(HTTPRequestParser.parse(Data("POST /x HTTP/1.1\r\nno-colon-here\r\n\r\n".utf8)) == .invalid(status: 400))
        #expect(HTTPRequestParser.parse(Data("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) == .invalid(status: 411))
        #expect(HTTPRequestParser.parse(Data("POST /x HTTP/1.1\r\nContent-Length: 11\r\n\r\n".utf8), maxBodyBytes: 10) == .invalid(status: 413))
        #expect(HTTPRequestParser.parse(Data(repeating: 65, count: HTTPRequestParser.maxHeadBytes + 1)) == .invalid(status: 431))
    }

    @Test func aGetWithoutBodyIsComplete() {
        guard case .complete(let req) = HTTPRequestParser.parse(Data("GET /health HTTP/1.1\r\nHost: a\r\n\r\n".utf8)) else {
            Issue.record("expected a complete request"); return
        }
        #expect(req.method == "GET")
        #expect(req.body.isEmpty)
    }

    @Test func serializesResponses() {
        let ok = String(decoding: HTTPResponse(status: 200, body: Data("{}".utf8), contentType: "application/json").serialized(), as: UTF8.self)
        #expect(ok == "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
        let none = String(decoding: HTTPResponse(status: 204).serialized(), as: UTF8.self)
        #expect(none == "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
    }

    @Test func mapsHookResponses() {
        #expect(HookServer.httpResponse(for: .ack).status == 200)
        #expect(HookServer.httpResponse(for: .ack).body == Data(#"{"ok":true}"#.utf8))
        #expect(HookServer.httpResponse(for: .decision(.allow)).body == HookOutput.permissionRequest(.allow))
        #expect(HookServer.httpResponse(for: .decision(.allow)).contentType == "application/json")
        #expect(HookServer.httpResponse(for: .noDecision).status == 204)
        #expect(HookServer.httpResponse(for: .noDecision).body.isEmpty)
    }
}

// MARK: - Review finding: web pages must not reach the hook server

@Suite("Hook server refuses requests from web pages")
struct HookServerOriginTests {
    private func request(_ method: String = "POST", path: String = "/hook/PermissionRequest",
                         headers: [String: String]) -> HTTPRequest {
        HTTPRequest(method: method, path: path, headers: headers, body: Data("{}".utf8))
    }

    @Test func localToolsPass() {
        let json = ["host": "127.0.0.1:47474", "content-type": "application/json"]
        #expect(HookServer.rejection(for: request(headers: json), port: 47474) == nil)
        #expect(HookServer.rejection(for: request(headers: ["host": "localhost:47474", "content-type": "application/json; charset=utf-8"]), port: 47474) == nil)
        #expect(HookServer.rejection(for: request(headers: ["host": "LOCALHOST:47474", "content-type": "Application/JSON"]), port: 47474) == nil)
        #expect(HookServer.rejection(for: request("GET", path: "/health", headers: ["host": "127.0.0.1:47474"]), port: 47474) == nil)
        #expect(HookServer.rejection(for: request("GET", path: "/health", headers: ["host": "127.0.0.1"]), port: 47474) == nil)
    }

    @Test func anOriginHeaderIsRefused() {
        for origin in ["https://evil.example", "http://127.0.0.1:47474", "null"] {
            let r = request(headers: ["host": "127.0.0.1:47474", "content-type": "application/json", "origin": origin])
            #expect(HookServer.rejection(for: r, port: 47474)?.status == 403, "\(origin)")
        }
        let fetch = request(headers: ["host": "127.0.0.1:47474", "content-type": "application/json", "sec-fetch-site": "cross-site"])
        #expect(HookServer.rejection(for: fetch, port: 47474)?.status == 403)
    }

    @Test func aForeignHostIsRefused() {
        for host in ["evil.example:47474", "evil.example", "127.0.0.1:1", "127.0.0.1.evil.example:47474", "localhost.evil.example", "127.0.0.1:abc"] {
            let r = request("GET", path: "/health", headers: ["host": host])
            #expect(HookServer.rejection(for: r, port: 47474)?.status == 403, "\(host)")
        }
        #expect(HookServer.rejection(for: request("GET", path: "/health", headers: [:]), port: 47474)?.status == 403)
    }

    @Test func aSimpleCORSPostIsRefused() {
        for type in ["text/plain", "application/x-www-form-urlencoded", "multipart/form-data; boundary=x", ""] {
            var headers = ["host": "127.0.0.1:47474"]
            if !type.isEmpty { headers["content-type"] = type }
            #expect(HookServer.rejection(for: request(headers: headers), port: 47474)?.status == 415, "\(type)")
        }
    }

    /// The reported attack, end to end: a text/plain POST with an Origin never reaches the handler.
    @Test func aWebPagePostNeverReachesTheHandler() async throws {
        let recorder = Recorder()
        let (server, port) = try await startServer { event in
            await recorder.record(event)
            return .decision(.allow)
        }
        defer { server.stop() }
        let body = try fixture("permission-request-bash-npm-test")
        let attempts = [
            "Host: 127.0.0.1:\(port)\r\nOrigin: https://evil.example\r\nContent-Type: text/plain",
            "Host: 127.0.0.1:\(port)\r\nOrigin: https://evil.example\r\nContent-Type: application/json",
            "Host: 127.0.0.1:\(port)\r\nContent-Type: text/plain",
            "Host: evil.example:\(port)\r\nContent-Type: application/json",
        ]
        for head in attempts {
            let client = RawClient(port: port)
            try await client.connect()
            try await client.send(Data("POST /hook/PermissionRequest HTTP/1.1\r\n\(head)\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body)
            let reply = try #require(RawClient.parse(try await client.receiveAll()))
            client.close()
            #expect(reply.status == 403 || reply.status == 415, "\(head)")
            #expect(!reply.bodyString.contains("allow"), "\(head)")
        }
        let health = RawClient(port: port)
        try await health.connect()
        try await health.send(Data("GET /health HTTP/1.1\r\nHost: evil.example:\(port)\r\n\r\n".utf8))
        #expect(try #require(RawClient.parse(try await health.receiveAll())).status == 403)
        health.close()
        #expect(await recorder.events.isEmpty)
        // The real hook still gets through.
        #expect(try await HTTPClient.post(port: port, event: "PermissionRequest", body: body).status == 200)
    }
}
