import Foundation
import PiRPC
import PippaCore

/// Retry, rate-limit continuation and plain-language model errors for `ChatModel`.
extension ChatModel {
    /// The last answer failed: ask the same question again.
    /// An approved question is never sent again as it was: it goes back through the review (no replay).
    func retry(in conversationID: String? = nil) {
        let targetID = conversationID ?? currentID
        guard !isAnswering, review == nil, let id = targetID, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        if currentID != id { select(id) }
        let messages = conversations[index].messages
        guard messages.count >= 2, messages[messages.count - 1].role == .assistant, messages[messages.count - 2].role == .user else { return }
        let question = messages[messages.count - 2]
        let files = question.files.map { URL(fileURLWithPath: $0) }
        if question.shared != nil, let route = reviewRoute {
            // Back through the review, with the edits of the one that failed when it is parked here. The composer keeps
            // whatever was typed since.
            conversations[index].removeTurnForRetry()
            save(id)
            let parked = desk.parked(in: id, handoff: route.handoff) != nil
            startReview(route.destination, handoff: route.handoff, composer: ShareComposer(text: question.text, files: files), explicit: parked)
            return
        }
        guard question.shared == nil else {
            // No online AI to check it for any more: the words go back into an empty composer, nothing is sent.
            if draft.isEmpty && attachments.isEmpty { draft = question.text; attachments = files }
            return
        }
        conversations[index].removeTurnForRetry()
        draft = question.text
        attachments = files
        send()
    }

    /// Pi waits before it tries again: how long, and whether the online AI said "too many requests".
    struct RetryWait: Equatable {
        var until: Date
        var rateLimit: Bool
        var seconds: Int
    }

    /// Continue waits this long after the last try failed: a rate limit counts per minute.
    static let resumeDelay: TimeInterval = 60

    /// What the chat and Pippa Island say during the wait.
    static func retryLabel(_ wait: RetryWait) -> String {
        wait.rateLimit ? T("The online AI is at its limit. Continuing in %lld s", table: "App", wait.seconds)
            : T("The AI didn’t answer. Trying again in %lld s", table: "App", wait.seconds)
    }

    /// Starts (`until`) or ends (`nil`) the countdown.
    func waitForRetry(_ until: Date?, rateLimit: Bool = false) {
        retryTick?.cancel()
        retryTick = nil
        guard let until else { if retryWait != nil { retryWait = nil }; return }
        func seconds() -> Int { max(0, Int(until.timeIntervalSinceNow.rounded(.up))) }
        retryWait = RetryWait(until: until, rateLimit: rateLimit, seconds: seconds())
        retryTick = Task {
            while !Task.isCancelled, let wait = retryWait, wait.seconds > 0 {
                try? await Task.sleep(for: .seconds(1))
                if !Task.isCancelled { retryWait?.seconds = seconds() }
            }
            // The wait is over and Pi tries again: the answer shows its work, not "Continuing in 0 s".
            if !Task.isCancelled { retryWait = nil }
        }
    }

    /// What Pi receives with Continue: the session still holds everything the stopped answer did.
    static let resumePrompt = "[Your last answer stopped because the online AI was at its limit. Continue where you stopped. "
        + "Do not repeat changes that are already done; if you are unsure whether one was, check first.]"

    /// Whether Continue may go now: the last answer stopped at the online AI's limit, its minute is over, and typed
    /// words still go to its Pi session (`scope`, `PiSession.typedScope`).
    static func resumable(_ messages: [ChatMessage], now: Date, scope: String?) -> Bool {
        guard let last = messages.last, last.role == .assistant, let after = last.resumeAfter, scope != nil,
              last.resumeScope == scope else { return false }
        return after <= now
    }

    /// When the Continue countdown changes: each whole second from `now` until `until`, none after it.
    static func resumeTicks(until: Date, now: Date = Date()) -> [Date] {
        let left = max(0, Int(until.timeIntervalSince(now).rounded(.up)))
        return [now] + (0..<left).map { until.addingTimeInterval(-Double(left - 1 - $0)) }
    }

    /// The session typed words go to now (`PiSession.typedScope`).
    private static func typedScope() -> String? {
        let settings = SettingsModel.shared.inferenceSettings
        return PiSession.typedScope(settings, ShareDestination.active(settings))
    }

    /// The answer offers Continue: it stopped at the limit. Whether the route still leads to its session is checked when
    /// the button is pressed (`resume`), not on every redraw: that reads the provider's files and the Keychain.
    func offersResume(_ message: ChatMessage) -> Bool { message.resumeAfter != nil }

    /// Continue after the online AI stayed at its limit: one follow-up in the same conversation's Pi session, never the
    /// question again. Not before `resumeAfter`.
    func resume(in conversationID: String? = nil, now: Date = Date()) {
        let targetID = conversationID ?? currentID
        guard !isAnswering, review == nil, let id = targetID, let index = conversations.firstIndex(where: { $0.id == id }),
              let last = conversations[index].messages.indices.last, let after = conversations[index].messages[last].resumeAfter,
              after <= now else { return }
        if currentID != id { select(id) }
        let scope = Self.typedScope()
        // Another AI, account or Mac access since the answer stopped: its session is not reachable from here. Continue
        // goes, and the answer offers Try Again like any other failed one.
        if scope == nil || conversations[index].messages[last].resumeScope != scope {
            conversations[index].messages[last].resumeAfter = nil
            conversations[index].messages[last].resumeScope = nil
            return
        }
        guard Self.resumable(conversations[index].messages, now: now, scope: scope) else { return }
        let settings = SettingsModel.shared.inferenceSettings
        let destination = ShareDestination.active(settings)
        let limited = destination != nil && !settings.allowsMacAccess(destination)
        guard let outgoing = Self.outgoing(Self.resumePrompt, files: [], frontApp: nil, undone: [], online: limited) else { return }
        conversations[index].messages[last].resumeAfter = nil
        conversations[index].messages[last].resumeScope = nil
        ask(T("Continue", table: "App"), files: [], outgoing: outgoing, in: id, destination: destination?.label)
    }

    /// A failure mid-answer as one plain sentence: an online provider's ("401 {…}", "usage limit"), or the AI on this Mac
    /// running out of memory (the raw text goes to the log, not the chat); anything else as Pi said it.
    static func modelError(_ error: String, online: Bool) -> String {
        if let plain = OMLXServer.plainFailure(error, online: online) {
            DiagnosticsLog.shared.event("ki-zu-wenig-speicher", ["text": error])
            return plain
        }
        guard online, let problem = PiProviderClient.problem(in: error) else { return error }
        return limitMessage(problem)
    }

    /// The sentence for an online AI's problem: a used-up allowance, too many requests for now, or a lost sign-in.
    static func limitMessage(_ problem: PiProviderClient.Problem) -> String {
        switch problem {
        case .quota: T("Your online AI limit is reached for now. Try again later, or switch to the AI on this Mac in Settings.", table: "App")
        case .rateLimit: T("The online AI is at its limit right now. Try again in a minute.", table: "App")
        case .signedOut: T("Reconnect your online AI in Settings.", table: "App")
        }
    }
}
