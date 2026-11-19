import AppKit
import Foundation
import PippaCore

/// Integrations with only the required members: everything else falls back to the protocol's defaults.
private final class MinimalIntegrations: AppIntegrations, @unchecked Sendable {
    let base = DemoIntegrations(granted: true)
    func access(_ i: Integration) async -> IntegrationAccess { await base.access(i) }
    func requestAccess(_ i: Integration) async -> IntegrationAccess { await base.requestAccess(i) }
    func remove(_ item: CreatedItem) async throws -> RemoveResult { .changed }
    func selectedMail() async throws -> MailMessage? { nil }
}

/// Mail drafts: identity of the original, readback, inserting into Mail. No native app actions.
func runLetterChecks() async {
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
    check("Mail: reply fields are read after saving; Pippa never closes an unconfirmed window") {
        guard let source = IntegrationScripts.sources.first(where: { $0.name == "MailReply" })?.source,
              let open = source.range(of: "on openReply"),
              let create = source.range(of: "set r to reply m\n", range: open.upperBound..<source.endIndex),
              let fill = source.range(of: "tell r to make new paragraph at end of content with data (theBody", range: create.upperBound..<source.endIndex),
              let save = source.range(of: "save r\n", range: fill.upperBound..<source.endIndex),
              let read = source.range(of: "set readBody to (content of r) as text", range: save.upperBound..<source.endIndex),
              let envelope = source.range(of: "set readSubject to (subject of r) as text", range: read.upperBound..<source.endIndex),
              let recipients = source.range(of: "repeat with targetRecipient in to recipients of r", range: envelope.upperBound..<source.endIndex),
              let unconfirmed = source.range(of: "return {\"shown\"}", range: recipients.upperBound..<source.endIndex),
              let report = source.range(of: "return {\"reply\", readSubject, readBody, addresses, saved}", range: unconfirmed.upperBound..<source.endIndex)
        else { return false }
        // `set content` has no effect on replies in Mail 16 ; `save` makes the window show the text.
        let noDeadEnds = !source.contains("set content of r") && !source.contains("with opening window")
        let neverCloses = !source.contains("close r") && !source.contains("close candidate") && !source.contains("delete r")
        let timeouts = source.components(separatedBy: "with timeout of").count - 1 >= 7 && source.contains("errNum is -1712")
        let noStaleReadback = !source[fill.upperBound..<save.lowerBound].contains("set readBody")
        return report.lowerBound > read.lowerBound && noStaleReadback && noDeadEnds && neverCloses && timeouts
    }
    check("Mail: new compose creation and field verification have an explicit timeout; no save, send or retry") {
        guard let source = IntegrationScripts.sources.first(where: { $0.name == "MailReply" })?.source,
              let start = source.range(of: "on newMessage("),
              let end = source.range(of: "end newMessage", range: start.upperBound..<source.endIndex) else { return false }
        let handler = String(source[start.upperBound..<end.lowerBound])
        guard let timeout = handler.range(of: "with timeout of 30 seconds"),
              let create = handler.range(of: "set nm to make new outgoing message", range: timeout.upperBound..<handler.endIndex),
              let recipients = handler.range(of: "repeat with targetRecipient in to recipients of nm", range: create.upperBound..<handler.endIndex),
              let read = handler.range(of: "return {(subject of nm) as text, (content of nm) as text, recipientAddresses}", range: recipients.upperBound..<handler.endIndex),
              let endTimeout = handler.range(of: "end timeout", range: read.upperBound..<handler.endIndex) else { return false }
        return endTimeout.lowerBound > read.lowerBound
            && handler.components(separatedBy: "make new outgoing message").count == 2
            && !handler.contains("save nm") && !handler.contains("send nm") && !handler.contains("delete nm")
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
            && outcome("failed") == "unconfirmed" && outcome("busy") == "notCreated"
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
            && decided([a], incomplete: true) == "searchIncomplete"
            && decided([a, aAgain], incomplete: true) == "searchIncomplete"
            && decided([a, b], incomplete: true) == "ambiguousOriginal" && invalid
            && MailOriginalSearch.budget <= .seconds(120)
    }
    check("Mail: malformed mailbox responses never become a smaller complete search") {
        func list(_ values: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
            let result = NSAppleEventDescriptor.list()
            for (index, value) in values.enumerated() { result.insert(value, at: index + 1) }
            return result
        }
        func text(_ value: String) -> NSAppleEventDescriptor { NSAppleEventDescriptor(string: value) }
        func response(_ payload: NSAppleEventDescriptor) -> NSAppleEventDescriptor { list([text("ok"), payload]) }
        let valid = list([text("Work"), list([text("Inbox"), text("Pippa QA")]), text("")])
        let malformed: [NSAppleEventDescriptor] = [
            text("not a response list"), response(text("not a mailbox list")),
            response(list([valid, text("not a mailbox")])),
            response(list([list([text("Work"), text("Inbox"), text("")])])),
            response(list([list([text("Work"), list([text("Inbox"), NSAppleEventDescriptor(int32: 7)]), text("")])])),
            response(list([list([text("Work"), list([text("")]), text("")])])),
            response(list([list([text("Work"), list([text("Inbox")]), NSAppleEventDescriptor(int32: 7)])]))
        ]
        let decoded = try IntegrationScripts.mailSearchMailboxes(response(list([valid])))
        let empty = try IntegrationScripts.mailSearchMailboxes(response(list([])))
        return decoded == [MailLocator(account: "Work", path: ["Inbox", "Pippa QA"], mailID: nil)!] && empty.isEmpty
            && malformed.allSatisfy { value in
                do { _ = try IntegrationScripts.mailSearchMailboxes(value); return false }
                catch MailReplyFailure.searchIncomplete { return true }
                catch { return false }
            }
    }
    check("Mail: malformed match responses never become no match or one apparently unique match") {
        func list(_ values: [NSAppleEventDescriptor]) -> NSAppleEventDescriptor {
            let result = NSAppleEventDescriptor.list()
            for (index, value) in values.enumerated() { result.insert(value, at: index + 1) }
            return result
        }
        func text(_ value: String) -> NSAppleEventDescriptor { NSAppleEventDescriptor(string: value) }
        func number(_ value: Int32) -> NSAppleEventDescriptor { NSAppleEventDescriptor(int32: value) }
        func response(_ payload: NSAppleEventDescriptor) -> NSAppleEventDescriptor { list([text("ok"), payload]) }
        guard let box = MailLocator(account: "Work", path: ["Inbox"], mailID: nil) else { return false }
        let malformed: [NSAppleEventDescriptor] = [
            response(text("not an ID list")), response(number(7)),
            response(list([number(7), text("8")])), response(list([number(7), number(0)])),
            response(list([number(-1)])), response(list([NSAppleEventDescriptor(boolean: true)])),
            response(list([list([number(7)])])), list([text("skip")]), list([text("timeout")])
        ]
        let decoded = try IntegrationScripts.mailSearchMatches(response(list([number(7), number(8)])), in: box)
        let empty = try IntegrationScripts.mailSearchMatches(response(list([])), in: box)
        return decoded.map(\.mailID) == [7, 8] && empty.isEmpty
            && malformed.allSatisfy { value in
                do { _ = try IntegrationScripts.mailSearchMatches(value, in: box); return false }
                catch MailReplyFailure.searchIncomplete { return true }
                catch { return false }
            }
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
        do { _ = try await MinimalIntegrations().insertReply(draft); return false } catch let error as PippaError {
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
        let expected: [String] = ["Mail", "MailReply", "MailSearch", "MailAccounts", "MailMove", "Excel", "PhotosSearch", "PhotosShow", "Safari", "Chrome", "FrontDocument"]
        return clean && shape && names == expected
    }
    await checkAsync("Mail: reply script is among the compiled scripts") {
        let result = await MainActor.run { IntegrationScripts.compileAll() }
        return result["MailReply"] != nil && result["Mail"] != nil
    }
}
