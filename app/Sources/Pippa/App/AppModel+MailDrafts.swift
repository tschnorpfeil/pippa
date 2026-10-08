import AppKit
import Foundation
import PippaCore

extension AppModel {
    /// The card click authorizes one unsent native reply window with exactly these fields.
    func openMailDraft(messageID: UUID) {
        guard !isActiveWork, let conversation = conversations.current,
              let draft = conversation.messages.first(where: { $0.id == messageID })?.mailDraft,
              draft.state == .draft, draft.canOpen else { return }
        if draft.requiresOriginalReply && draft.replySource == nil {
            show(.message(title: T("Reply could not be opened", table: "App"),
                          body: T("The original email has no usable Message-ID. Copy the draft and reply manually in Mail.", table: "App"), isError: false))
            return
        }
        let conversationID = conversation.id
        withAccess(.mail) { [weak self] in
            guard let self, self.conversations.current?.id == conversationID,
                  self.conversations.current?.messages.first(where: { $0.id == messageID })?.mailDraft == draft,
                  self.conversations.transitionMailDraft(messageID: messageID, in: conversationID, to: .opening) else { return }
            self.show(.input)
            self.mailDraftOpening = true
            let engine = self.engine
            let recipient = draft.to.trimmingCharacters(in: .whitespacesAndNewlines)
            let outgoing = MailDraft(messageID: draft.replySource?.messageID, to: recipient.isEmpty ? nil : recipient, toName: nil,
                                     subject: draft.subject, body: draft.body, isReply: draft.requiresOriginalReply, exactSubject: true)
            let progress: @Sendable (Int, Int) -> Void = { done, total in
                Task { @MainActor [weak self] in
                    guard let self, self.mailDraftOpening else { return }
                    self.mailDraftSearch = (done, total)
                }
            }
            self.mailDraftTask = Task { [weak self] in
                do {
                    let result = try await MailOriginalSearch.$progress.withValue(progress) {
                        try await engine.insertMailReply(outgoing)
                    }
                    self?.conversations.transitionMailDraft(messageID: messageID, in: conversationID, to: .opened)
                    if result == .replyNeedsPaste {
                        // The threaded reply is open; Mail did not report the text. One ⌘V puts it in.
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(draft.body, forType: .string)
                        self?.show(.message(title: T("Reply opened in Mail", table: "App"),
                                            body: T("Your reply is open in Mail, but Mail could not confirm your text in it. Your text is on the clipboard: if it’s missing, click into the reply and press ⌘V.", table: "App"),
                                            isError: false))
                    }
                } catch {
                    if let explanation = LetterController.retryableInsertProblem(error) {
                        // Nothing is in Mail: the card goes back to an editable draft.
                        self?.conversations.transitionMailDraft(messageID: messageID, in: conversationID, to: .draft)
                        self?.show(.message(title: T("Reply could not be opened", table: "App"), body: explanation, isError: false))
                    } else {
                        // The native window may exist even if the acknowledgement failed. No automatic
                        // retry; the card offers „Back to Draft“ once the person has checked Mail.
                        self?.conversations.transitionMailDraft(messageID: messageID, in: conversationID, to: .uncertain)
                        self?.show(.message(title: T("Reply could not be opened", table: "App"),
                                            body: T("The reply could not be confirmed. Check Mail before continuing; an unsent reply may already be open.", table: "App"),
                                            isError: false))
                    }
                }
                self?.mailDraftTask = nil
                self?.mailDraftSearch = nil
                self?.mailDraftOpening = false
            }
        }
    }

    /// Stop while the original is still being looked for. Nothing is in Mail yet at that point.
    func stopMailDraftOpening() {
        guard mailDraftSearch != nil else { return }
        mailDraftTask?.cancel()
    }

    /// After „check Mail first“: the person's click makes the card editable again. Never automatic.
    func reviseUncertainMailDraft(messageID: UUID) {
        guard !isActiveWork, let id = conversations.current?.id else { return }
        conversations.transitionMailDraft(messageID: messageID, in: id, to: .draft)
    }

    func discardMailDraft(messageID: UUID) {
        guard !isActiveWork, let id = conversations.current?.id else { return }
        conversations.transitionMailDraft(messageID: messageID, in: id, to: .discarded)
    }
}
