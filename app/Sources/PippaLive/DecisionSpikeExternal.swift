import Foundation

// Optional external models for the decision spike so that candidates such as Laya or Kev-0.8B
// are measured with exactly the same data, prompts and metrics as Apple FM.
//
//   DECIDE_CHAT_URL   OpenAI-compatible chat endpoint, e.g. http://127.0.0.1:8081/v1/chat/completions
//                     (llama-server). Answers are enforced via JSON schema (response_format).
//   DECIDE_CHAT_NAME  Display name in the tables (default "External")
//   DECIDE_EMBED_URL  OpenAI-compatible embeddings endpoint, e.g. http://127.0.0.1:8082/v1/embeddings
//                     (llama-server --embedding). Measured as an additional embedding method.
//   DECIDE_EMBED_NAME Display name (default "External embedding")
//   DECIDE_ONLY_EXTERNAL=1  Set Apple FM repetitions to 1 (saves time, system-framework numbers already exist)
//   DECIDE_OUT        Output folder instead of the spike directory (so a run doesn't overwrite the checked-in results)

@MainActor
enum External {
    static let env = ProcessInfo.processInfo.environment
    static var chatURL: URL? { env["DECIDE_CHAT_URL"].flatMap(URL.init(string:)) }
    static var chatName: String { env["DECIDE_CHAT_NAME"] ?? "External" }
    static var embedURL: URL? { env["DECIDE_EMBED_URL"].flatMap(URL.init(string:)) }
    static var embedName: String { env["DECIDE_EMBED_NAME"] ?? "External embedding" }

    static func post(_ url: URL, _ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "External", code: (resp as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: data.prefix(200), as: UTF8.self)])
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "External", code: -2, userInfo: [NSLocalizedDescriptionKey: "no JSON response"])
        }
        return obj
    }

    /// One chat call with enforced JSON schema, greedy (temperature 0), fresh history.
    static func chat(_ system: String, _ user: String, schema: [String: Any], maxTokens: Int = 256) async -> (FMOutcome<[String: Any]>, Double) {
        guard let url = chatURL else { return (.error("DECIDE_CHAT_URL missing"), 0) }
        let clock = ContinuousClock()
        let t = clock.now
        let body: [String: Any] = [
            "model": env["DECIDE_CHAT_MODEL"] ?? "local",
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "temperature": 0, "max_tokens": maxTokens,
            "response_format": ["type": "json_schema", "json_schema": ["name": "antwort", "strict": true, "schema": schema]],
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        do {
            let obj = try await post(url, body)
            guard let choices = obj["choices"] as? [[String: Any]], let msg = choices.first?["message"] as? [String: Any],
                  var content = msg["content"] as? String else { return (.error("unexpected response"), Stat.ms(clock.now - t)) }
            if let r = content.range(of: "</think>") { content = String(content[r.upperBound...]) }
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any] else {
                return (.error("not valid JSON: \(content.prefix(80))"), Stat.ms(clock.now - t))
            }
            return (.ok(parsed), Stat.ms(clock.now - t))
        } catch {
            return (.error(String(describing: error).prefix(120).description), Stat.ms(clock.now - t))
        }
    }

    static func embed(_ texts: [String]) async throws -> [[Double]] {
        guard let url = embedURL else { return [] }
        var out: [[Double]] = []
        for batch in stride(from: 0, to: texts.count, by: 16).map({ Array(texts[$0..<min($0 + 16, texts.count)]) }) {
            let obj = try await post(url, ["model": env["DECIDE_EMBED_MODEL"] ?? "local", "input": batch])
            guard let data = obj["data"] as? [[String: Any]] else { throw NSError(domain: "External", code: -3) }
            let sorted = data.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
            out += sorted.map { ($0["embedding"] as? [NSNumber] ?? []).map(\.doubleValue) }
        }
        return out
    }

    static let intentSchema: [String: Any] = [
        "type": "object", "additionalProperties": false, "required": ["absicht"],
        "properties": ["absicht": ["type": "string", "enum": ["ordnen", "rechnungen", "fristen", "texthilfe", "erinnerung", "frage", "sonstiges"]]],
    ]
    static func pickSchema(_ n: Int) -> [String: Any] {
        ["type": "object", "additionalProperties": false, "required": ["nummern"],
         "properties": ["nummern": ["type": "array", "minItems": 3, "maxItems": 3, "items": ["type": "integer", "minimum": 1, "maximum": n]]]]
    }
    static let claimSchema: [String: Any] = [
        "type": "object", "additionalProperties": false, "required": ["gestuetzt"],
        "properties": ["gestuetzt": ["type": "boolean"]],
    ]
}
