// OWNER: workstream B (bridge). Minimal HTTP/1.1 request parsing and response serialization for HookServer.
import Foundation

/// One parsed HTTP request. Header names are stored lowercased.
struct HTTPRequest: Equatable, Sendable {
    var method: String
    /// The request target without the query string ("/hook/PreToolUse").
    var path: String
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// Incremental request parser: call `parse` with everything received so far.
enum HTTPRequestParser {
    /// Request line plus headers.
    static let maxHeadBytes = 64 * 1024
    /// Hook payloads (PostToolUse carries `tool_response`) stay far below this.
    static let defaultMaxBodyBytes = 1024 * 1024

    enum Result: Equatable {
        /// More bytes needed. `headComplete` tells whether the blank line after the headers arrived;
        /// `expectsContinue` whether the client sent `Expect: 100-continue` and waits for an interim 100.
        case incomplete(headComplete: Bool, expectsContinue: Bool)
        case complete(HTTPRequest)
        /// Answer with this status and close.
        case invalid(status: Int)
    }

    private static let headTerminator = Data([13, 10, 13, 10])  // \r\n\r\n

    static func parse(_ buffer: Data, maxBodyBytes: Int = defaultMaxBodyBytes) -> Result {
        guard let end = buffer.range(of: headTerminator) else {
            return buffer.count > maxHeadBytes ? .invalid(status: 431) : .incomplete(headComplete: false, expectsContinue: false)
        }
        let headLength = end.lowerBound - buffer.startIndex
        guard headLength <= maxHeadBytes else { return .invalid(status: 431) }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8)
                ?? String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .isoLatin1)
        else { return .invalid(status: 400) }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid(status: 400) }
        let method = String(requestLine[0])
        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(status: 400) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return .invalid(status: 400) }
            headers[name] = value
        }

        if let te = headers["transfer-encoding"], te.lowercased() != "identity" { return .invalid(status: 411) }
        var contentLength = 0
        if let cl = headers["content-length"] {
            guard let n = Int(cl), n >= 0 else { return .invalid(status: 400) }
            contentLength = n
        }
        guard contentLength <= maxBodyBytes else { return .invalid(status: 413) }

        let bodyStart = end.upperBound
        let available = buffer.endIndex - bodyStart
        guard available >= contentLength else {
            let expects = headers["expect"]?.lowercased() == "100-continue"
            return .incomplete(headComplete: true, expectsContinue: expects)
        }
        let body = Data(buffer[bodyStart..<(bodyStart + contentLength)])
        return .complete(HTTPRequest(method: method, path: path, headers: headers, body: body))
    }
}

/// One HTTP/1.1 response. Always `Connection: close`.
struct HTTPResponse: Equatable, Sendable {
    var status: Int
    var body: Data = Data()
    var contentType: String?

    static let interimContinue = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)

    static func json(_ status: Int, _ body: Data) -> HTTPResponse {
        HTTPResponse(status: status, body: body, contentType: "application/json")
    }

    static func json(_ status: Int, _ text: String) -> HTTPResponse { json(status, Data(text.utf8)) }

    static func reason(_ status: Int) -> String {
        switch status {
        case 100: return "Continue"
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 415: return "Unsupported Media Type"
        case 408: return "Request Timeout"
        case 411: return "Length Required"
        case 413: return "Content Too Large"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }

    func serialized() -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        if status != 204 {  // RFC 9110: no Content-Length (and no body) on 204.
            if let contentType { head += "Content-Type: \(contentType)\r\n" }
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        if status != 204 { out.append(body) }
        return out
    }
}
