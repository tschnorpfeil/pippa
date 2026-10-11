import Foundation

/// A file change Pi made in a conversation that can be taken back (session entry `pippa-change`, pippa-assist.ts).
/// Recorded in the journal at the end of the answer (`Executor.recordAgentChanges`), so "Undo" under the answer works
/// like Undo after tidying up.
public struct AgentChange: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// `to` was changed; the old version is the copy at `from` (Pippa's backup folder).
        case restore
        /// `to` is new; undo moves it to the Trash.
        case create
        /// Moved from `from` to `to`.
        case move
        /// Moved from `from` into the Trash at `to`.
        case trash
    }
    public var kind: Kind
    public var from: String?
    public var to: String

    public init(kind: Kind, from: String?, to: String) {
        self.kind = kind; self.from = from; self.to = to
    }

    /// The changes in one `pippa-change` entry (`{"v":1,"changes":[…]}`); anything incomplete or not absolute is dropped.
    public static func parse(_ json: String) -> [AgentChange] {
        guard let record = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let changes = record["changes"] as? [[String: Any]] else { return [] }
        return changes.compactMap { c in
            let absolute = { (key: String) -> String? in (c[key] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil } }
            switch c["kind"] as? String {
            case "restore": return absolute("file").flatMap { file in absolute("copy").map { AgentChange(kind: .restore, from: $0, to: file) } }
            case "create": return absolute("file").map { AgentChange(kind: .create, from: nil, to: $0) }
            case "move": return absolute("from").flatMap { from in absolute("to").map { AgentChange(kind: .move, from: from, to: $0) } }
            case "trash": return absolute("from").flatMap { from in absolute("to").map { AgentChange(kind: .trash, from: from, to: $0) } }
            default: return nil
            }
        }
    }

    /// The changes worth keeping, in order: per file only the first old version or "new" (the state before the answer).
    public static func merged(_ changes: [AgentChange]) -> [AgentChange] {
        var seen = Set<String>()
        return changes.filter { change in
            guard change.kind == .restore || change.kind == .create else { return true }
            return seen.insert(change.to).inserted
        }
    }

    /// Where the file of change `index` is at the end of the answer: later moves (or the Trash) of the same path followed.
    public static func finalPath(of index: Int, in changes: [AgentChange]) -> String {
        var path = changes[index].to
        for later in changes.dropFirst(index + 1) where (later.kind == .move || later.kind == .trash) && later.from == path {
            path = later.to
        }
        return path
    }
}
