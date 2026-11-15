// OWNER: workstream B (bridge). One accepted TCP connection of HookServer: read one request, answer once, close.
import Foundation
import Network

/// Serves exactly one HTTP request on an accepted connection.
///
/// All mutable state is confined to the server's serial `queue`. The handler runs in its own `Task`;
/// while it is suspended (a held `PermissionRequest`), a receive stays pending so the peer closing
/// (Claude Code killed the hook, the user answered in the terminal) is noticed and the task cancelled.
final class HookConnection: @unchecked Sendable {
    /// A client must finish sending its request within this many seconds (the handler itself may take minutes).
    static let readTimeout: TimeInterval = 15

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: HookServer.Handler
    private let maxBodyBytes: Int
    /// The server's bound port, for the Host check.
    private let port: @Sendable () -> UInt16?
    private let onClose: (HookConnection) -> Void

    private var buffer = Data()
    private var sentContinue = false
    private var dispatched = false
    private var responded = false
    private var closed = false
    private var task: Task<Void, Never>?
    private var readDeadline: DispatchWorkItem?

    init(connection: NWConnection, queue: DispatchQueue, handler: @escaping HookServer.Handler,
         maxBodyBytes: Int, port: @escaping @Sendable () -> UInt16? = { nil },
         onClose: @escaping (HookConnection) -> Void) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
        self.maxBodyBytes = maxBodyBytes
        self.port = port
        self.onClose = onClose
    }

    /// Call on `queue`.
    func start() {
        connection.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
        connection.start(queue: queue)
        let deadline = DispatchWorkItem { [weak self] in self?.readTimedOut() }
        readDeadline = deadline
        queue.asyncAfter(deadline: .now() + Self.readTimeout, execute: deadline)
        receive()
    }

    /// Closes the connection. A handler still running is cancelled. Idempotent. Call on `queue`.
    func close() {
        guard !closed else { return }
        closed = true
        readDeadline?.cancel()
        if !responded { task?.cancel() }
        connection.cancel()
        onClose(self)
    }

    // MARK: Reading

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.didReceive(data) }
            if isComplete || error != nil {
                self.peerClosed()
            } else if !self.closed {
                self.receive()  // keep one receive pending, also while the handler runs
            }
        }
    }

    private func didReceive(_ data: Data) {
        guard !dispatched, !closed else { return }  // one request per connection; ignore anything after it
        buffer.append(data)
        switch HTTPRequestParser.parse(buffer, maxBodyBytes: maxBodyBytes) {
        case .incomplete(let headComplete, let expectsContinue):
            if headComplete, expectsContinue, !sentContinue {
                sentContinue = true
                connection.send(content: HTTPResponse.interimContinue, completion: .idempotent)
            }
        case .invalid(let status):
            dispatched = true
            respond(HTTPResponse(status: status))
        case .complete(let request):
            dispatched = true
            buffer = Data()
            readDeadline?.cancel()
            handle(request)
        }
    }

    private func handle(_ request: HTTPRequest) {
        // Web pages (Origin, foreign Host, non-JSON POST) never reach the router or the handler.
        if let refusal = HookServer.rejection(for: request, port: port()) {
            respond(refusal)
            return
        }
        switch HookServer.route(request) {
        case .respond(let response):
            respond(response)
        case .hook(let event):
            let handler = self.handler
            let queue = self.queue
            task = Task { [weak self] in
                let result = await handler(event)
                queue.async { self?.respond(HookServer.httpResponse(for: result)) }
            }
        }
    }

    // MARK: Writing and closing

    private func respond(_ response: HTTPResponse) {
        guard !responded, !closed else { return }
        responded = true
        readDeadline?.cancel()
        connection.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    private func readTimedOut() {
        guard !dispatched, !closed else { return }
        dispatched = true
        respond(HTTPResponse(status: 408))
    }

    /// The client closed its side or the connection broke.
    private func peerClosed() {
        // After a response the send completion closes the connection; before one, the client is gone.
        if responded { return }
        close()
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .failed, .waiting:
            close()
        case .cancelled:
            if !closed { close() }
        default:
            break
        }
    }
}
