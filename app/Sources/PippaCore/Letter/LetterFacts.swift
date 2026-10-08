import Foundation

// Letter: the first line after a call in Mail or for a given letter.
// Everything here is code without a model and without file access (pattern from Deadlines.swift and Analysis.swift), fast enough
// for the first line. Only `FirstLineBuilder.refined` optionally asks the system's small language model, never the large one.
// Callers still do not read files on the cooperative pool (reading is their business, not this code's).

/// What the code finds in a mail or letter.
public struct LetterFacts: Sendable, Equatable {
    /// Display name (`Heuristics.displayName`), never an address or a path.
    public var sender: String?
    public var senderAddress: String?
    public var subject: String?
    public var amount: Decimal?
    /// Literal line where the amount appears.
    public var amountEvidence: String?
    /// The most important upcoming deadline.
    public var deadline: Deadline?
    /// Upcoming deadlines from the patterns, at most five, by date.
    public var deadlines: [Deadline]
    public var attachmentNames: [String]
    /// `.mail` for a call in Mail, `.letter` for a document.
    public var taskKind: TaskKind

    public init(sender: String? = nil, senderAddress: String? = nil, subject: String? = nil, amount: Decimal? = nil,
                amountEvidence: String? = nil, deadline: Deadline? = nil, deadlines: [Deadline] = [],
                attachmentNames: [String] = [], taskKind: TaskKind = .letter) {
        self.sender = sender; self.senderAddress = senderAddress; self.subject = subject; self.amount = amount
        self.amountEvidence = amountEvidence; self.deadline = deadline; self.deadlines = deadlines
        self.attachmentNames = attachmentNames; self.taskKind = taskKind
    }
}

public enum LetterReading {
    /// At most this many deadlines in `LetterFacts.deadlines`.
    static let maxDeadlines = 5
    /// Order by which the most important deadline is chosen; then the earlier date decides.
    static let priority: [Deadline.Kind] = [.payment, .objection, .cancellation, .appointment, .generic, .contractEnd, .debit]
    /// Words in the evidence line that let an uncertain amount count anyway.
    static let amountWords = ["zahl", "nachzahlung", "betrag", "fällig"]
    /// The patterns read at most this much of a mail's text.
    static let bodyLimit = 60_000

    /// Facts about a mail from Mail. The deadlines carry the mail's file name as source (like the stored .eml).
    public static func facts(mail: MailMessage, today: DayDate = DayDate(Date())) -> LetterFacts {
        let placeholder = FileManager.default.temporaryDirectory.appendingPathComponent(mail.fileName)
        var result = facts(document: document(for: mail, url: placeholder), today: today)
        let parsed = MailAddress.parse(mail.sender)
        let named = parsed.name.map { Heuristics.displayName($0) }.flatMap(usableName)
        result.sender = named ?? result.sender
        result.senderAddress = parsed.address
        let subject = mail.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        result.subject = subject.isEmpty ? nil : subject
        result.attachmentNames = mail.attachmentNames
        result.taskKind = .mail
        return result
    }

    /// Facts about a document that was read (letter, PDF, .eml).
    public static func facts(document: DocumentText, today: DayDate = DayDate(Date())) -> LetterFacts {
        let text = document.fullText
        let rawSender = Heuristics.sender(text: text, headers: document.headers)
        let sender = rawSender.map { Heuristics.displayName($0) }.flatMap(usableName)

        var amount: Decimal?
        var evidence: String?
        if let found = Heuristics.invoiceAmount(text: text) {
            let lower = found.evidence.lowercased()
            let named = amountWords.contains { lower.contains($0) }
            if found.sure || named {
                amount = found.amount
                evidence = found.evidence
            }
        }

        let patterns = Deadlines.find(in: document, today: today)
        let upcoming = patterns.filter { d in
            guard let date = d.date else { return true }
            return date >= today
        }
        let deadlines = Array(upcoming.prefix(maxDeadlines))
        let subject = document.headers["subject"].flatMap { s -> String? in
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return LetterFacts(sender: sender, senderAddress: nil, subject: subject, amount: amount, amountEvidence: evidence,
                           deadline: mostRelevant(deadlines), deadlines: deadlines, attachmentNames: document.attachments,
                           taskKind: .letter)
    }

    /// Text of the mail as a document, so that the same patterns apply as for a stored .eml.
    public static func document(for mail: MailMessage, url: URL) -> DocumentText {
        // The patterns need the beginning; a huge newsletter should not hold up the first line.
        let body = mail.body.count > bodyLimit ? String(mail.body.prefix(bodyLimit)) : mail.body
        var doc = DocumentText(url: url, pages: [body], isPaged: false, usedOCR: false,
                               headers: ["from": mail.sender, "subject": mail.subject])
        doc.attachments = mail.attachmentNames
        return doc
    }

    /// First by kind (amounts before objection before cancellation ...), then the earlier date; no date last.
    static func mostRelevant(_ deadlines: [Deadline]) -> Deadline? {
        func rank(_ kind: Deadline.Kind) -> Int { priority.firstIndex(of: kind) ?? priority.count }
        let far = DayDate(year: 2100, month: 12, day: 31)!
        return deadlines.min { a, b in
            let ra = rank(a.kind)
            let rb = rank(b.kind)
            if ra != rb { return ra < rb }
            return (a.date ?? far) < (b.date ?? far)
        }
    }

    /// A name is only usable without "@" and without slash (no address, no path).
    static func usableName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bad = trimmed.isEmpty || trimmed.contains("@") || trimmed.contains("/") || trimmed.contains("\\")
        return bad ? nil : trimmed
    }
}

