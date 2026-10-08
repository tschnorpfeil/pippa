import Foundation
import PippaCore

#if DEBUG
/// Exercises the host generation path with synthetic mail, never native Mail.
@MainActor enum MailIdentitySnapshot {
    static func run(model: AppModel, shell: ShellController, directory: URL) async {
        var observations: [String] = []
        var failures: [String] = []
        func verify(_ condition: Bool, _ description: String) {
            observations.append("\(condition ? "PASS" : "FAIL"): \(description)")
            if !condition { failures.append(description) }
        }
        func finish() {
            let heading = failures.isEmpty ? "PASS: mail identity fixture" : "FAIL: mail identity fixture"
            try? (heading + "\n" + observations.joined(separator: "\n") + "\n")
                .write(to: directory.appendingPathComponent("mailidentity.txt"), atomically: true, encoding: .utf8)
        }
        guard model.engine is StubEngine,
              DevSnapshot.directory?.standardizedFileURL == directory.standardizedFileURL else {
            verify(false, "Requires demo engine and isolated PIPPA_SNAPSHOT directory")
            finish(); return
        }
        guard let skill = PippaSkill.parse("---\nname: antwort-schreiben\ndescription: Synthetic mail identity fixture\npippa-draft: true\n---", folder: "antwort-schreiben") else {
            verify(false, "Synthetic reply skill parses")
            finish(); return
        }
        let original = directory.appendingPathComponent("mailidentity-original.eml")
        let missing = directory.appendingPathComponent("mailidentity-no-id.eml")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "Message-ID: <fixture-original@example.invalid>\r\nFrom: Sender <sender@example.invalid>\r\nReply-To: Reply <reply@example.invalid>\r\nSubject: =?UTF-8?Q?Gr=C3=BC=C3=9Fe?=\r\n\r\nSynthetic original.\r\n"
                .write(to: original, atomically: true, encoding: .utf8)
            try "From: Sender <sender@example.invalid>\r\nSubject: No identity\r\n\r\nSynthetic mail without identity.\r\n"
                .write(to: missing, atomically: true, encoding: .utf8)
        } catch {
            verify(false, "Synthetic mail files created: \(error.localizedDescription)")
            finish(); return
        }
        func generate(from file: URL) async -> ConversationMessage? {
            model.newConversation()
            model.attach(.files([file]), items: [file], startsFresh: false, open: true)
            verify(model.conversations.current?.context?.files.contains(file) == true, "Real attachment path retains \(file.lastPathComponent)")
            model.conversations.send("Entwirf eine kurze Antwort auf diese Mail.", skill: skill)
            for _ in 0..<200 {
                if !model.conversations.isRunning {
                    verify(model.conversations.error == nil, "Generated response completes for \(file.lastPathComponent)")
                    return model.conversations.current?.messages.last(where: { $0.role == .assistant && $0.mailDraft != nil })
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            verify(false, "Generation timed out for \(file.lastPathComponent)")
            model.conversations.stop()
            return nil
        }
        func persisted(_ conversationID: UUID, _ messageID: UUID) -> ConversationMailDraft? {
            do {
                let store = try ConversationStore(directory: directory.appendingPathComponent("conversations"))
                return try store.load(conversationID).messages.first(where: { $0.id == messageID })?.mailDraft
            } catch {
                verify(false, "Persisted history reload: \(error.localizedDescription)")
                return nil
            }
        }
        guard let response = await generate(from: original), let card = response.mailDraft,
              let topicID = model.conversations.current?.id else {
            verify(false, "Reply generation creates a mail card")
            finish(); return
        }
        verify(card.replySource?.messageID == "fixture-original@example.invalid", "Original RFC Message-ID captured by generation hook")
        verify(card.replySource?.replyTo == "Reply <reply@example.invalid>", "Host captures Reply-To rather than sender")
        verify(card.replySource?.subject == "Grüße" && card.subject == "Re: Grüße", "Encoded original subject decodes and prefills reply subject")
        verify(card.to == "reply@example.invalid" && card.requiresOriginalReply, "Generated card prefills reply recipient and requires original")
        verify(persisted(topicID, response.id) == card, "Generated card and immutable provenance survive history reload")
        model.removeConversationAttachment(original)
        do { try FileManager.default.removeItem(at: original) }
        catch { verify(false, "Remove synthetic original: \(error.localizedDescription)") }
        verify(model.conversations.current?.context?.files.contains(original) != true, "Original removed from future context")
        verify(model.conversations.current?.messages.first(where: { $0.id == response.id })?.mailDraft == card,
               "Removing original source preserves generated card and provenance")
        var edited = card
        edited.to = "edited@example.invalid"
        edited.subject = "Reviewed subject"
        edited.body = "Reviewed complete answer."
        verify(model.conversations.updateMailDraft(messageID: response.id, draft: edited), "Reviewed fields update through controller")
        verify(edited.replySource == card.replySource && edited.requiresOriginalReply, "Reviewed edits cannot change original provenance or reply mode")
        verify(persisted(topicID, response.id) == edited, "Reviewed card persists after original file is gone")
        guard let noIDResponse = await generate(from: missing), let noIDCard = noIDResponse.mailDraft,
              let noIDTopic = model.conversations.current?.id else {
            verify(false, "No-ID mail still creates a reviewable card")
            finish(); return
        }
        verify(noIDCard.requiresOriginalReply && noIDCard.replySource == nil, "Missing-ID email requires original reply without invented provenance")
        verify(persisted(noIDTopic, noIDResponse.id) == noIDCard, "Missing-ID reply requirement survives history reload")
        verify(card.state == .draft && edited.state == .draft && noIDCard.state == .draft && !model.mailDraftOpening,
               "Generation and editing invoke no Mail handoff")
        finish()
    }
}
#endif
