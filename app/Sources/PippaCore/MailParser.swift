import Foundation

/// Minimal MIME reader: header lines, first text/plain part (otherwise text/html), attachments.
public enum MailParser {
    public struct Mail: Sendable {
        public var headers: [String: String]; public var body: String; public var attachments: [String]
        /// The message has an HTML part but no text/plain alternative: typical for designed bulk mail, rare for letters.
        public var htmlOnly = false
        /// The attachments' decoded bytes, in the order of `attachments`; empty for a part that carries none (Pippa's
        /// own name-only .eml before 0.3.20).
        public var files: [Attachment] = []
    }

    public struct Attachment: Sendable, Equatable {
        public var name: String
        public var data: Data
        /// An image shown inside the text (`Content-Disposition: inline` with a Content-ID): signature logos and social
        /// icons. A PDF or other document is never inline, even when a mailer gives it a Content-ID.
        public var inline: Bool
    }

    public static func parse(_ data: Data) -> Mail {
        // Lossless: every byte becomes exactly one character (Latin-1). Only per MIME part is it
        // decoded by its charset (`bytes(_:)` gets the bytes back). So "Kündigung" in Latin-1 never becomes "KÃ¼ndigung".
        let raw = String(data: data, encoding: .isoLatin1) ?? ""
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var plain: String?
        var html: String?
        var attachments: [String] = []
        var files: [Attachment] = []
        let (headers, body) = splitPart(text)
        walk(headers: headers, body: body, plain: &plain, html: &html, attachments: &attachments, files: &files, depth: 0)
        var decoded: [String: String] = [:]
        for (k, v) in headers { decoded[k] = decodeWords(decode(bytes(v), charset: "utf-8")) }
        let bodyText = plain ?? html.map(TextReader.stripHTML) ?? ""
        return Mail(headers: decoded, body: bodyText.trimmingCharacters(in: .whitespacesAndNewlines), attachments: attachments,
                    htmlOnly: plain == nil && html != nil, files: files)
    }

