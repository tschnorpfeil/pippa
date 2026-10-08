import Foundation
import Network

// Pippa's intermediary between her Pi and the person's own online service.
// Website and privacy page promise "Pippa fragt dich, bevor etwas deinen Mac verlässt"; that applies to the online
// service too. Pi only knows this intermediary (`pippa-online` in models.json, `PiOnlineProvider`), never the service.
//
// Per request from Pi:
// 1. Check origin: only 127.0.0.1 (bound to loopback, `acceptLocalOnly`), no `Origin` (browser), `Host` with
//    our port (DNS rebinding), this app run's access token as `Authorization: Bearer` or `x-api-key`.
// 2. `POST` only, on the service's single path (`/chat/completions` or `/v1/messages`); everything else 404.
// 3. `decide` asks (card in the conversation) with exactly what would go out. No → 403 with a sentence that Pi shows as
//    an error message and the model understands; nothing goes out.
// 4. Yes → forward to the service, key fresh from the keychain (`credential`), never in file, log or environment.
//    The response flows back piece by piece (chunked) so Pi's streaming is preserved.
//
// The intermediary logs neither content nor key; DiagnosticsLog only gets event, result and size.

/// What Pi wants to send, raw. `PippaOnlineAsk.make` turns it into the card.
public struct PippaOnlineOutgoing: Sendable {
    public var connection: ModelConnection
    public var body: Data
    public init(connection: ModelConnection, body: Data) { self.connection = connection; self.body = body }
}

/// What the person sees on the card: who gets what, how much, which shown items are included.
public struct PippaOnlineAsk: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// "OpenAI", "Anthropic" or the host of a compatible service.
    public var service: String
    public var host: String
    public var model: String
    public var bytes: Int
    /// Messages in the history that goes along (without the system prompt).
    public var messages: Int
    /// Tool results in it (e.g. files read, web pages).
    public var toolResults: Int
    public var images: Int
    /// Names of shown items that occur in the request (name, path or content via a tool).
    public var shownIncluded: [String]
    public init(id: UUID = UUID(), service: String, host: String, model: String, bytes: Int, messages: Int, toolResults: Int,
                images: Int, shownIncluded: [String]) {
        self.id = id; self.service = service; self.host = host; self.model = model; self.bytes = bytes
        self.messages = messages; self.toolResults = toolResults; self.images = images; self.shownIncluded = shownIncluded
    }

    /// Reads the request (OpenAI or Anthropic form) without storing any of it. `shown`: what the person has shown in this
    /// conversation; named is what occurs in the request text (path or file name).
    public static func make(_ outgoing: PippaOnlineOutgoing, shown: [URL]) -> PippaOnlineAsk {
        let connection = outgoing.connection
        let object = (try? JSONSerialization.jsonObject(with: outgoing.body)) as? [String: Any] ?? [:]
        let messages = object["messages"] as? [[String: Any]] ?? []
        var toolResults = 0, images = 0, counted = 0
        for message in messages {
            let role = message["role"] as? String ?? ""
            if role == "system" || role == "developer" { continue }
            counted += 1
            if role == "tool" { toolResults += 1 }
            for part in message["content"] as? [[String: Any]] ?? [] {
                switch part["type"] as? String {
                case "tool_result": toolResults += 1
                    for inner in part["content"] as? [[String: Any]] ?? [] where inner["type"] as? String == "image" { images += 1 }
                case "image", "image_url", "input_image": images += 1
                default: break
                }
            }
        }
        let text = String(decoding: outgoing.body, as: UTF8.self)
        var included: [String] = []
        for url in shown {
            let name = url.lastPathComponent
            guard !name.isEmpty, !included.contains(name) else { continue }
            if text.contains(url.path) || text.contains(jsonEscaped(url.path)) || text.contains(name) || text.contains(jsonEscaped(name)) {
                included.append(name)
            }
        }
        let service = connection.provider == .compatible ? connection.destination : connection.provider.displayName
        return PippaOnlineAsk(service: service, host: connection.destination,
                              model: object["model"] as? String ?? connection.modelID, bytes: outgoing.body.count,
                              messages: counted, toolResults: toolResults, images: images, shownIncluded: included)
    }

    static func jsonEscaped(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes]),
              let array = String(data: data, encoding: .utf8) else { return text }
        return String(array.dropFirst(2).dropLast(2))
    }
}

/// Approvals. "Für dieses Gespräch": applies only to this conversation, this connection (service, address, model) and exactly what was
/// shown. Newly shown items or a changed connection need a new approval; "Nur diesmal" remembers nothing.
public struct PippaOnlineGrants: Sendable, Equatable {
    private var keys: Set<String> = []
    public init() {}