/// The first line: sender · what they want · by when.
public struct FirstLine: Sendable, Equatable {
    public var text: String
    /// The deadline's date was computed (certainty `.unsure`): show "please check" (German UI: "bitte prüfen").
    public var pleaseCheck: Bool
    public var usedSystemModel: Bool
    public init(text: String, pleaseCheck: Bool, usedSystemModel: Bool) {
        self.text = text; self.pleaseCheck = pleaseCheck; self.usedSystemModel = usedSystemModel
    }
}

public enum FirstLineBuilder {
    /// Line during the call: "Looking at the mail from Finanzamt München".
    public static func calling(sender: String?) -> String {
        if let name = sender.flatMap(LetterReading.usableName) {
            return L("Looking at the mail from %@", table: "Letter", name)
        }
        return L("Looking at the mail …", table: "Letter")
    }

    /// First line from code only. Never a path, a file extension, a cell reference or words like "Modell" (model).
    public static func line(_ facts: LetterFacts, locale: Locale = .current) -> FirstLine {
        let sender = facts.sender.flatMap(LetterReading.usableName)
        let amountText = facts.amount.map { money($0, locale: locale) }
        let pleaseCheck = facts.deadline?.certainty == .unsure
        let text: String
        if let deadline = facts.deadline {
            let dayText = deadline.date.map { day($0, locale: locale) }
            let payAmount = deadline.kind == .payment ? amountText : nil
            let core = phrase(deadline.kind, day: dayText, amount: payAmount)
            text = sender.map { $0 + ": " + core } ?? core
        } else if let amountText {
            let core = L("%@ mentioned", table: "Letter", amountText)
            text = sender.map { $0 + ": " + core } ?? core
        } else {
            text = neutral(sender: sender, subject: facts.subject.flatMap(cleanSubject))
        }
        return FirstLine(text: text, pleaseCheck: pleaseCheck, usedSystemModel: false)
    }

    /// The deadline as its own sentence, e.g. for "Online prüfen" (check online): "Objection possible until 06.11."
    public static func statement(for deadline: Deadline, locale: Locale = .current) -> String {
        phrase(deadline.kind, day: deadline.date.map { day($0, locale: locale) }, amount: nil)
    }

    /// Short gist from the system's language model (macOS 26+), only if the code found neither deadline nor amount.
    /// Waits at most `timeout`, never throws; `nil` if nothing usable came.
    public static func refined(_ facts: LetterFacts, text: String, model: (any QuickLanguageModel)?,
                               timeout: Duration = .milliseconds(2500), locale: Locale = .current) async -> FirstLine? {
        guard facts.deadline == nil, facts.amount == nil, let model, model.availability == .available else { return nil }
        let prompt = String(text.prefix(1500))
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let language = PippaSkill.prefersGerman ? "German" : "English"
        let instructions = "Say in at most eight plain words what the sender wants from the reader. "
            + "No names, numbers, dates or addresses. Answer in \(language)."
        let raw = await firstAnswer(model: model, instructions: instructions, prompt: prompt, timeout: timeout)
        guard let raw, let gist = acceptedGist(raw) else { return nil }
        let sender = facts.sender.flatMap(LetterReading.usableName)
        let lineText = sender.map { $0 + ": " + gist } ?? gist
        return FirstLine(text: lineText, pleaseCheck: false, usedSystemModel: true)
    }

