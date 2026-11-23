import AppKit
import UniformTypeIdentifiers
import PippaCore

/// Sharing with an online AI: the review before anything from the Mac goes out (`ShareDesk`), the parts read for it and
/// the approved send.
extension ChatModel {
    /// The online AI a single question can go to while conversations stay on this Mac ("Ask OpenAI…").
    var handoffDestination: ShareDestination? { ShareDestination.handoff(SettingsModel.shared.inferenceSettings, recipients: .unresolved) }

    /// "Ask <provider>…": the review for one question to the recipient, with the files attached and Pippa's last answer
    /// here (each part with what it was read from). Nothing is sent before the person's OK.
    func askOnline() {
        guard !isAnswering, review == nil, let destination = ShareDestination.handoff(SettingsModel.shared.inferenceSettings) else { return }
        startReview(destination, handoff: true)
    }

    /// Where a review opened now would go: the online AI conversations use, or else the recipient of single questions.
    var reviewRoute: (destination: ShareDestination, handoff: Bool)? {
        let settings = SettingsModel.shared.inferenceSettings
        if let active = ShareDestination.active(settings) { return (active, false) }
        return ShareDestination.handoff(settings).map { ($0, true) }
    }

    /// The + menu: one source read on this Mac by Pippa herself, then the review for the online AI, or with the AI on
    /// this Mac for one question to the recipient of single questions.
    func share(_ source: SharingSource) {
        guard !isAnswering, let route = review.map({ ($0.plan.destination, $0.handoff) }) ?? reviewRoute else { return }
        let rules = SettingsModel.shared.inferenceSettings.sharing
        guard rules[source] == .ask, source != .photos, source != .documents, source != .contacts else { return }
        if review == nil { startReview(route.destination, handoff: route.handoff) }
        let extraction = ShareExtraction(host: PippaMCPService.currentHost)
        guard let reviewID = review?.id else { return }
        desk.reading()
        Task {
            let piece: SharePiece?
            var problem: String?
            do {
                switch source {
                case .mail: piece = try await extraction.selectedMail()
                case .calendar: piece = try await extraction.calendar()
                case .reminders: piece = try await extraction.reminders()
                case .documents, .photos, .contacts: piece = nil
                }
            } catch {
                piece = nil; problem = error.localizedDescription
            }
            // Into the review it was read for, even if that one was cancelled or parked meanwhile.
            desk.add(piece.map { [$0] } ?? [], problem: problem, to: reviewID, rules: SettingsModel.shared.inferenceSettings.sharing)
        }
    }

    /// One picture chosen in the Photos picker: only the text recognized in it on this Mac joins the review, under the
    /// Photos rule; the picture itself never leaves the Mac. `data` is the picture's bytes, read into a temporary file
    /// for local OCR and removed right after.
    func sharePhoto(type: UTType?, load: @escaping @MainActor () async -> Data?) {
        guard !isAnswering, let route = review.map({ ($0.plan.destination, $0.handoff) }) ?? reviewRoute,
              SettingsModel.shared.inferenceSettings.sharing.photos == .ask else { return }
        if review == nil { startReview(route.destination, handoff: route.handoff) }
        guard let reviewID = review?.id else { return }
        desk.reading()
        let name = T("Photo", table: "App")
        Task {
            let data = await load()
            let piece: SharePiece? = await Task.detached(priority: .userInitiated) { () -> SharePiece? in
                guard let data else { return nil }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-photo-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let file = folder.appendingPathComponent(name).appendingPathExtension(type?.preferredFilenameExtension ?? "jpg")
                guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
                      (try? data.write(to: file)) != nil else { return nil }
                return ShareExtraction.files([file]).first
            }.value
            desk.add(piece.map { [$0] } ?? [], problem: piece == nil ? T("Pippa couldn’t read this photo.", table: "App") : nil,
                     to: reviewID, rules: SettingsModel.shared.inferenceSettings.sharing)
        }
    }