    public static func key(conversation: String, connection: ModelConnection, shown: [URL]) -> String {
        ([conversation, connection.id.uuidString, connection.provider.rawValue, connection.endpoint.absoluteString, connection.modelID]
         + shown.map(\.standardizedFileURL.path).sorted()).joined(separator: "\u{1F}")
    }
    public func allows(conversation: String, connection: ModelConnection, shown: [URL]) -> Bool {
        keys.contains(Self.key(conversation: conversation, connection: connection, shown: shown))
    }
    public mutating func grant(conversation: String, connection: ModelConnection, shown: [URL]) {
        keys.insert(Self.key(conversation: conversation, connection: connection, shown: shown))
    }
    public mutating func removeAll() { keys.removeAll(); turns.removeAll() }

    /// "Nur diesmal" covers the whole message (all model rounds of one answer) with exactly the shown items that
    /// were on the card. If something shown is added in the same answer, a new card is needed.
    private var turns: [String: Set<String>] = [:]
    public mutating func approveTurn(_ turn: String, shown: [String]) { turns[turn, default: []].formUnion(shown) }
    public func turnAllows(_ turn: String, shown: [String]) -> Bool { turns[turn].map { Set(shown).isSubset(of: $0) } ?? false }
    public mutating func endTurn(_ turn: String) { turns.removeValue(forKey: turn) }
}

/// The card's answer for a request: forward, decline, or answer on this Mac (Pippa has already switched Pi to
/// `pippa-local`; the intermediary reports an error on which Pi retries by itself, then with the local AI).
public enum PippaOnlineVerdict: Sendable, Equatable { case allow, deny, local }

/// A request to the online service and what became of it (receipt "Online gefragt: …", from code).
public struct PippaOnlineRecord: Sendable, Equatable {
    public enum Outcome: String, Sendable { case done, declined, local, failed }
    public var service: String
    public var outcome: Outcome
    public var bytes: Int
    public init(service: String, outcome: Outcome, bytes: Int) { self.service = service; self.outcome = outcome; self.bytes = bytes }

    /// Receipt lines for an answer: one per service and result (several requests → one "Online gefragt: …" line).
    public static func receiptItems(_ records: [PippaOnlineRecord]) -> [ActionReceipt.Item] {
        var items: [ActionReceipt.Item] = []
        for record in records {
            let item = ActionReceipt.Item(action: "online", outcome: record.outcome.rawValue, name: record.service)
            if !items.contains(item) { items.append(item) }
        }
        return items
    }
}

public final class PippaOnlineProxy: @unchecked Sendable {
    /// Largest request Pi may send (long histories with images); above it 413, nothing goes out.
    public static let maxRequestBytes = 32_000_000
    /// Sentence for Pi and the model on "No" (no digits, no "timeout": Pi would otherwise retry).
    public static let declinedMessage = "Pippa: The person did not allow this request to their online service. Nothing was sent. Do not try again on your own; tell the person in one sentence that you did not ask online."
    /// "On this Mac": deliberately a sentence Pi recognizes as transient ("service unavailable"). Pi drops the
    /// attempt from the history and asks again, meanwhile with `pippa-local`. Nothing went out.
    public static let localMessage = "Pippa: online service unavailable for this request, nothing was sent; continuing with the AI on this Mac."

    public let token: String
    public let connection: ModelConnection
    private let needsApproval: Bool
    private let decide: @Sendable (PippaOnlineOutgoing) async -> PippaOnlineVerdict
    private let credential: @Sendable () throws -> String?
    private let onRecord: @Sendable (PippaOnlineRecord) -> Void
    private let listener: NWListener
    private let queue = DispatchQueue(label: "io.github.tschnorpfeil.pippa.online")
    private let session: URLSession
    private let lock = NSLock()
    private var boundPort: UInt16 = 0

    /// `needsApproval`: `false` only if the service itself runs on this Mac (nothing leaves the Mac).
    /// `upstreamProtocols`: only for tests (stand-in service without network).
    public init(connection: ModelConnection, port: Int, needsApproval: Bool, token: String = PippaMCPServer.newToken(),
                credential: @escaping @Sendable () throws -> String?,
                decide: @escaping @Sendable (PippaOnlineOutgoing) async -> PippaOnlineVerdict,
                onRecord: @escaping @Sendable (PippaOnlineRecord) -> Void = { _ in },
                upstreamProtocols: [AnyClass]? = nil) throws {
        self.connection = try connection.validated()
        self.token = token
        self.needsApproval = needsApproval
        self.credential = credential
        self.decide = decide
        self.onRecord = onRecord
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0 else { throw PippaOnlineProxyError.badPort }
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 300
        if let upstreamProtocols { configuration.protocolClasses = upstreamProtocols }
        session = URLSession(configuration: configuration)
    }

