import Foundation

/// "Test connection" in the settings: a small request to the person's own online service, directly in Swift.
/// Same two shapes as the intermediary
/// (`PippaOnlineProxy`, `PiOnlineProvider`): OpenAI shape `<address>/chat/completions`, Anthropic shape
/// `<address>/v1/messages`. The person clicked "Test"; only a fixed sentence goes out, no content.
public enum ModelConnectionTest {
    static let prompt = "Connection test. Reply with: ok"

    /// The request (visible for checks without network). The key is only in the header.
    public static func request(_ connection: ModelConnection, apiKey: String, timeout: TimeInterval = 30) throws -> URLRequest {
        try connection.validated()
        var endpoint = connection.endpoint.absoluteString
        while endpoint.hasSuffix("/") { endpoint.removeLast() }
        let path = PiOnlineProvider.allowedPaths(connection.provider).first ?? "/chat/completions"
        guard let url = URL(string: endpoint + path) else { throw InferenceError.invalidConnection(AnswerFailureCode.providerRejected.fallbackText) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let messages = [["role": "user", "content": prompt]]
        let body: [String: Any]
        switch connection.provider {
        case .anthropic:
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "x-api-key") }
            body = ["model": connection.modelID, "max_tokens": 16, "messages": messages]
        case .openAI:
            if !apiKey.isEmpty { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
            body = ["model": connection.modelID, "max_completion_tokens": 16, "messages": messages]
        case .compatible:
            if !apiKey.isEmpty { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
            body = ["model": connection.modelID, "max_tokens": 16, "messages": messages, "stream": false]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Response status -> error in everyday language (401/403 key, 400/404/422 rejected,
    /// otherwise unreachable). `nil`: the connection works.
    public static func failure(status: Int) -> AnswerFailure? {
        switch status {
        case 200..<300: nil
        case 401, 403: .pi(.authFailed, AnswerFailureCode.authFailed.fallbackText)
        case 400, 404, 405, 422: .pi(.providerRejected, AnswerFailureCode.providerRejected.fallbackText)
        default: .pi(.providerUnreachable, AnswerFailureCode.providerUnreachable.fallbackText)
        }
    }

    public static func run(_ connection: ModelConnection, apiKey: String, session: URLSession = .shared) async throws {
        let request = try request(connection, apiKey: apiKey)
        let response: URLResponse
        do { (_, response) = try await session.data(for: request) } catch is CancellationError { throw CancellationError() } catch {
            throw AnswerFailure.pi(.providerUnreachable, AnswerFailureCode.providerUnreachable.fallbackText)
        }
        if let failure = failure(status: (response as? HTTPURLResponse)?.statusCode ?? 0) { throw failure }
    }
}