    // MARK: Helpers

    /// The model's answer or `nil`, whichever comes first: answer or timeout.
    static func firstAnswer(model: any QuickLanguageModel, instructions: String, prompt: String, timeout: Duration) async -> String? {
        await withTaskGroup(of: String?.self, returning: String?.self) { group in
            group.addTask {
                var out = ""
                do {
                    for try await piece in model.stream(instructions: instructions, prompt: prompt, maximumTokens: 40) {
                        out += piece
                        if out.count > 400 { break }
                    }
                } catch {
                    return nil
                }
                if Task.isCancelled { return nil }
                return out
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next()
            group.cancelAll()
            return first ?? nil
        }
    }

    /// Only one line, at most 80 characters, no digit, no "@", no link, no path.
    static func acceptedGist(_ raw: String) -> String? {
        let quotes = CharacterSet(charactersIn: "\"'“”„«»").union(.whitespacesAndNewlines)
        var gist = raw.trimmingCharacters(in: quotes)
        while gist.hasSuffix(".") { gist.removeLast() }
        gist = gist.trimmingCharacters(in: .whitespaces)
        guard !gist.isEmpty, gist.count <= 80 else { return nil }
        let multiline = gist.contains("\n") || gist.contains("\r")
        let digit = gist.contains { $0.isNumber }
        let lower = gist.lowercased()
        let bad = multiline || digit || gist.contains("@") || lower.contains("http") || gist.contains("/") || gist.contains("\\")
        return bad ? nil : gist
    }

    static func phrase(_ kind: Deadline.Kind, day: String?, amount: String?) -> String {
        switch kind {
        case .payment:
            if let amount, let day { return L("%@ to pay by %@", table: "Letter", amount, day) }
            if let amount { return L("%@ to pay", table: "Letter", amount) }
            if let day { return L("Payment due by %@", table: "Letter", day) }
            return L("Payment due", table: "Letter")
        case .objection:
            if let day { return L("Objection possible until %@", table: "Letter", day) }
            return L("Objection possible", table: "Letter")
        case .cancellation:
            if let day { return L("Cancel by %@", table: "Letter", day) }
            return L("Cancellation possible", table: "Letter")
        case .appointment:
            if let day { return L("Appointment on %@", table: "Letter", day) }
            return L("Appointment", table: "Letter")
        case .generic, .contractEnd, .debit:
            if let day { return L("Deadline: %@", table: "Letter", day) }
            return L("There’s a deadline", table: "Letter")
        }
    }

    static func neutral(sender: String?, subject: String?) -> String {
        switch (sender, subject) {
        case let (sender?, subject?): return L("%@ wrote about “%@”", table: "Letter", sender, subject)
        case let (sender?, nil): return L("%@ wrote to you", table: "Letter", sender)
        case let (nil, subject?): return L("About “%@”", table: "Letter", subject)
        case (nil, nil): return L("I found no date and no amount in it.", table: "Letter")
        }
    }

    /// Subject for the line: without slashes and file extensions, at most 60 characters.
    static func cleanSubject(_ raw: String) -> String? {
        var s = raw.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
        s = s.replacingOccurrences(of: #"(?i)\.(pdf|docx?|xlsx?|csv|txt|eml|jpe?g|png|heic|zip)\b"#, with: "", options: .regularExpression)
        s = s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        if s.count > 60 { s = String(s.prefix(59)).trimmingCharacters(in: .whitespaces) + "…" }
        return s.isEmpty ? nil : s
    }

    /// Day and month in the UI language: "31.10."; where the format would have slashes ("10/31"), "Oct 31".
    static func day(_ date: DayDate, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        var c = DateComponents()
        c.year = date.year; c.month = date.month; c.day = date.day; c.hour = 12
        guard let value = calendar.date(from: c) else { return String(format: "%02d.%02d.", date.day, date.month) }
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("ddMM")
        let numeric = f.string(from: value)
        if !numeric.contains("/") { return numeric }
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f.string(from: value).replacingOccurrences(of: "/", with: " ")
    }

    /// Amount as euros in the UI language ("312,48 €", "€312.48").
    static func money(_ amount: Decimal, locale: Locale) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .currency
        f.currencyCode = "EUR"
        f.maximumFractionDigits = 2
        return f.string(from: NSDecimalNumber(decimal: amount)) ?? GermanText.formatAmount(amount)
    }
}