    public var port: UInt16 { lock.withLock { boundPort } }

    /// Starts and waits until the port is bound (taken → error; Pippa then picks a new one).
    public func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let once = OnlineOnce()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let self, let port = self.listener.port?.rawValue { self.lock.withLock { self.boundPort = port } }
                    if once.take() { done.resume() }
                case .failed(let error), .waiting(let error):
                    self?.listener.cancel()
                    if once.take() { done.resume(throwing: error) }
                case .cancelled:
                    if once.take() { done.resume(throwing: CancellationError()) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        DiagnosticsLog.shared.event("online-vermittler", ["port": String(port), "fragt": needsApproval ? "ja" : "nein"])
    }

    public func stop() {
        listener.cancel()
        session.invalidateAndCancel()
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, Data())
    }

    private func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch Self.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil { connection.cancel() } else { self.receive(connection, buffer) }
            case .invalid(let status):
                self.sendWhole(.plain(status, "Bad request"), on: connection)
            case .complete(let request):
                let task = Task { [self] in await self.serve(request, on: connection) }
                // Pi aborts (stop, or Pi's time limit while the card is open): the connection closes, the
                // fetch at the service too, and a later approval sends nothing out for this request.
                connection.stateUpdateHandler = { state in
                    switch state { case .failed, .cancelled: task.cancel(); default: break }
                }
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
                    if isComplete || error != nil { task.cancel() }
                }
            }
        }
    }

    // MARK: Requests (testable without network)

    /// Checks origin, access token, method and path. `nil` = fine; otherwise the rejection. `port`: for tests.
    public func admission(_ request: PippaHTTPRequest, port expected: UInt16? = nil) -> PippaHTTPResponse? {
        let port = expected ?? self.port
        if request.headers["origin"] != nil { return .plain(403, "Forbidden") }
        guard let host = request.headers["host"], ["127.0.0.1:\(port)", "localhost:\(port)"].contains(host.lowercased()) else {
            return .plain(403, "Forbidden")
        }
        let bearer = request.headers["authorization"]
        let apiKey = request.headers["x-api-key"].map { "Bearer " + $0 }
        guard PippaMCPServer.authorized(bearer, token: token) || PippaMCPServer.authorized(apiKey, token: token) else {
            var response = PippaHTTPResponse.plain(401, "Unauthorized")
            response.extraHeaders = [("WWW-Authenticate", "Bearer")]
            return response
        }
        guard request.method == "POST" else {
            var response = PippaHTTPResponse.plain(405, "Method not allowed")
            response.extraHeaders = [("Allow", "POST")]
            return response
        }
        guard upstreamURL(for: request.path) != nil else { return .plain(404, "Not found") }
        guard (request.headers["content-type"] ?? "").lowercased().hasPrefix("application/json") else { return .plain(415, "Use application/json") }
        return nil
    }

    /// Address at the service for Pi's path, or `nil` if the path is not forwarded.
    public func upstreamURL(for path: String) -> URL? {
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let base = PiOnlineProvider.basePath(connection.provider)
        guard let full = parts.first.map(String.init), full.hasPrefix(base) else { return nil }
        let rest = String(full.dropFirst(base.count))
        guard PiOnlineProvider.allowedPaths(connection.provider).contains(rest) else { return nil }
        // Anthropic SDK: `client.beta.messages` appends `?beta=true`. No other query parts.
        var query = ""
        if parts.count == 2 {
            guard connection.provider == .anthropic, parts[1] == "beta=true" else { return nil }
            query = "?beta=true"
        }
        var endpoint = connection.endpoint.absoluteString
        while endpoint.hasSuffix("/") { endpoint.removeLast() }
        return URL(string: endpoint + rest + query)
    }

    /// Error response in the service's form, so Pi shows the sentence as an error message.
    public func errorResponse(_ status: Int, _ message: String) -> PippaHTTPResponse {
        let object: [String: Any] = connection.provider == .anthropic
            ? ["type": "error", "error": ["type": "permission_error", "message": message]]
            : ["error": ["message": message, "type": "permission_denied", "code": "pippa_declined"]]
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return PippaHTTPResponse(status: status, contentType: "application/json", body: body)
    }

    private func serve(_ request: PippaHTTPRequest, on connection: NWConnection) async {
        if let refusal = admission(request) { return sendWhole(refusal, on: connection) }
        guard let url = upstreamURL(for: request.path) else { return sendWhole(.plain(404, "Not found"), on: connection) }
        let service = self.connection.provider == .compatible ? self.connection.destination : self.connection.provider.displayName
        let bytes = request.body.count
        if needsApproval {
            let verdict = await decide(PippaOnlineOutgoing(connection: self.connection, body: request.body))
            // Pi gave up (the approval then applies to Pi's new attempt at the same request, not to this one).
            guard !Task.isCancelled else { connection.cancel(); return }
            switch verdict {
            case .allow: break
            case .deny:
                record(service, .declined, bytes)
                return sendWhole(errorResponse(403, Self.declinedMessage), on: connection)
            case .local:
                record(service, .local, bytes)
                return sendWhole(errorResponse(503, Self.localMessage), on: connection)
            }
        }
        let key: String?
        do { key = try credential() } catch {
            record(service, .failed, bytes)
            return sendWhole(errorResponse(401, "Pippa: The key for the online service could not be read from the keychain."), on: connection)
        }
        var upstream = URLRequest(url: url)
        upstream.httpMethod = "POST"
        upstream.httpBody = request.body
        upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
        upstream.setValue(request.headers["accept"] ?? "application/json", forHTTPHeaderField: "Accept")
        for name in ["anthropic-version", "anthropic-beta"] {
            if let value = request.headers[name] { upstream.setValue(value, forHTTPHeaderField: name) }
        }
        if let key, !key.isEmpty {
            if self.connection.provider == .anthropic { upstream.setValue(key, forHTTPHeaderField: "x-api-key") }
            else { upstream.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        }
        do {
            let (stream, response) = try await session.bytes(for: upstream)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 502
            var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
            head += "Content-Type: \(http?.value(forHTTPHeaderField: "Content-Type") ?? "application/json")\r\n"
            for name in ["Retry-After", "Request-Id", "X-Request-Id"] {
                if let value = http?.value(forHTTPHeaderField: name) { head += "\(name): \(value)\r\n" }
            }
            head += "Cache-Control: no-store\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            try await send(Data(head.utf8), on: connection)
            var chunk = Data()
            chunk.reserveCapacity(16_384)
            for try await byte in stream {
                chunk.append(byte)
                // Server-Sent Events: forward each line immediately, otherwise in chunks up to 16 KB.
                if byte == 0x0A || chunk.count >= 16_384 {
                    try await send(Self.chunked(chunk), on: connection)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !chunk.isEmpty { try await send(Self.chunked(chunk), on: connection) }
            try await send(Data("0\r\n\r\n".utf8), on: connection)
            connection.cancel()
            record(service, (200..<300).contains(status) ? .done : .failed, bytes)
        } catch {
            record(service, .failed, bytes)
            // Head already sent or Pi gone: just close. Otherwise an error message for Pi.
            if connection.state == .ready {
                sendWhole(errorResponse(502, "Pippa: The online service could not be reached."), on: connection)
            } else {
                connection.cancel()
            }
        }
    }

    private func record(_ service: String, _ outcome: PippaOnlineRecord.Outcome, _ bytes: Int) {
        onRecord(PippaOnlineRecord(service: service, outcome: outcome, bytes: bytes))
        DiagnosticsLog.shared.event("online-gefragt", ["ergebnis": outcome.rawValue, "bytes": String(bytes)])
    }

    static func chunked(_ data: Data) -> Data {
        Data((String(data.count, radix: 16) + "\r\n").utf8) + data + Data("\r\n".utf8)
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { done.resume(throwing: error) } else { done.resume() }
            })
        }
    }

    private func sendWhole(_ response: PippaHTTPResponse, on connection: NWConnection) {
        connection.send(content: response.bytes, completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Reading HTTP

    /// Like `PippaHTTPRequest.parse`, but with room for long histories (`maxRequestBytes`).
    static func parse(_ buffer: Data) -> PippaHTTPRequest.Parse {
        if buffer.count > maxRequestBytes + 65_536 { return .invalid(413) }
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
            if headers[name] != nil, ["content-length", "authorization", "x-api-key", "host"].contains(name) { return .invalid(400) }
            headers[name] = value
        }
        if headers["transfer-encoding"] != nil { return .invalid(411) }
        let length: Int
        if let raw = headers["content-length"] {
            guard let n = Int(raw), n >= 0 else { return .invalid(400) }
            length = n
        } else { length = 0 }
        if length > maxRequestBytes { return .invalid(413) }
        let bodyStart = end.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return .incomplete }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])
        return .complete(PippaHTTPRequest(method: String(start[0]), path: String(start[1]), headers: headers, body: body))
    }
}

public enum PippaOnlineProxyError: Error, Equatable {
    case badPort
}

private final class OnlineOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
