import Foundation

/// A structured call directly to the local llama-server (OpenAI-compatible `/v1/chat/completions` with
/// `response_format: json_schema`), without Pi and without Node. Only one fixed task uses it any more: classifying an
/// unclear document while tidying when Apple's on-device model is not available (`TidyClassifier`, `LocalEngine.askModel`;
/// keep or drop after measuring it against Pi with K2). Temperature 0.1, thinking off, response limit a quarter of the
/// context (at most 4096), grammar from the schema. The response is checked in code (Decodable + checks), never trusted.
public enum LocalModelJSON {
    public enum Failure: Error, Equatable, Sendable {
        /// System, user text and schema together larger than the context allows.
        case messageTooLong
        /// Response empty, truncated or not a JSON object.
        case invalidResponse
        /// The server answered with an error status.
        case server(Int)
    }

    /// As `localProfile` in the old core: a quarter of the context, at most 4096 tokens.
    public static func maxTokens(contextWindow: Int) -> Int { min(4096, max(256, contextWindow / 4)) }

    /// The request as a JSON object (visible for checks without a server).
    public static func body(modelID: String, system: String, user: String, schema: String, name: String, contextWindow: Int) throws -> [String: Any] {
        guard let schemaObject = try? JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any],
              name.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else { throw Failure.invalidResponse }
        guard !system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Failure.messageTooLong
        }
        // Same limit as structured.mjs: bytes of system, user text and schema ≤ min(32000, 2 × context).
        guard (system + user + schema).utf8.count <= min(32000, contextWindow * 2) else { throw Failure.messageTooLong }
        return [
            "model": modelID,
            "messages": [["role": "system", "content": system + "\nReturn only JSON matching this schema: " + schema],
                         ["role": "user", "content": user]],
            "temperature": 0.1,
            "max_tokens": maxTokens(contextWindow: contextWindow),
            "stream": false,
            "chat_template_kwargs": ["enable_thinking": false],
            "response_format": ["type": "json_schema", "json_schema": ["name": name, "strict": true, "schema": schemaObject]],
        ]
    }

    /// The response text (JSON). Throws on cancellation (`CancellationError`), server error or truncated response.
    public static func request(_ lease: LlamaServer.AgentLease, system: String, user: String, schema: String, name: String,
                               timeout: TimeInterval = 300, session: URLSession = .shared) async throws -> Data {
        let body = try body(modelID: lease.modelID, system: system, user: user, schema: schema, name: name, contextWindow: lease.contextWindow)
        var request = URLRequest(url: lease.endpoint.appendingPathComponent("chat/completions"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(lease.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw Failure.server(http.statusCode) }
        return try content(of: data)
    }

    /// `choices[0].message.content` of a response; `finish_reason: length` counts as unusable (as in the old core).
    public static func content(of data: Data) throws -> Data {
        guard data.count <= 4 * 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (object["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any],
              let text = message["content"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.invalidResponse }
        if (choice["finish_reason"] as? String) == "length" { throw Failure.invalidResponse }
        guard text.utf8.count <= 1024 * 1024 else { throw Failure.invalidResponse }
        return Data(text.utf8)
    }
}
