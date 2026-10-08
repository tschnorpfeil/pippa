import Foundation
import Network

// Pippa itself serves MCP over "Streamable HTTP" on
// 127.0.0.1, not a helper that Pi starts. So the Pippa process always does the reading (EventKit, Apple Events), TCC asks
// for and remembers "Pippa", and the same permissions and the same code apply as in the native flow.
//
// Protection:
// - loopback only: bound to 127.0.0.1 (`requiredLocalEndpoint`) and `acceptLocalOnly`;
// - key per app launch (32 random bytes), only in the environment of Pippa's own Pi; without it 401;
// - no browser: requests with `Origin` -> 403, `Host` must be 127.0.0.1/localhost with our port (DNS rebinding);
// - requests at most 1 MB, one request per connection (`Connection: close`), connection closes after 330 s.
// Answers are plain `application/json` answers (the specification allows that); GET (server stream) -> 405.

/// An HTTP/1.1 request, as far as the server needs it.
public struct PippaHTTPRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    /// Header lines with lowercase names.
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method; self.path = path; self.headers = headers; self.body = body
    }

    public enum Parse: Sendable, Equatable {
        case incomplete
        case invalid(Int)
        case complete(PippaHTTPRequest)
    }

    public static let maxBytes = 1_000_000

    /// Reads a complete request from `buffer`. Only `Content-Length`; `chunked` -> 411.
    public static func parse(_ buffer: Data) -> Parse {
        if buffer.count > maxBytes { return .invalid(413) }
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > 16_384 ? .invalid(431) : .incomplete
        }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid(400) }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count == 3, start[2].hasPrefix("HTTP/1.") else { return .invalid(400) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid(400) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if headers[name] != nil, name == "content-length" || name == "authorization" || name == "host" { return .invalid(400) }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil { return .invalid(411) }
        let length: Int
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0 else { return .invalid(400) }
            length = n
        } else {
            length = 0
        }
        if length > maxBytes { return .invalid(413) }
        let bodyStart = end.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return .incomplete }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        return .complete(PippaHTTPRequest(method: String(start[0]), path: String(start[1]), headers: headers, body: body))
    }
}

public struct PippaHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var contentType: String?
    public var body: Data
    public var extraHeaders: [(String, String)] = []

    public static func == (a: Self, b: Self) -> Bool { a.status == b.status && a.contentType == b.contentType && a.body == b.body }

    static func plain(_ status: Int, _ text: String) -> PippaHTTPResponse {
        PippaHTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    var bytes: Data {
        let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                       405: "Method Not Allowed", 411: "Length Required", 413: "Content Too Large", 415: "Unsupported Media Type",
                       431: "Request Header Fields Too Large"]
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        for (name, value) in extraHeaders { head += "\(name): \(value)\r\n" }
        head += "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// The server. One instance per app run; `stop()` on quit.
public final class PippaMCPServer: @unchecked Sendable {
    public let token: String
    private let tools: PippaMCPTools
    private let listener: NWListener
    private let queue = DispatchQueue(label: "io.github.tschnorpfeil.pippa.mcp")
    private let lock = NSLock()
    private var boundPort: UInt16 = 0

    public init(host: PippaMCPHost, token: String = PippaMCPServer.newToken()) throws {
        self.token = token
        tools = PippaMCPTools(host: host)
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    /// 32 random bytes as hex (SystemRandomNumberGenerator: arc4random, cryptographically secure).
    public static func newToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    public var port: UInt16 { lock.withLock { boundPort } }
    public var url: URL { URL(string: "http://127.0.0.1:\(port)/mcp")! }

    /// Starts and waits until the port is known.
    public func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let self, let port = self.listener.port?.rawValue { self.lock.withLock { self.boundPort = port } }
                    if once.take() { done.resume() }
                case .failed(let error):
                    if once.take() { done.resume(throwing: error) }
                case .cancelled:
                    if once.take() { done.resume(throwing: CancellationError()) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        DiagnosticsLog.shared.event("mcp-server", ["port": String(port)])
    }

    public func stop() { listener.cancel() }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        // "Look online" waits for the person's click; Pi's limit is 300 s (pippa-mcp.ts), a bit more here.
        queue.asyncAfter(deadline: .now() + 330) { connection.cancel() }
        receive(connection, Data())
    }

    private func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch PippaHTTPRequest.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil { connection.cancel() } else { self.receive(connection, buffer) }
            case .invalid(let status):
                self.send(.plain(status, "Bad request"), on: connection)
            case .complete(let request):
                Task { [self] in
                    let response = await self.respond(to: request)
                    self.send(response, on: connection)
                }
            }
        }
    }

    private func send(_ response: PippaHTTPResponse, on connection: NWConnection) {
        connection.send(content: response.bytes, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Requests (checkable without network)

    /// Checks origin and key, then JSON-RPC. `port`: only for checks without a running server.
    public func respond(to request: PippaHTTPRequest, port expected: UInt16? = nil) async -> PippaHTTPResponse {
        let port = expected ?? self.port
        // Browsers always send Origin; Pippa's Pi never does.
        if request.headers["origin"] != nil { return .plain(403, "Forbidden") }
        guard let host = request.headers["host"], ["127.0.0.1:\(port)", "localhost:\(port)"].contains(host.lowercased()) else {
            return .plain(403, "Forbidden")
        }
        guard Self.authorized(request.headers["authorization"], token: token) else {
            var response = PippaHTTPResponse.plain(401, "Unauthorized")
            response.extraHeaders = [("WWW-Authenticate", "Bearer")]
            return response
        }
        guard request.path == "/mcp" || request.path.hasPrefix("/mcp?") else { return .plain(404, "Not found") }
        switch request.method {
        case "POST":
            guard (request.headers["content-type"] ?? "").lowercased().hasPrefix("application/json") else { return .plain(415, "Use application/json") }
            guard let reply = await tools.handle(request.body) else { return PippaHTTPResponse(status: 202, contentType: nil, body: Data()) }
            return PippaHTTPResponse(status: 200, contentType: "application/json", body: reply)
        default:
            // GET: no server stream (Pippa sends nothing on its own). DELETE: there is no session to end.
            var response = PippaHTTPResponse.plain(405, "Method not allowed")
            response.extraHeaders = [("Allow", "POST")]
            return response
        }
    }

    /// `Bearer <token>`, comparison in constant time.
    static func authorized(_ header: String?, token: String) -> Bool {
        guard let header, header.hasPrefix("Bearer ") else { return false }
        let given = Array(header.dropFirst(7).utf8), expected = Array(token.utf8)
        guard given.count == expected.count, !expected.isEmpty else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(given, expected) { difference |= a ^ b }
        return difference == 0
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
