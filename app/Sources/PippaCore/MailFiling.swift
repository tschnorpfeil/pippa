import Foundation
import CryptoKit

/// A mail as files Pippa can read: the message as .eml and each real attachment as its own file, in Pippa's cache (never
/// next to a person's own file). Signature logos and icons shown inside the text are left out. `InboxCleanup` removes
/// the folders after 30 days, like every other copy in the inbox.
public enum MailFiling {
    /// Pippa's copies of shown and read mails (the app's `Inbox` uses the same folder).
    public static var inbox: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pippa/Inbox", isDirectory: true)
    }

    /// What saving the attachments of one message did: the files, and the real attachments whose bytes could not be saved.
    public struct AttachmentSave: Sendable, Equatable {
        /// Saved or reused files in message order, with the attachment name each came from.
        public var saved: [SavedFile] = []
        /// Real (not inline) attachments without readable bytes: empty after decoding, or the file could not be written.
        public var unsaved: [String] = []
        /// Inline images left out on purpose.
        public var skippedInline: [String] = []
        /// The message itself could not be read or parsed, so nothing is known about its attachments.
        public var unreadable = false
        public var files: [URL] { saved.map(\.url) }
    }

    public struct SavedFile: Sendable, Equatable {
        public var name: String
        public var url: URL
    }

    /// Writes the attachments of `eml` into `folder` and returns their files in message order. A file already there with
    /// the same bytes is reused, so reading the same mail twice writes nothing new. Empty and inline parts are skipped.
    public static func saveAttachments(of eml: URL, into folder: URL) -> [URL] { save(of: eml, into: folder).files }

    /// As `saveAttachments`, and says what could not be saved so a caller never presents a name as readable content.
    public static func save(of eml: URL, into folder: URL) -> AttachmentSave {
        var result = AttachmentSave()
        guard let data = try? Data(contentsOf: eml) else { result.unreadable = true; return result }
        let all = MailParser.parse(data).files
        result.skippedInline = all.filter(\.inline).map(\.name)
        let real = all.filter { !$0.inline }
        result.unsaved = real.filter { $0.data.isEmpty }.map(\.name)
        let parts = real.filter { !$0.data.isEmpty }
        guard !parts.isEmpty else { return result }
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
            result.unsaved += parts.map(\.name)
            return result
        }
        var taken: Set<String> = [eml.lastPathComponent.lowercased(), sidecarName]
        for part in parts {
            let url = folder.appendingPathComponent(uniqueName(part.name, taken: &taken))
            if (try? Data(contentsOf: url, options: .mappedIfSafe)) != part.data {
                guard (try? part.data.write(to: url, options: .atomic)) != nil else { result.unsaved.append(part.name); continue }
            }
            result.saved.append(SavedFile(name: part.name, url: url))
        }
        return result
    }

    static let sidecarName = ".pippa-mail.json"

    /// Where a filed `.eml` came from in Mail (`inbox`, `sent` or `drafts` when known) and its exact locator.
    public struct FiledOrigin: Codable, Equatable, Sendable {
        public var mailbox: MailBoxKind?
        public var locator: MailLocator?
        public var requiresStrictLocator: Bool

        public init(mailbox: MailBoxKind? = nil, locator: MailLocator? = nil, requiresStrictLocator: Bool = false) {
            self.mailbox = mailbox
            self.locator = locator
            self.requiresStrictLocator = requiresStrictLocator
        }

        private enum CodingKeys: String, CodingKey { case mailbox, locator, requiresStrictLocator }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.mailbox = try c.decodeIfPresent(MailBoxKind.self, forKey: .mailbox)
            self.locator = try c.decodeIfPresent(MailLocator.self, forKey: .locator)
            self.requiresStrictLocator = try c.decodeIfPresent(Bool.self, forKey: .requiresStrictLocator) ?? false
        }
    }

    /// Reads the origin recorded when Pippa filed `eml`, if `eml` is Pippa's own cached copy.
    public static func origin(for eml: URL) -> FiledOrigin? {
        guard ["eml", "emlx"].contains(eml.pathExtension.lowercased()) else { return nil }
        let folder = eml.standardizedFileURL.deletingLastPathComponent()
        guard folder.lastPathComponent.hasPrefix("mail-"),
              let data = try? Data(contentsOf: folder.appendingPathComponent(sidecarName)) else { return nil }
        return try? JSONDecoder().decode(FiledOrigin.self, from: data)
    }

    /// Where the attachments of `eml` go: beside it when it is already Pippa's copy, otherwise a folder of the inbox named
    /// after the file's path and modification date (a person's .eml in Documents stays untouched).
    public static func attachmentFolder(for eml: URL) -> URL {
        let path = eml.standardizedFileURL.path
        if path.hasPrefix(inbox.standardizedFileURL.path + "/") { return eml.deletingLastPathComponent() }
        let modified = (try? eml.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return inbox.appendingPathComponent("attachments-" + stableHash(path + "|" + String(modified)), isDirectory: true)
    }

    /// A mail read from Mail as files: the .eml (Mail's original message when it gave one) and its attachments, in one
    /// folder per message under `root`, so reading the same mail again reuses them. `notSaved` names every attachment
    /// Mail lists whose bytes are not in a file (not even a name-only stand-in is readable content).
    public static func file(_ mail: MailMessage, root: URL = inbox, scope: [String] = [], origin: FiledOrigin? = nil) throws -> (eml: URL, attachments: [URL], notSaved: [String]) {
        let text = mail.emlText
        // A Message-ID can occur in several accounts. Content changes must also leave earlier attachment paths intact.
        let effectiveLocator = origin?.locator ?? mail.locator
        var identity: [String: Any] = ["messageID": mail.messageID ?? "", "account": effectiveLocator?.account ?? "",
                                       "accountID": effectiveLocator?.accountID ?? "",
                                       "path": effectiveLocator?.path ?? [], "mailID": effectiveLocator?.mailID ?? 0,
                                       "scope": scope, "content": text]
        if let kind = origin?.mailbox { identity["mailbox"] = kind.rawValue }
        if origin?.requiresStrictLocator == true { identity["strictOrigin"] = true }
        let bytes = try JSONSerialization.data(withJSONObject: identity, options: .sortedKeys)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let folder = root.appendingPathComponent("mail-" + digest, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let origin, let encoded = try? JSONEncoder().encode(origin) {
            try encoded.write(to: folder.appendingPathComponent(sidecarName), options: .atomic)
        }
        let eml = folder.appendingPathComponent(mail.fileName)
        if (try? String(contentsOf: eml, encoding: .utf8)) != text { try text.write(to: eml, atomically: true, encoding: .utf8) }
        let result = save(of: eml, into: folder)
        return (eml, result.files, notSaved(mail.attachmentNames, result))
    }

    /// The names Mail lists that have no readable file: real attachments that failed to save, and listed names that the
    /// message neither saved nor skipped as an inline image (Mail's source can lack parts it has not downloaded).
    static func notSaved(_ listed: [String], _ result: AttachmentSave) -> [String] {
        if result.unreadable { return listed }
        var accounted: [String: Int] = [:], names = result.unsaved
        for name in result.saved.map(\.name) + result.skippedInline + result.unsaved {
            accounted[comparable(name), default: 0] += 1
        }
        for name in listed {
            let key = comparable(name)
            if accounted[key, default: 0] > 0 { accounted[key, default: 0] -= 1 }
            else { names.append(name) }
        }
        return names
    }

    private static func comparable(_ name: String) -> String {
        Naming.sanitize(name, maxLength: 120).precomposedStringWithCanonicalMapping.lowercased()
    }

    /// File name from the attachment's own name; "Anhang" when it has none, " 2", " 3" … when two share a name.
    static func uniqueName(_ raw: String, taken: inout Set<String>) -> String {
        let clean = Naming.sanitize(raw, maxLength: 120)
        let name = clean.isEmpty ? "Anhang" : clean
        let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
        var candidate = name, n = 2
        while taken.contains(candidate.lowercased()) {
            candidate = base + " \(n)" + (ext.isEmpty ? "" : "." + ext); n += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }

    /// FNV-1a over the UTF-8 bytes: the same text always gives the same folder name, across launches.
    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(format: "%016llx", hash)
    }
}