    /// Opens the review for the conversation shown, resuming one parked there with its edits (`ShareDesk.open`), and
    /// reads the files it does not have yet. `composer`: what it is made from, the composer itself unless a retry says.
    func startReview(_ destination: ShareDestination, handoff: Bool, composer: ShareComposer? = nil, explicit: Bool = false) {
        if currentID == nil {
            let id = UUID().uuidString.lowercased()
            let words = (composer?.text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = words.isEmpty ? T("New Conversation", table: "App") : String(words.prefix(60))
            startConversation(id, title: title)
        }
        let rules = SettingsModel.shared.inferenceSettings.sharing
        let fresh = handoff ? lastAnswerHere().map { [$0] } ?? [] : []
        let unread = desk.open(in: currentID, destination: destination, handoff: handoff,
                               composer: composer ?? ShareComposer(text: draft, files: attachments), fresh: fresh, rules: rules, explicit: explicit)
        problem = nil
        ChatWindow.shared.show()
        guard !unread.isEmpty, let reviewID = review?.id else { return }
        Task {
            let pieces = await Task.detached(priority: .userInitiated) { ShareExtraction.files(unread, rules: rules) }.value
            desk.add(pieces, files: unread, to: reviewID, rules: SettingsModel.shared.inferenceSettings.sharing)
        }
    }

    /// A review parked in the conversation shown (cancelled, or not answered), for "Continue checking".
    var parkedReview: ShareReview? {
        desk.parked(in: currentID, handoff: !SettingsModel.shared.inferenceSettings.usesOnlineAI)
    }

    /// "Continue checking": the parked review as it was, with every edit, for the recipient as it is now.
    func resumeReview() {
        guard !isAnswering, review == nil, let route = reviewRoute, desk.parked(in: currentID, handoff: route.handoff) != nil else { return }
        startReview(route.destination, handoff: route.handoff, explicit: true)
    }

    /// The person no longer wants the parked review.
    func discardParkedReview() {
        guard let route = reviewRoute else { return }
        desk.discard(in: currentID, handoff: route.handoff)
    }

    /// The approved review failed: parked in its conversation, its words back into the composer only if that is empty.
    func parkFailed(_ review: ShareReview, in conversation: String, problem: String?) {
        var review = review
        review.conversation = conversation
        if let back = desk.failed(review, problem: problem, current: currentID, composer: ShareComposer(text: draft, files: attachments)) {
            draft = back.text; attachments = back.files
        }
    }

    /// Pippa's last answer here, by the AI on this Mac, as a part: its sources are what its tools read.
    private func lastAnswerHere() -> SharePiece? {
        guard let current, let index = current.messages.lastIndex(where: { $0.role == .assistant }) else { return nil }
        let answer = current.messages[index]
        let text = answer.result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard answer.destination == nil, answer.error == nil, !text.isEmpty else { return nil }
        // Pi can use any earlier local turn to answer a follow-up, even when it calls no tool on this turn.
        let sources = current.localSources(through: index)
        return SharePiece(sources: sources, title: T("Pippa’s answer on this Mac", table: "App"), text: text)
    }

    static func localHistorySources(in history: ArraySlice<ChatMessage>) -> Set<SharingSource> {
        var sources = Set<SharingSource>()
        for message in history where message.destination == nil {
            if message.role == .assistant {
                sources.formUnion(message.provenance ?? SharingSource.allCases)
            }
            for file in message.files {
                sources.formUnion(SharingSource.sources(forFile: URL(fileURLWithPath: file)))
            }
        }
        return sources
    }

    /// The person's changes in the review sheet (their words, a part's text, leaving a part out).
    func updateReview(_ change: (inout SharePlan) -> Void) { desk.update(change) }

    /// Cancel or closing the sheet: nothing is sent; the edits stay, parked with the conversation, and the edited words
    /// go into the composer if it still holds what the review opened with.
    func dismissReview() {
        guard review != nil else { return }
        if let back = desk.cancel(current: currentID, composer: ShareComposer(text: draft, files: attachments)) {
            draft = back.text; attachments = back.files
        }
    }

    /// Send: the approval is fixed now (`ShareApproval`), for the destination shown and the rules as they are now. If the
    /// online AI changed while the review was open, nothing is sent and the review says so.
    /// The answer goes to the review's own conversation; a draft typed in the composer meanwhile stays there.
    func approveReview() {
        guard let current = review, !isAnswering else { return }
        let settings = SettingsModel.shared.inferenceSettings
        let now = current.handoff ? ShareDestination.handoff(settings) : ShareDestination.active(settings)
        switch desk.approve(current: currentID, destination: now, composer: ShareComposer(text: draft, files: attachments), rules: settings.sharing) {
        case .send(let approval, let sent, let clearComposer):
            if clearComposer { draft = ""; attachments = []; frontApp = nil }
            ask(approval.question, files: sent.files.map(\.path), outgoing: .approved(approval), in: sent.conversation, handoff: sent.handoff,
                destination: approval.destination.label, shared: approval.parts.map(\.title), review: sent)
        case .destinationChanged:
            desk.setProblem(PiSession.Failure.destinationChanged.localizedDescription)
        case .parked, .nothing:
            break
        }
    }
}