    static func splitPart(_ text: String) -> ([String: String], String) {
        let parts = text.components(separatedBy: "\n\n")
        let headerBlock = parts.first ?? ""
        let body = parts.dropFirst().joined(separator: "\n\n")
        var headers: [String: String] = [:]
        var lastKey: String?
        for line in headerBlock.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = line.first, first == " " || first == "\t", let key = lastKey {
                headers[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
                if headers[key] == nil { headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
                lastKey = key
            }
        }
        return (headers, body)
    }

    private static func paramPattern(_ name: String) -> String { "(?i)\(name)\\*?=\\s*(\"([^\"]*)\"|([^;\\s]+))" }

    /// One expression per parameter name `walk` asks for, compiled once; any other name is compiled when asked.
    private static let paramExpressions: [String: NSRegularExpression] = Dictionary(uniqueKeysWithValues:
        ["boundary", "filename", "name", "charset"].map { ($0, try! NSRegularExpression(pattern: paramPattern($0))) })

    static func param(_ name: String, in header: String) -> String? {
        guard let re = paramExpressions[name] ?? (try? NSRegularExpression(pattern: paramPattern(name))),
              let m = re.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else { return nil }
        for g in [2, 3] { if let r = Range(m.range(at: g), in: header) { return String(header[r]) } }
        return nil
    }

    static func walk(headers: [String: String], body: String, plain: inout String?, html: inout String?, attachments: inout [String],
                     files: inout [Attachment], depth: Int) {
        guard depth < 8 else { return }
        let contentType = headers["content-type"] ?? "text/plain"
        let lowerType = contentType.lowercased()
        let disposition = headers["content-disposition"] ?? ""
        if lowerType.hasPrefix("multipart/"), let boundary = param("boundary", in: contentType) {
            let parts = body.components(separatedBy: "--" + boundary)
            for part in parts.dropFirst() {
                if part.hasPrefix("--") { break }
                let trimmed = part.hasPrefix("\n") ? String(part.dropFirst()) : part
                let (h, b) = splitPart(trimmed)
                walk(headers: h, body: b, plain: &plain, html: &html, attachments: &attachments, files: &files, depth: depth + 1)
            }
            return
        }
        let filename = param("filename", in: disposition) ?? param("name", in: contentType)
        let encoding = (headers["content-transfer-encoding"] ?? "").lowercased()
        func content() -> Data {
            if encoding.contains("base64") { return Data(base64Encoded: body.filter { !$0.isWhitespace }) ?? Data() }
            if encoding.contains("quoted-printable") { return quotedPrintable(body) }
            return Self.bytes(body)            // 7bit, 8bit, binary: the original bytes
        }
        if disposition.lowercased().hasPrefix("attachment") || (filename != nil && !lowerType.hasPrefix("text/")) {
            let name = filename.map { decodeWords(decode(Self.bytes($0), charset: "utf-8")) } ?? "Anhang"
            attachments.append(name)
            let inline = !disposition.lowercased().hasPrefix("attachment") && headers["content-id"] != nil && lowerType.hasPrefix("image/")
            files.append(Attachment(name: name, data: content(), inline: inline))
            return
        }
        guard lowerType.hasPrefix("text/") else { return }
        let charset = param("charset", in: contentType)?.lowercased() ?? "utf-8"
        let text = decode(content(), charset: charset)
        if lowerType.hasPrefix("text/plain") { if plain == nil { plain = text } } else if lowerType.hasPrefix("text/html") { if html == nil { html = text } }
    }

    /// Original bytes of a piece from `parse` (there every byte is exactly one Latin-1 character).
    static func bytes(_ s: String) -> Data { s.data(using: .isoLatin1) ?? Data(s.utf8) }

    /// Bytes by the given charset (IANA name). "iso-8859-1" as Windows-1252 like mail programs do (€, „“),
    /// with invalid UTF-8 also Windows-1252, finally Latin-1: never lose text.
    static func decode(_ data: Data, charset: String) -> String {
        var enc = String.Encoding.utf8
        let cf = CFStringConvertIANACharSetNameToEncoding(charset.trimmingCharacters(in: .whitespaces) as CFString)
        if cf != kCFStringEncodingInvalidId { enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)) }
        if enc == .isoLatin1 { enc = .windowsCP1252 }
        return String(data: data, encoding: enc) ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    static func quotedPrintable(_ s: String) -> Data {
        var out = Data()
        let bytes = Array(Self.bytes(s.replacingOccurrences(of: "=\n", with: "")))
        var i = 0
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "="), i + 2 < bytes.count,
               let v = UInt8(String(bytes: bytes[(i + 1)...(i + 2)], encoding: .ascii) ?? "", radix: 16) {
                out.append(v); i += 3
            } else { out.append(bytes[i]); i += 1 }
        }
        return out
    }

    private static let encodedWord = try! NSRegularExpression(pattern: #"=\?([^?]+)\?([QqBb])\?([^?]*)\?="#)

    /// RFC 2047: =?utf-8?Q?...?= and =?utf-8?B?...?=
    static func decodeWords(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        let s = input.replacingOccurrences(of: #"\?=\s+=\?"#, with: "?==?", options: .regularExpression)
        var result = s
        for m in encodedWord.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let whole = Range(m.range, in: s), let cs = Range(m.range(at: 1), in: s),
                  let mode = Range(m.range(at: 2), in: s), let payload = Range(m.range(at: 3), in: s) else { continue }
            let data: Data
            if s[mode].uppercased() == "B" { data = Data(base64Encoded: String(s[payload])) ?? Data() }
            else { data = quotedPrintable(s[payload].replacingOccurrences(of: "_", with: " ")) }
            result.replaceSubrange(whole, with: decode(data, charset: String(s[cs])))
        }
        return result
    }
}
