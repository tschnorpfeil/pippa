import Foundation

/// Mail can offer the same message through several drag representations or temporary file names.
/// Read only a bounded header; subjects and filenames are not message identities.
enum MailDropIdentity {
    static func key(for url: URL) -> String? {
        guard url.pathExtension.lowercased() == "eml", let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024),
              let text = String(data: data, encoding: .isoLatin1) else { return nil }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var headers: [String] = []
        for line in lines {
            if line.isEmpty { break }
            if line.first == " " || line.first == "\t", !headers.isEmpty { headers[headers.count - 1] += line }
            else { headers.append(line) }
        }
        for header in headers {
            guard let colon = header.firstIndex(of: ":"), header[..<colon].lowercased() == "message-id" else { continue }
            let value = header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("<"), value.hasSuffix(">"), value.count > 2 else { return nil }
            return value
        }
        return nil
    }

    static func attachments(_ incoming: [URL], excluding existing: [URL]) -> [URL] {
        var paths = Set(existing.map { $0.standardizedFileURL })
        var messages = Set(existing.compactMap { key(for: $0) })
        return incoming.filter { url in
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path),
                  paths.insert(url.standardizedFileURL).inserted else { return false }
            if let key = key(for: url), !messages.insert(key).inserted { return false }
            return true
        }
    }
}
