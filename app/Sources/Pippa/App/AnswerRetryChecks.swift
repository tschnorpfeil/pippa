import Foundation
import PiRPC
import PippaCore

/// `Pippa --check-approvals`: what the chat makes of Pi's waits on an online AI's limit (`ChatModel.apply`): the countdown,
/// Stop during the wait, Continue after the tries ran out, and a used-up allowance without Continue.
@MainActor
enum AnswerRetryChecks {
    static func run() -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print("\(ok ? "PASS" : "FAIL") \(name)")
            if !ok { failures += 1 }
        }
        let limit = "429 Too Many Requests: rate limit exceeded"
        let chat = ChatModel()
        func start(shared: [String]? = nil) {
            let question = ChatMessage(role: .user, text: "Sortiere meine Mails", destination: "OpenAI", shared: shared)
            let reply = ChatMessage(role: .assistant, text: "", destination: "OpenAI")
            chat.replaceForSnapshot([Conversation(id: "r", title: "Mails", updated: Date(), messages: [question, reply])],
                                    current: "r", answering: true)
        }
        var answer: ChatMessage? { chat.conversations.first?.messages.last }

        start()
        chat.apply(.assistantEnded(text: "", stopReason: "error", error: limit), in: "r")
        chat.apply(.retryScheduled(attempt: 1, maxAttempts: 4, delayMs: 42_000, error: limit), in: "r")
        let waiting = chat.retryWait
        check(waiting?.rateLimit == true && (41...42).contains(waiting?.seconds ?? 0) && answer?.error == nil,
              "a wait on a rate limit counts down from its delay, and the failed try is no error on the answer")
        chat.apply(.textDelta("Erledigt."), in: "r")
        check(chat.retryWait == nil, "the next try's first words end the countdown, before Pi reports the try's end")
        chat.apply(.retryEnded(success: true, attempt: 1, finalError: nil), in: "r")
        check(chat.retryWait == nil && answer?.error == nil && answer?.resumeAfter == nil,
              "a successful try ends the wait and the answer goes on as usual")

        start()
        chat.apply(.retryScheduled(attempt: 1, maxAttempts: 4, delayMs: 503_000, error: "503 Service Unavailable"), in: "r")
        check(chat.retryWait?.rateLimit == false, "a wait after another failure is not called a limit")

        // Stop during the wait: Pi ends it ("Retry cancelled"); the answer is stopped, nothing to continue.
        start()
        chat.apply(.retryScheduled(attempt: 1, maxAttempts: 4, delayMs: 15_000, error: limit), in: "r")
        chat.stop()
        let stoppedWait = chat.retryWait
        chat.apply(.retryEnded(success: false, attempt: 1, finalError: limit), in: "r")
        check(stoppedWait == nil && chat.retryWait == nil && answer?.resumeAfter == nil && answer?.error == nil,
              "Stop during the wait ends the countdown at once and offers no Continue")

        // The provider keeps answering 429: after the last try the answer offers Continue, not before a minute, and only
        // while typed words still go to the session it ran in.
        let session = PiSession.shared.answerScope
        defer { PiSession.shared.answerScope = session }
        let scope = ShareDestination(PiModelSelection(providerID: "openai", modelID: "gpt-fixture", providerName: "OpenAI"),
                                     recipient: "account-a").sessionTag
        PiSession.shared.answerScope = scope
        start()
        let failed = Date()
        for attempt in 1...4 {
            chat.apply(.assistantEnded(text: "", stopReason: "error", error: limit), in: "r")
            chat.apply(.retryScheduled(attempt: attempt, maxAttempts: 4, delayMs: 15_000, error: limit), in: "r")
        }
        chat.apply(.assistantEnded(text: "", stopReason: "error", error: limit), in: "r")
        chat.apply(.retryEnded(success: false, attempt: 4, finalError: limit), in: "r")
        let messages = chat.conversations.first?.messages ?? []
        let after = answer?.resumeAfter?.timeIntervalSince(failed) ?? 0
        check(chat.retryWait == nil && answer?.error != nil && (60...61).contains(after)
              && answer?.resumeScope == scope
              && !ChatModel.resumable(messages, now: failed.addingTimeInterval(59), scope: scope)
              && ChatModel.resumable(messages, now: failed.addingTimeInterval(61), scope: scope),
              "a rate limit after every try ends the answer with a sentence and Continue, available 60 s later")
        chat.replaceForSnapshot(chat.conversations, current: "r", answering: false)
        chat.resume(now: failed.addingTimeInterval(30))
        check(chat.isAnswering == false && answer?.resumeAfter != nil, "Continue before its minute sends nothing")
        check(!ChatModel.resumable(messages, now: failed.addingTimeInterval(61), scope: "mac-other")
              && !ChatModel.resumable(messages, now: failed.addingTimeInterval(61), scope: nil),
              "another AI, account, Mac access or the AI on this Mac: no Continue into a session the answer never ran in")
        let until = failed.addingTimeInterval(3)
        let ticks = ChatModel.resumeTicks(until: until, now: failed)
        check(ticks.last == until && ticks.count == 4 && ChatModel.resumeTicks(until: failed, now: until) == [until],
              "the Continue countdown ticks once a second until it may go, then no more")

        // The AI on this Mac or an unverified recipient: Pi's session is not one to go back to.
        PiSession.shared.answerScope = nil
        start()
        chat.apply(.assistantEnded(text: "", stopReason: "error", error: limit), in: "r")
        chat.apply(.retryEnded(success: false, attempt: 4, finalError: limit), in: "r")
        check(answer?.resumeAfter == nil && answer?.resumeScope == nil, "an answer outside a resumable session offers no Continue")
        PiSession.shared.answerScope = scope

        // An approved question ran in a session of its own: no Continue there.
        start(shared: ["Mail"])
        chat.apply(.assistantEnded(text: "", stopReason: "error", error: limit), in: "r")
        chat.apply(.retryEnded(success: false, attempt: 4, finalError: limit), in: "r")
        check(answer?.resumeAfter == nil, "an approved question's answer offers no Continue")

        // A used-up allowance: Pi does not try again; today's sentence, no Continue.
        start()
        chat.apply(.assistantEnded(text: "", stopReason: "error", error: "429 You exceeded your current quota (insufficient_quota)"), in: "r")
        check(answer?.error == ChatModel.limitMessage(.quota) && answer?.resumeAfter == nil && chat.retryWait == nil,
              "a used-up allowance says so and offers no Continue")

        // Any other online failure: a calm sentence by its class, never the provider's raw text with keys or addresses.
        let raw = #"503 {"error":{"message":"upstream unavailable for key sk-proj-abcdef1234567890XYZ (anna@example.com)","stack":"at /srv/app.js:1"}}"#
        DiagnosticsLog.shared.flush()
        let before = (try? String(contentsOf: DiagnosticsLog.shared.fileURL, encoding: .utf8)) ?? ""
        let plain = ChatModel.modelError(raw, online: true)
        DiagnosticsLog.shared.flush()
        let added = ((try? String(contentsOf: DiagnosticsLog.shared.fileURL, encoding: .utf8)) ?? "").dropFirst(before.count)
        check(plain == ModelFailure(failureClass: .unavailable).onlineText && !plain.contains("503") && !plain.contains("sk-")
                && added.contains("ki-fehler klasse=unavailable online=true status=503") && !added.contains("anna") && !added.contains("abcdef"),
              "an online failure reads as a calm sentence and logs only its class and status")
        check(ChatModel.modelError("something odd {\"debug\":1}", online: true) == UserMessage.generic
                && ChatModel.modelError("401 Unauthorized", online: true) == ChatModel.limitMessage(.signedOut)
                && ChatModel.modelError("local failure", online: false) == "local failure",
              "an unknown online failure gets the short fallback; sign-in keeps its sentence; local failures stay as they were")
        chat.replaceForSnapshot([], current: nil, answering: false)
        return failures == 0 ? 0 : 1
    }
}
