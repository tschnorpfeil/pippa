import Foundation

/// "Test connection" in the settings: a small request to the person's own online service, directly in Swift.
/// Same two shapes Pi uses (`PiOnlineProvider`): OpenAI shape `<address>/chat/completions`, Anthropic shape
/// `<address>/v1/messages`. The person clicked "Test"; only a fixed sentence goes out, no content.
public enum ModelConnectionTest {
    static let prompt = "Connection test. Reply with: ok"

    /// The request (visible for checks without network). The key is only in the header.
    public static func request(_ connection: ModelConnection, apiKey: String, timeout: TimeInterval = 30) throws -> URLRequest {
        try connection.validated()
        guard let url = URL(string: PiOnlineProvider.baseURL(connection) + PiOnlineProvider.chatPath(connection.provider)) else { throw InferenceError.invalidConnection(AnswerFailureCode.providerRejected.fallbackText) }
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

    /// Response status and body -> error in everyday language (401/403 key, 429/503/529 busy or quota,
    /// 400/404/405/422 rejected, otherwise unreachable). `nil`: the connection works.
    public static func failure(status: Int, body: String = "") -> AnswerFailure? {
        switch status {
        case 200..<300: nil
        case 401, 403: .pi(.authFailed, AnswerFailureCode.authFailed.fallbackText)
        case 429:
            PiProviderClient.problem(in: body) == .quota
                ? .pi(.providerRejected, L("Your online AI limit is reached for now. Try again later, or check your account.", table: "Core"))
                : .pi(.providerBusy, AnswerFailureCode.providerBusy.fallbackText)
        case 503, 529: .pi(.providerBusy, AnswerFailureCode.providerBusy.fallbackText)
        case 400, 404, 405, 422: .pi(.providerRejected, AnswerFailureCode.providerRejected.fallbackText)
        default: .pi(.providerUnreachable, AnswerFailureCode.providerUnreachable.fallbackText)
        }
    }

    /// "Test connection": validate, require a key for online services, then send the fixed sentence.
    public static func check(_ connection: ModelConnection, apiKey: String) async throws {
        try connection.validated()
        guard connection.isLocal || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw InferenceError.missingCredential }
        try await run(connection, apiKey: apiKey)
    }

    /// The default transport refuses every redirect. An injected session supplies its own redirect policy.
    public static func run(_ connection: ModelConnection, apiKey: String, session: URLSession? = nil) async throws {
        let request = try request(connection, apiKey: apiKey)
        let transport = session ?? URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        defer { if session == nil { transport.finishTasksAndInvalidate() } }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await transport.data(for: request) } catch is CancellationError { throw CancellationError() } catch {
            throw AnswerFailure.pi(.providerUnreachable, AnswerFailureCode.providerUnreachable.fallbackText)
        }
        let body = String(decoding: data.prefix(4096), as: UTF8.self)
        if let failure = failure(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body) { throw failure }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
