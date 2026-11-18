import Foundation
import Network
import PippaCore

func runModelConnectionChecks() async {
    await checkAsync("Connection test sends its POST to the configured origin only") {
        let receiver = try ConnectionFixture(status: "200 OK")
        defer { receiver.stop() }
        let otherPort = try await receiver.start()
        let redirect = try ConnectionFixture(status: "307 Temporary Redirect", location: "http://127.0.0.1:\(otherPort)/other")
        defer { redirect.stop() }
        let port = try await redirect.start()
        let connection = ModelConnection(provider: .compatible, endpoint: URL(string: "http://127.0.0.1:\(port)"), modelID: "fixture")
        do { try await ModelConnectionTest.check(connection, apiKey: "fixture-key"); return false }
        catch let error as AnswerFailure {
            guard case .pi(.providerUnreachable, _) = error else { return false }
            guard redirect.requests == 1, redirect.sawFixturePOST, receiver.requests == 0 else { return false }
        }
        let direct = ModelConnection(provider: .compatible, endpoint: URL(string: "http://127.0.0.1:\(otherPort)"), modelID: "fixture")
        try await ModelConnectionTest.check(direct, apiKey: "fixture-key")
        return receiver.requests == 1 && receiver.sawFixturePOST
    }
}

private final class ConnectionFixture: @unchecked Sendable {
    private let listener: NWListener
    private let reply: Data
    private let lock = NSLock()
    private var count = 0
    private var sawPOST = false
    var sawFixturePOST: Bool { lock.withLock { sawPOST } }
    var requests: Int { lock.withLock { count } }

    init(status: String, location: String? = nil) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let redirect = location.map { "Location: \($0)\r\n" } ?? ""
        reply = Data("HTTP/1.1 \(status)\r\n\(redirect)Content-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] data, _, _, _ in
                guard data?.isEmpty == false else { connection.cancel(); return }
                let head = String(decoding: data ?? Data(), as: UTF8.self).lowercased()
                lock.withLock {
                    count += 1
                    sawPOST = head.hasPrefix("post ") && head.contains("\r\nauthorization: bearer fixture-key\r\n")
                }
                connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
        for _ in 0..<200 {
            if case .ready = listener.state, let port = listener.port?.rawValue { return port }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.cannotConnectToHost)
    }

    func stop() { listener.cancel() }
}
