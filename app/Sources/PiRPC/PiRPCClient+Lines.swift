import Foundation

extension PiRPCClient {
    public static let readResultLimit = 200_000
    /// Every other tool: enough for a whole error message or a written file's summary.
    public static let resultLimit = 4_000
    /// A single argument value (a file's new content, a long command); paths and search words stay whole.
    public static let argumentValueLimit = 2_000
    public static let listingResultLimit = 20_000
    /// `web_search`: enough to find its result links for the sources card (PiTurnReceipt.webSources).
    static let listingTools: Set<String> = ["bash", "find", "grep", "ls", "web_search"]

    /// Pi's answer to a prompt while a summary runs (Pi 1.1: "Cannot submit a prompt while compaction is in progress").
    static func isCompactionBusy(_ error: PiRPCError) -> Bool {
        guard case .commandFailed(let command, let message) = error else { return false }
        return command == "prompt" && message.localizedCaseInsensitiveContains("compaction is in progress")
    }

    static func disposition(_ response: Response) -> String? {
        response.data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["disposition"] as? String
    }

    static func text(of message: [String: Any]) -> String {
        if let text = message["content"] as? String { return text }
        return (message["content"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
    }

    /// Sorted JSON of the arguments with each long string shortened, so the JSON stays valid and short values that
    /// sort after a long one (a `path` after `content`) are never lost.
    static func json(_ value: Any?, valueLimit: Int) -> String {
        func shorten(_ value: Any) -> Any {
            switch value {
            case let text as String: text.count > valueLimit ? String(text.prefix(valueLimit)) + "…" : text
            case let object as [String: Any]: object.mapValues(shorten)
            case let list as [Any]: list.map(shorten)
            default: value
            }
        }
        guard let value, let data = try? JSONSerialization.data(withJSONObject: shorten(value), options: [.fragmentsAllowed, .sortedKeys]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
