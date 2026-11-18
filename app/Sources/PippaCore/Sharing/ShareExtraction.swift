import Foundation

/// Reads what the person wants to share, on this Mac and by Pippa's own code, never by a model: the text the review
/// shows comes from the apps and files themselves, and each part carries the source it was read from.
/// Images are never sent: a picture becomes the text recognized in it on this Mac. File paths stay here: parts are
/// named by file name only.
public struct ShareExtraction: Sendable {
    public enum Failure: LocalizedError, Equatable {
        case blocked(String)
        public var errorDescription: String? { if case .blocked(let tell) = self { tell } else { nil } }
    }

    let host: PippaMCPHost
    public init(host: PippaMCPHost) { self.host = host }

    // MARK: Files (Documents, saved emails as Mail, pictures as Photos)

    /// One part per file or folder, by its kind (`SharingSource.of`). Reading is local: PDFs, Office files and scans
    /// through `TextReader`, emails through `MailParser`.
    public static func files(_ urls: [URL], rules: SourceSharing = SourceSharing()) -> [SharePiece] {
        urls.map { url in
            let sources = SharingSource.sources(forFile: url)
            guard rules.mayOffer(sources) else {
                return SharePiece(sources: sources, title: url.lastPathComponent, text: "")
            }
            var piece = file(url.resolvingSymlinksInPath())
            piece.sources.formUnion(sources)
            return piece
        }
    }

    static func file(_ url: URL) -> SharePiece {
        let name = url.lastPathComponent
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
            let shown = names.prefix(50).map { "- " + $0 }.joined(separator: "\n")
            let more = names.count > 50 ? "\n" + L("… and %lld more", table: "Core", names.count - 50) : ""
            return SharePiece(sources: SharingSource.sources(forFile: url), title: L("Folder “%@”", table: "Core", name),
                              text: names.isEmpty ? L("(The folder is empty.)", table: "Core") : shown + more)
        }
        switch SharingSource.of(file: url) {
        case .mail:
            guard let data = mailData(url) else {
                return SharePiece(sources: [.mail], title: name, text: L("(Pippa couldn’t read this email.)", table: "Core"))
            }
            let mail = MailParser.parse(data)
            let subject = mail.headers["subject"] ?? name
            return SharePiece(sources: [.mail], title: L("Email “%@”", table: "Core", subject),
                              text: SharePiece.bounded(mailText(from: mail.headers["from"], date: mail.headers["date"], subject: subject,
                                                                body: mail.body, attachments: mail.attachments)))
        case .photos:
            let read = TextReader.read(url, options: TextReader.Options(maxPages: 1, ocr: true))
            let text = read.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            return SharePiece(sources: [.photos], title: L("Picture “%@”", table: "Core", name),
                              text: text.isEmpty ? L("(No text was found in this picture. The picture itself is never sent.)", table: "Core")
                                  : L("Text recognized in the picture on this Mac:", table: "Core") + "\n" + SharePiece.bounded(text))
        default:
            let read = TextReader.read(url)
            let text = read.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard read.problem == .none, !text.isEmpty else {
                return SharePiece(sources: [.documents], title: name, text: L("(Pippa couldn’t read text from this file.)", table: "Core"))
            }
            return SharePiece(sources: [.documents], title: name, text: SharePiece.bounded(read.isTruncated
                ? text + "\n" + L("[… shortened on this Mac]", table: "Core") : text))
        }
    }

    private static func mailData(_ url: URL) -> Data? {
        guard ["eml", "emlx"].contains(url.pathExtension.lowercased()),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard url.pathExtension.lowercased() == "emlx" else { return data }
        // Apple Mail appends a property list after exactly this many MIME bytes.
        guard let newline = data.prefix(24).firstIndex(of: 10),
              let count = Int(String(decoding: data[..<newline], as: UTF8.self)), count > 0 else { return nil }
        let payload = data.suffix(from: data.index(after: newline))
        guard payload.count >= count else { return nil }
        return Data(payload.prefix(count))
    }

    static func mailText(from: String?, date: String?, subject: String, body: String, attachments: [String]) -> String {
        var lines: [String] = []
        if let from, !from.isEmpty { lines.append(L("From: %@", table: "Core", from)) }
        if let date, !date.isEmpty { lines.append(L("Date: %@", table: "Core", date)) }
        lines.append(L("Subject: %@", table: "Core", subject))
        if !attachments.isEmpty { lines.append(L("Attachments (not shared): %@", table: "Core", attachments.joined(separator: ", "))) }
        return lines.joined(separator: "\n") + "\n\n" + body
    }

    // MARK: Apps

    /// The email selected in Mail.
    public func selectedMail() async throws -> SharePiece {
        try await open(.mail)
        guard let mail = try await host.integrations.selectedMail() else {
            throw Failure.blocked(L("Select an email in Mail first, then try again.", table: "Core"))
        }
        let date = mail.date.map { Self.format($0, "EEE d MMM y HH:mm") }
        return SharePiece(sources: [.mail], title: L("Email “%@”", table: "Core", mail.subject),
                          text: SharePiece.bounded(Self.mailText(from: mail.sender, date: date, subject: mail.subject, body: mail.body,
                                                                 attachments: mail.attachmentNames)))
    }

    /// Appointments from today through the next `days` days, as in `calendar_read`: no cancelled or declined ones.
    public func calendar(days: Int = 7) async throws -> SharePiece {
        try await open(.calendar)
        let start = host.calendar.startOfDay(for: host.now())
        let end = host.calendar.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(Double(days) * 86_400)
        let fetch = try await host.integrations.events(in: DateInterval(start: start, end: end), limit: 60)
        let events = fetch.events.filter { $0.status != .cancelled && !$0.declined }.sorted { $0.start < $1.start }
        let lines = events.map { event -> String in
            let when = event.allDay ? Self.format(event.start, "EEE d MMM") + " · " + L("all day", table: "Core")
                : Self.format(event.start, "EEE d MMM HH:mm") + "–" + Self.format(event.end, "HH:mm")
            return "- " + when + " · " + SharePiece.line(event.title) + (event.location.map { " · " + SharePiece.line($0) } ?? "")
        }
        return SharePiece(sources: [.calendar], title: L("Calendar, next %lld days", table: "Core", days),
                          text: lines.isEmpty ? L("(Nothing in the calendar.)", table: "Core") : lines.joined(separator: "\n"))
    }

    /// Reminders that are not done yet.
    public func reminders() async throws -> SharePiece {
        try await open(.reminders)
        let fetch = try await host.hostData.openReminders(dueBefore: nil, limit: 50)
        let lines = fetch.items.map { item -> String in
            let due = item.due.map { " · " + Self.format($0, item.dueHasTime ? "EEE d MMM HH:mm" : "EEE d MMM") } ?? ""
            return "- " + SharePiece.line(item.title) + due
        }
        return SharePiece(sources: [.reminders], title: L("Open reminders", table: "Core"),
                          text: lines.isEmpty ? L("(No open reminders.)", table: "Core") : lines.joined(separator: "\n"))
    }

    /// Permission first, with the same sentences as Pippa's tools; macOS asks only when the person is using the feature.
    private func open(_ integration: Integration) async throws {
        var access = await host.integrations.access(integration)
        if access == .notDetermined && host.askForAccess { access = await host.integrations.requestAccess(integration) }
        switch access {
        case .granted: return
        case .notDetermined: throw Failure.blocked(PippaMCPTools.notYet(integration))
        case .denied: throw Failure.blocked(PippaMCPTools.denied(integration))
        case .unavailable(let why): throw Failure.blocked(why)
        }
    }

    static func format(_ date: Date, _ template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
