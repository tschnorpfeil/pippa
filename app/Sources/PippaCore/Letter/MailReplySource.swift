import Foundation

/// Host-captured RFC identity. Never populated from generated text or editable card fields.
public struct MailReplySource: Codable, Equatable, Sendable {
    public let messageID: String
    public let replyTo: String?
    public let subject: String

    public init?(messageID: String, replyTo: String?, subject: String) {
        guard let id = Self.canonicalMessageID(messageID), subject.utf8.count <= 8192,
              subject.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        if let replyTo, MailAddress.parse(replyTo).address == nil || replyTo.rangeOfCharacter(from: .controlCharacters) != nil { return nil }
        self.messageID = id; self.replyTo = replyTo; self.subject = subject
    }

    public static func canonicalMessageID(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("<"), value.hasSuffix(">") { value = String(value.dropFirst().dropLast()) }
        guard value.utf8.count <= 998,
              value.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil else { return nil }
        return value
    }

    /// Reads only a bounded RFC header block; .emlx's byte count never exposes its trailing plist.
    public static func capture(from url: URL) -> Self? {
        guard ["eml", "emlx"].contains(url.pathExtension.lowercased()),
              let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: 65_536), !data.isEmpty else { return nil }
        return capture(headers: data, emlx: url.pathExtension.lowercased() == "emlx")
    }

    public static func capture(headers data: Data, emlx: Bool = false) -> Self? {
        guard data.count <= 65_536 else { return nil }
        var text = String(data: data, encoding: .isoLatin1) ?? ""
        if emlx {
            guard let newline = text.firstIndex(of: "\n"), let count = Int(text[..<newline]), count > 0 else { return nil }
            text = String(data: MailParser.bytes(String(text[text.index(after: newline)...])).prefix(count), encoding: .isoLatin1) ?? ""
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard let end = text.range(of: "\n\n") else { return nil }
        let lines = text[..<end.lowerBound].split(separator: "\n", omittingEmptySubsequences: false)
        var fields: [String: String] = [:]; var current: String?
        for line in lines {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard let current else { return nil }
                fields[current, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else {
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let key = line[..<colon].lowercased()
                if fields[key] != nil, ["message-id", "reply-to", "from", "subject"].contains(key) { return nil }
                fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                current = key
            }
        }
        guard let id = fields["message-id"] else { return nil }
        func decoded(_ value: String) -> String { MailParser.decodeWords(MailParser.decode(MailParser.bytes(value), charset: "utf-8")) }
        return Self(messageID: id, replyTo: (fields["reply-to"] ?? fields["from"]).map(decoded), subject: decoded(fields["subject"] ?? ""))
    }
}

/// `notCreated` and `searchIncomplete`: Mail has no new window, so trying again is safe.
/// `unconfirmed`: a reply may already be open; the person checks Mail before trying again.
public enum MailReplyFailure: Error, Equatable, Sendable { case missingOriginal, ambiguousOriginal, unconfirmed, notCreated, searchIncomplete }
