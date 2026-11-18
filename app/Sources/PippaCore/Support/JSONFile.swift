import Darwin
import Foundation

/// JSON files that Pippa merges into or writes for Pi and the local server (models.json, settings.json, the launch file).
enum JSONFile {
    static let writingOptions: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

    /// The top-level object, or `nil` if the file is missing, unreadable or not an object (comments are not JSON).
    static func readObject(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// A file Pi reads, parsed as the bundled Pi parses it: a leading byte order mark is ignored (`stripBom`) and, with
    /// `comments` (models.json), `//` comments and trailing commas too (`stripJsonComments` in Pi's `utils/json.js`).
    /// `nil` like `readObject`. Where the two parsers could still differ, the private folder an online Pi runs in is
    /// written from Pi's own parse (`pi-providers.mjs prepare`), so a difference refuses the turn and never redirects it.
    static func readPiObject(_ url: URL, comments: Bool = false) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), var text = String(data: data, encoding: .utf8) else { return nil }
        if text.unicodeScalars.first == "\u{FEFF}" { text.unicodeScalars.removeFirst() }
        if comments { text = stripJsonComments(text) }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// Pi's `stripJsonComments` with the same two expressions, spelled for ICU: JavaScript's `.` (no line terminator)
    /// and `\s` are written out, as ICU's differ.
    static func stripJsonComments(_ input: String) -> String {
        let string = #""(?:\\[^\n\r\u2028\u2029]|[^"\\])*""#
        let space = #"[\t\n\u000B\f\r \u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF]"#
        let withoutComments = replace(input, string + #"|//[^\n]*"#) { match, _ in match.hasPrefix("\"") ? match : "" }
        return replace(withoutComments, string + #"|,("# + space + #"*[}\]])"#) { match, tail in tail ?? match }
    }

    private static func replace(_ text: String, _ pattern: String, _ with: (String, String?) -> String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
        let source = text as NSString
        var result = "", last = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            let group = match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound ? source.substring(with: match.range(at: 1)) : nil
            result += with(source.substring(with: match.range), group)
            last = match.range.location + match.range.length
        }
        return result + source.substring(from: last)
    }

    /// Key-sorted bytes to compare two values regardless of key order.
    static func canonical(_ value: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    /// The file's text: pretty, sorted keys, a final newline.
    static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: writingOptions) + Data("\n".utf8)
    }

    /// Writes next to the target as `.<name>.pippa-<uuid>`, sets the mode, then renames over it (atomic). `mode`:
    /// `nil` keeps the mode of an existing file and uses 0600 for a new one. The parent folder must exist.
    static func writeAtomically(_ data: Data, to url: URL, mode: Int? = nil) throws {
        let fm = FileManager.default
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).pippa-\(UUID().uuidString)")
        do {
            try data.write(to: temporary)
            let existing = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
            try fm.setAttributes([.posixPermissions: mode ?? existing ?? 0o600], ofItemAtPath: temporary.path)
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temporary)
            throw PiInstallFailure.notWritable(path: url.path, reason: SystemError.reason(errno: code))
        }
    }
}
