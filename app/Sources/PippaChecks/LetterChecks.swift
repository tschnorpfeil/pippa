import Foundation
import PippaCore

/// Stub for the system language model: answers with `answer` or (if nil) never.
private struct LetterGistModel: QuickLanguageModel, Sendable {
    let answer: String?
    var availability: QuickModelAvailability { .available }
    func stream(instructions: String, prompt: String, maximumTokens: Int) -> AsyncThrowingStream<String, Error> {
        let answer = answer
        return AsyncThrowingStream { continuation in
            guard let answer else { return }
            continuation.yield(answer)
            continuation.finish()
        }
    }
}

/// Letters: first line built in code, actions, validating model proposals, inserting into Mail.
func runLetterChecks() async {
    let today = DayDate(year: 2026, month: 10, day: 2)!
    let german = Locale(identifier: "de_DE")
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    func skillFixture(_ name: String) -> PippaSkill? {
        PippaSkill.parse("---\nname: \(name)\ndescription: Prüfung \(name)\npippa-label: \(name)\n---\nAnleitung.\n", folder: name, german: false)
    }
    let skills: [PippaSkill] = ["antwort-schreiben", "brief-verstehen", "zusammenfassen"].compactMap { skillFixture($0) }

    // MARK: Facts and first line

    check("Letter: sample mail yields sender, amount and payment deadline; first line without path or jargon") {
        guard let mail = DemoIntegrations().sampleMail else { return false }
        let facts = LetterReading.facts(mail: mail, today: today)
        let line = FirstLineBuilder.line(facts, locale: german)
        let due = DayDate(year: 2026, month: 10, day: 31)
        let senderOK = facts.sender == "Hausverwaltung Berger" && facts.senderAddress == "info@berger-hv.de"
        let amountOK = facts.amount == Decimal(string: "312.48", locale: Locale(identifier: "en_US_POSIX"))
        let deadlineOK = facts.deadline?.kind == .payment && facts.deadline?.date == due
        let lower = line.text.lowercased()
        let lineOK = line.text.contains("Hausverwaltung Berger") && line.text.contains("31.10.") && !line.text.contains("/")
        let wordsOK = !lower.contains("model") && !lower.contains("token") && !lower.contains(".pdf")
        let kindOK = facts.taskKind == .mail && facts.subject == "Nebenkostenabrechnung 2025"
            && facts.attachmentNames == ["Nebenkosten 2025.pdf"]
        return senderOK && amountOK && deadlineOK && lineOK && wordsOK && kindOK && !line.pleaseCheck && !line.usedSystemModel
    }
    check("Letter: tax notice with objection within one month yields a computed deadline marked \"please check\"") {
        let text = """
        Finanzamt München
        Datum: 15.09.2026
        Bescheid für 2025 über Einkommensteuer

        Rechtsbehelfsbelehrung
        Gegen diesen Bescheid ist der Einspruch gegeben. Der Einspruch ist innerhalb eines Monats nach Bekanntgabe dieses Bescheids beim Finanzamt einzulegen.
        """
        let doc = DocumentText(url: URL(fileURLWithPath: "/Users/test/Downloads/Bescheid.pdf"), pages: [text], isPaged: true,
                               usedOCR: false, headers: [:])
        let facts = LetterReading.facts(document: doc, today: today)
        let line = FirstLineBuilder.line(facts, locale: german)
        let due = DayDate(year: 2026, month: 10, day: 15)
        let kindOK = facts.deadline?.kind == .objection && facts.deadline?.date == due && facts.taskKind == .letter
        let lineOK = line.pleaseCheck && line.text.contains("15.10.") && line.text.hasPrefix("Finanzamt München: ")
        let statement = facts.deadline.map { FirstLineBuilder.statement(for: $0, locale: german) } ?? ""
        let statementOK = statement.contains("15.10.") && !statement.contains("Finanzamt")
        return kindOK && lineOK && statementOK && facts.amount == nil && facts.deadlines.count <= 5
    }
    check("Letter: without deadline and amount a calm line with subject; subject without slash and file extension") {
        let mail = MailMessage(subject: "Einladung zum Sommerfest", sender: "Verein Gartenfreunde <info@gartenfreunde.de>", date: nil,
                               body: "Liebe Mitglieder,\n\nwir laden euch herzlich zu unserem Sommerfest ein.\n\nViele Grüße", attachmentNames: [])
        let facts = LetterReading.facts(mail: mail, today: today)
        let line = FirstLineBuilder.line(facts, locale: german)
        let neutralOK = facts.deadline == nil && facts.amount == nil && line.text.contains("Verein Gartenfreunde")
            && line.text.contains("Einladung zum Sommerfest") && !line.pleaseCheck
        let odd = FirstLineBuilder.line(LetterFacts(subject: "Rechnung 2026/10.pdf"), locale: german)
        let oddOK = !odd.text.contains("/") && !odd.text.lowercased().contains(".pdf") && odd.text.contains("Rechnung")
        let bare = FirstLineBuilder.line(LetterFacts(), locale: german)
        return neutralOK && oddOK && !bare.text.isEmpty
    }
    check("Letter: line when called with and without sender, never with an address") {
        let named = FirstLineBuilder.calling(sender: "Finanzamt München")
        let plain = FirstLineBuilder.calling(sender: nil)
        let address = FirstLineBuilder.calling(sender: "info@berger-hv.de")
        return named.contains("Finanzamt München") && !plain.isEmpty && !address.contains("@")
    }
    check("Letter: mail as document carries sender, subject and attachments; mail ID stays optional") {
        let mail = MailMessage(subject: "Test", sender: "A <a@b.de>", date: nil, body: "Hallo", attachmentNames: ["x.pdf"], messageID: "id-1@b.de")
        let doc = LetterReading.document(for: mail, url: URL(fileURLWithPath: "/tmp/Test.eml"))
        let old = MailMessage(subject: "Test", sender: "A", date: nil, body: "Hallo", attachmentNames: [])
        return doc.headers["from"] == "A <a@b.de>" && doc.headers["subject"] == "Test" && doc.attachments == ["x.pdf"]
            && doc.pages == ["Hallo"] && mail.messageID == "id-1@b.de" && old.messageID == nil
    }

    // MARK: System language model (supplement only)

    let quiet = LetterFacts(sender: "Verein Gartenfreunde", subject: "Sommerfest")
    await checkAsync("Letter: short gist from the system model is adopted") {
        let line = await FirstLineBuilder.refined(quiet, text: "Bitte meldet euch bis Freitag.", model: LetterGistModel(answer: "möchte eine Rückmeldung."))
        return line?.usedSystemModel == true && line?.text == "Verein Gartenfreunde: möchte eine Rückmeldung" && line?.pleaseCheck == false
    }
    await checkAsync("Letter: gist with digits, address or multiple lines is discarded") {
        let digits = await FirstLineBuilder.refined(quiet, text: "Text", model: LetterGistModel(answer: "Zahlen Sie 312 €"))
        let mail = await FirstLineBuilder.refined(quiet, text: "Text", model: LetterGistModel(answer: "schreib an a@b.de"))
        let lines = await FirstLineBuilder.refined(quiet, text: "Text", model: LetterGistModel(answer: "möchte\netwas"))
        return digits == nil && mail == nil && lines == nil
    }
    await checkAsync("Letter: a system model that does not answer does not hold up the line") {
        let start = ContinuousClock.now
        let line = await FirstLineBuilder.refined(quiet, text: "Text", model: LetterGistModel(answer: nil), timeout: .milliseconds(200))
        let elapsed = ContinuousClock.now - start
        return line == nil && elapsed < .seconds(2)
    }
    await checkAsync("Letter: with deadline or amount, or without a model, Pippa does not ask the system model") {
        var withAmount = quiet
        withAmount.amount = Decimal(12)
        let a = await FirstLineBuilder.refined(withAmount, text: "Text", model: LetterGistModel(answer: "möchte Geld"))
        let b = await FirstLineBuilder.refined(quiet, text: "Text", model: nil)
        return a == nil && b == nil
    }

    // MARK: Actions

    check("Letter: catalog in fixed order; without the skill the action drops out") {
        let all = LetterActions.catalog(skills: skills).map(\.id)
        let none = LetterActions.catalog(skills: []).map(\.id)
        let drafts = LetterActions.catalog(skills: skills).filter(\.writesDraft).map(\.id)
        let expectedDrafts: [String] = ["reply", "object", "cancel"]
        return all == LetterActions.ids && none == ["add-date"] && drafts == expectedDrafts
    }
    check("Letter: type actions Explain · Reply · Date, habit moves Reply to the front") {
        let plain = LetterActions.fallback(kind: .mail, source: nil, records: [], now: now, skills: skills).map(\.id)
        let records = (0..<3).map { i in
            TaskRecord(at: now.addingTimeInterval(-Double(i) * 3600), kind: .mail, offered: ["explain", "reply", "add-date"],
                       chosen: "reply", outcome: .kept)
        }
        let habit = LetterActions.fallback(kind: .mail, source: nil, records: records, now: now, skills: skills).map(\.id)
        let bare = LetterActions.fallback(kind: .mail, source: nil, records: [], now: now, skills: []).map(\.id)
        let expected: [String] = ["explain", "reply", "add-date"]
        return plain == expected && habit.first == "reply" && habit.count == 3 && bare == ["add-date"]
    }
    // MARK: Inserting into Mail

    check("Mail: readback confirms the complete draft, never just the beginning") {
        let body = "Sehr geehrte Damen und Herren, hiermit lege ich Einspruch gegen Ihren Bescheid ein. Bitte bestätigen Sie den Eingang."
        let draft = MailDraft(messageID: "original", to: "sender@example.org", toName: nil, subject: "Bescheid", body: body)
        let truncated = String(body.prefix(40))
        let wrapped = "Meine Signatur\n" + body.replacingOccurrences(of: " ", with: "\n") + "\n> Originaltext"
        let empty = MailDraft(messageID: nil, to: nil, toName: nil, subject: "", body: " \n ")
        return !draft.isConfirmed(byReadback: truncated) && draft.isConfirmed(byReadback: wrapped)
            && !empty.isConfirmed(byReadback: "")
    }
    check("Mail: original search ignores the selection and has no compose fallback") {
        guard let source = IntegrationScripts.sources.first(where: { $0.name == "MailReply" })?.source else { return false }
        return source.contains("on replyAt") && source.contains("on findIn") && source.contains("on mailboxList")
            && !source.contains("set sel to selection") && !source.contains("selection")
    }
    check("Mail: candidates are checked against the case-sensitive original ID before being accepted") {
        guard let source = IntegrationScripts.sources.first(where: { $0.name == "MailReply" })?.source,
              let find = source.range(of: "on findIn"),
              let filter = source.range(of: "considering case\n", range: find.upperBound..<source.endIndex),
              let equality = source.range(of: "if candidateID is theID or candidateID is", range: filter.upperBound..<source.endIndex),
              let endFilter = source.range(of: "end considering", range: equality.upperBound..<source.endIndex),
              let append = source.range(of: "if exactIdentity then set end of ids", range: endFilter.upperBound..<source.endIndex),
              let reply = source.range(of: "on replyAt"),
              let replyGuard = source.range(of: "if not exactIdentity then return {\"notHere\"}", range: reply.upperBound..<source.endIndex),
              let open = source.range(of: "return my openReply(m", range: reply.upperBound..<source.endIndex) else { return false }
        return append.lowerBound > find.upperBound && replyGuard.lowerBound < open.lowerBound
    }
    check("Mail: reply is filled, read back and saved; Pippa never closes open windows; every Mail step has a timeout") {
        guard let source = IntegrationScripts.sources.first(where: { $0.name == "MailReply" })?.source,
              let open = source.range(of: "on openReply"),
              let create = source.range(of: "set r to reply m\n", range: open.upperBound..<source.endIndex),
              let fill = source.range(of: "tell r to make new paragraph at end of content with data (theBody", range: create.upperBound..<source.endIndex),
              let read = source.range(of: "set readBody to (content of r) as text", range: fill.upperBound..<source.endIndex),
              let save = source.range(of: "save r\n", range: read.upperBound..<source.endIndex),
              let report = source.range(of: "return {\"reply\", readSubject, readBody, addresses, saved}", range: save.upperBound..<source.endIndex)
        else { return false }
        // `set content` has no effect on replies in Mail 16 ; `save` makes the window show the text.
        let noDeadEnds = !source.contains("set content of r") && !source.contains("with opening window")
        let neverCloses = !source.contains("close r") && !source.contains("close candidate") && !source.contains("delete r")
        let timeouts = source.components(separatedBy: "with timeout of").count - 1 >= 7 && source.contains("errNum is -1712")
        return report.lowerBound > save.lowerBound && noDeadEnds && neverCloses && timeouts
    }
    check("Mail: only text read back counts as inserted; otherwise paste via ⌘V, never a false confirmation") {
        let draft = MailDraft(messageID: "a@b", to: "amt@example.org", toName: nil, subject: "Bescheid", body: "Hiermit lege ich Einspruch ein.")
        func outcome(_ status: String, subject: String = "Re: Bescheid", body: String = "", to: [String] = ["amt@example.org"], saved: Bool = true) -> String {
            do { return try draft.replyOutcome(status: status, subject: subject, body: body, recipients: to, saved: saved).rawValue }
            catch let failure as MailReplyFailure { return "\(failure)" } catch { return "other" }
        }
        let quoted = "Hiermit lege ich\nEinspruch ein.\n\nAm 05.10.26 09:15 schrieb Amt:\n> Bescheid"
        return outcome("reply", body: quoted) == "reply"
            && outcome("reply", body: "") == "replyNeedsPaste"
            && outcome("reply", body: "Hiermit lege") == "replyNeedsPaste"
            && outcome("reply", body: quoted, to: ["other@example.org"]) == "unconfirmed"
            && outcome("reply", subject: "Re: Anderes", body: quoted) == "unconfirmed"
            && outcome("reply", body: quoted, saved: false) == "replyNeedsPaste"
            && outcome("failed") == "notCreated" && outcome("busy") == "notCreated"
            && outcome("uncertain") == "unconfirmed" && outcome("shown") == "unconfirmed" && outcome("timeout") == "unconfirmed"
            && outcome("") == "unconfirmed" && outcome("missing") == "missingOriginal"
    }
    check("Mail: search starts in the mailbox of the call, each mailbox once; ambiguity and incompleteness open nothing") {
        guard let captured = MailLocator(account: "Work", path: ["Inbox", "Steuer"], mailID: 42),
              let inbox = MailLocator(account: "Work", path: ["Inbox"], mailID: nil),
              let local = MailLocator(account: "", path: ["Importiert", "Pippa QA"], mailID: nil),
              let other = MailLocator(account: "Home", path: ["Inbox"], mailID: nil),
              let box = MailLocator(account: "Work", path: ["Inbox", "Steuer"], mailID: nil),
              let a = MailLocator(account: "Home", path: ["Inbox"], mailID: 7),
              let aAgain = MailLocator(account: "Home", path: ["Archiv"], mailID: 7),
              let b = MailLocator(account: "Work", path: ["Inbox"], mailID: 8) else { return false }
        let order = MailOriginalSearch.ordered([other, inbox, local, box, other, local], preferring: captured)
        let noHint = MailOriginalSearch.ordered([other, inbox, local], preferring: nil)
        func decided(_ matches: [MailLocator], incomplete: Bool = false) -> String {
            do { return "\(try MailOriginalSearch.decide(matches, incomplete: incomplete).mailID ?? 0)" }
            catch let failure as MailReplyFailure { return "\(failure)" } catch { return "other" }
        }
        let invalid = MailLocator(account: "", path: [], mailID: 1) == nil && MailLocator(account: "", path: [""], mailID: nil) == nil
            && MailLocator(account: "", path: ["x"], mailID: 0) == nil && MailLocator(account: "", path: ["x"], mailID: Int(Int32.max) + 1) == nil
        return order == [box, inbox, local, other] && noHint == [local, other, inbox]
            && decided([a]) == "7" && decided([a, aAgain]) == "7" && decided([a, b]) == "ambiguousOriginal"
            && decided([]) == "missingOriginal" && decided([], incomplete: true) == "searchIncomplete"
            && decided([a], incomplete: true) == "7" && invalid
            && MailOriginalSearch.budget <= .seconds(120)
    }
    check("Mail: call captures mailbox and mail ID as a hint, not as identity") {
        guard let source = IntegrationScripts.sources.first(where: { $0.name == "Mail" })?.source else { return false }
        let mail = MailMessage(subject: "x", sender: "a@b.de", date: nil, body: "y", attachmentNames: [], messageID: "a@b",
                               locator: MailLocator(account: "", path: ["Inbox"], mailID: 3))
        let draft = MailDraft(messageID: mail.messageID, to: nil, toName: nil, subject: "x", body: "y", locator: mail.locator)
        return source.contains("set theLocation to {acctName, boxPath, (id of m)}") && draft.locator?.mailID == 3
            && mail.replySource?.messageID == "a@b"
    }
    check("Mail: RFC ID, Reply-To and folded headers stay with the source") {
        let headers = "Received: first\r\nReceived: second\r\nMessage-ID: <original@example.org>\r\nFrom: Sender <from@example.org>\r\nReply-To: Reply <reply@example.org>\r\nSubject: First\r\n second\r\n\r\nBody"
        let source = MailReplySource.capture(headers: Data(headers.utf8))
        let emlx = "\(headers.utf8.count)\n" + headers + "\n<?xml malicious-tail>"
        return source?.messageID == "original@example.org" && source?.replyTo == "Reply <reply@example.org>"
            && source?.subject == "First second" && MailReplySource.capture(headers: Data(emlx.utf8), emlx: true) == source
            && MailReplySource.capture(headers: Data("Message-ID: <a@b>\nMessage-ID: <c@d>\n\n".utf8)) == nil
    }
    check("Mail: empty native Reply-To uses From and stays readable in the EML") {
        let mail = MailMessage(subject: "Betreff", sender: "From <from@example.org>", date: nil,
                               body: "Text", attachmentNames: [], messageID: "a@b", replyTo: "")
        return mail.replySource?.replyTo == mail.sender
            && MailReplySource.capture(headers: Data(mail.emlText.utf8)) == mail.replySource
    }
    check("Mail: broken IDs and header injection are not a reply target") {
        let bad = ["", "original", "<a@b> trailing", "a@b\nSubject: injected", "a@b\r", "a@b c", "<a@b><c@d>"]
        return bad.allSatisfy { MailReplySource.canonicalMessageID($0) == nil }
            && MailReplySource(messageID: "a@b", replyTo: "x@y.de\nBcc: z@y.de", subject: "x") == nil
            && MailReplySource.capture(headers: Data(repeating: 65, count: 65_537)) == nil
            && MailReplySource.capture(headers: Data("Message-ID: <a@b>\nSubject: =?UTF-8?Q?Gr=C3=BC=C3=9Fe?=\n\n".utf8))?.subject == "Grüße"
            && MailReplySource.capture(headers: Data("Message-ID: <a@b>\nSubject: Hello\n\n".utf8) + Data([255]))?.messageID == "a@b"
    }
    check("Mail: old cards stay readable without an invented source; source is immutable") {
        let legacy = Data(#"{"to":"","subject":"","body":"Hallo","state":"draft"}"#.utf8)
        guard let old = try? JSONDecoder().decode(ConversationMailDraft.self, from: legacy),
              let source = MailReplySource(messageID: "a@b", replyTo: "x@y.de", subject: "Original") else { return false }
        let card = ConversationMailDraft(body: "Hallo", replySource: source)
        var edited = card; edited.body = "Hallo neu"
        return old.replySource == nil && !old.requiresOriginalReply && card.requiresOriginalReply && card.canUpdate(to: edited)
            && !card.canUpdate(to: old)
            && (try? JSONDecoder().decode(ConversationMailDraft.self, from: JSONEncoder().encode(card))) == card
    }

    check("Mail: new drafts keep the subject and confirm all fields before success") {
        let draft = MailDraft(messageID: nil, to: "anna@example.invalid", toName: nil,
                              subject: "Termin", body: "Hallo Anna,\npasst Donnerstag?", isReply: false)
        var blank = draft; blank.to = nil; blank.subject = ""
        return draft.replySubject == "Termin" && blank.replySubject.isEmpty
            && draft.isConfirmed(subject: "Termin", body: draft.body, recipients: ["anna@example.invalid"])
            && !draft.isConfirmed(subject: "Re: Termin", body: draft.body, recipients: ["anna@example.invalid"])
            && !draft.isConfirmed(subject: "Termin", body: "Hallo Anna", recipients: ["anna@example.invalid"])
            && !draft.isConfirmed(subject: "Termin", body: draft.body, recipients: ["other@example.invalid"])
            && !draft.isConfirmed(subject: "Termin", body: draft.body, recipients: [])
            && blank.isConfirmed(subject: "", body: blank.body, recipients: [])
    }

    check("Mail: reply subject and addresses") {
        let base = MailDraft(messageID: nil, to: nil, toName: nil, subject: "x", body: "")
        var aw = base; aw.subject = "AW: x"
        var re = base; re.subject = "  re: Hallo "
        var fwd = base; fwd.subject = "Fwd: y"
        var empty = base; empty.subject = " "
        let subjectsOK = base.replySubject == "Re: x" && aw.replySubject == "AW: x" && re.replySubject == "re: Hallo"
            && fwd.replySubject == "Fwd: y" && empty.replySubject == "Re:"
        let fa = MailAddress.parse("Finanzamt München <poststelle@fa.bayern.de>")
        let quoted = MailAddress.parse("\"Berger, Anna\" <anna@example.de>")
        let bare = MailAddress.parse("info@berger-hv.de")
        let nameOnly = MailAddress.parse("Hausverwaltung Berger")
        let broken = MailAddress.parse("kaputt@")
        let badInner = MailAddress.parse("Name <kaputt>")
        let faOK = fa.name == "Finanzamt München" && fa.address == "poststelle@fa.bayern.de"
        let quotedOK = quoted.name == "Berger, Anna" && quoted.address == "anna@example.de"
        let bareOK = bare.name == nil && bare.address == "info@berger-hv.de"
        let nameOK = nameOnly.name == "Hausverwaltung Berger" && nameOnly.address == nil
        let brokenOK = broken.name == nil && broken.address == nil && badInner.name == "Name" && badInner.address == nil
        return subjectsOK && faOK && quotedOK && bareOK && nameOK && brokenOK
    }
    await checkAsync("Mail: inserting needs permission and remembers the draft (nothing is sent)") {
        let draft = MailDraft(messageID: "id-1@b.de", to: "info@berger-hv.de", toName: "Hausverwaltung Berger",
                              subject: "Nebenkostenabrechnung 2025", body: "Guten Tag,\n\nich prüfe die Abrechnung.")
        let locked = DemoIntegrations()
        var refused = false
        do { _ = try await locked.insertReply(draft) } catch let error as PippaError {
            refused = error == .accessDenied(L("Mail", table: "Core"))
        }
        let open = DemoIntegrations(granted: true)
        let result = try await open.insertReply(draft)
        return refused && locked.insertedDrafts.isEmpty && result == .reply && open.insertedDrafts == [draft]
    }
    await checkAsync("Mail: missing original ID produces no compose fallback even in the demo") {
        let integration = DemoIntegrations(granted: true)
        let draft = MailDraft(messageID: nil, to: "x@y.de", toName: nil, subject: "x", body: "Hallo")
        do { _ = try await integration.insertReply(draft); return false }
        catch let failure as MailReplyFailure { return failure == .missingOriginal && integration.insertedDrafts.isEmpty }
    }
    await checkAsync("Mail: integrations without their own insert say \"not possible\"") {
        let draft = MailDraft(messageID: nil, to: nil, toName: nil, subject: "x", body: "y")
        do { _ = try await ChangedIntegrations().insertReply(draft); return false } catch let error as PippaError {
            return error == .notAvailable
        }
    }
    check("Mail: no script calls \"send\"; reply opens a window, new mail is visible") {
        // Any bare `send` token, not only `send r`: the script may never name the command at all.
        let pattern = #"\bsend\b"#
        let sources = IntegrationScripts.sources
        let clean = sources.allSatisfy { $0.source.range(of: pattern, options: [.regularExpression, .caseInsensitive]) == nil }
        let reply = sources.first { $0.name == "MailReply" }?.source ?? ""
        let shape = reply.contains("set r to reply m\n") && reply.contains("visible:true") && !reply.contains("reply to all")
        let names = sources.map(\.name)
        let expected: [String] = ["Mail", "MailReply", "MailSearch", "Excel"]
        return clean && shape && names == expected
    }
    await checkAsync("Mail: reply script is among the compiled scripts") {
        let result = await MainActor.run { IntegrationScripts.compileAll() }
        return result["MailReply"] != nil && result["Mail"] != nil
    }
}
