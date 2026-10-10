import Foundation

/// What Pippa knows about the person: the `- fact` lines of the memory file that Pi's `remember` tool writes
/// (runtime/pippa-tools/pippa-memory.ts, same format). Settings shows them and lets the person forget each one.
public enum MemoryFacts {
    /// The facts in file order; other lines (a heading the person typed) are ignored, as in pippa-memory.ts.
    public static func read(_ file: URL) -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Removes exactly these facts (`nil`: all) and keeps every other line. Written whole, never half: a temporary
    /// file next to it, then replaced; only the person can read it.
    public static func forget(_ facts: Set<String>?, in file: URL) throws {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { return true }
            let fact = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return facts.map { !$0.contains(fact) } ?? false
        }
        let temp = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp")
        try Data(kept.joined(separator: "\n").utf8).write(to: temp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
    }
}
