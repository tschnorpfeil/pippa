import AppKit
import Foundation
import PiRPC
import PippaCore

/// `Pippa --check-approvals`: the question flow without any window. Asks while a presenter is registered, answers,
/// cancels and times out, and checks each answer reaches the waiting caller exactly once. Prints one line per check.
@MainActor
enum ApprovalsChecks {
    static func run() async -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print("\(ok ? "PASS" : "FAIL") \(name)")
            if !ok { failures += 1 }
        }
        let approvals = Approvals.shared
        var revealed = 0
        approvals.present("check") { revealed += 1 }
        defer { approvals.dismiss("check") }
        check(approvals.hasPresenter, "a registered presenter receives questions")

        func request(_ id: String, _ method: String = "confirm", options: [String] = [], timeout: Int? = nil) -> PiUIRequest {
            PiUIRequest(id: id, method: method, title: "Search the web?", message: "Pippa wants to look this up online.",
                        options: options, timeout: timeout)
        }
        func settle() async { for _ in 0..<5 { await Task.yield() } }

        let allow = Task { await approvals.ask(request("q1")) }
        await settle()
        check(approvals.questions.map(\.id) == ["q1"], "an open question is listed")
        check(revealed == 1, "a new question brings its presenter forward")
        approvals.answer("q1", .confirmed(true))
        check(await allow.value == .confirmed(true), "Allow reaches the caller")
        check(approvals.questions.isEmpty, "an answered question disappears")
        approvals.answer("q1", .confirmed(false))   // late or double click: ignored

        // Shared approval parser + structured key-value detection (used by QuestionCard, Island and fallback alert).
        let selectParsed = ApprovalPresentation.parse(PiUIRequest(id: "p1", method: "select", title: "Pick one\n\nDetails below", message: "", options: ["A"]))
        let mailParsed = ApprovalPresentation.parse(PiUIRequest(id: "p2", method: "confirm", title: "Send this mail?",
                                                                message: "To: anna@example.test\n\nSubject: Vertrag\nFrom: ich@example.test\n\nHallo Anna."))
        let kv = ApprovalPresentation.keyValueLine("To: anna@example.test")
        let notURL = ApprovalPresentation.keyValueLine("https: //example.com")
        let notProse = ApprovalPresentation.keyValueLine("Hinweis zur Kündigung 2026: Bitte prüfen")
        check(selectParsed.title == "Pick one" && selectParsed.summary == "Details below" && selectParsed.detail == nil
              && mailParsed.summary == "To: anna@example.test" && mailParsed.detail == "Subject: Vertrag\nFrom: ich@example.test\n\nHallo Anna."
              && kv?.label == "To" && kv?.value == "anna@example.test" && notURL == nil && notProse == nil,
              "approval parser splits select titles and detects structured metadata lines without matching URLs or prose")

        // mail_send names its buttons; the chat's card, the island and the alert all take them from here.
        let named = Confirmations.confirmLabels(request("q-send", options: ["Don’t Send", "Send"]))
        let plain = Confirmations.confirmLabels(request("q-plain"))
        check(named == ("Don’t Send", "Send") && plain == (T("Don’t Allow", table: "App"), T("Allow", table: "App")),
              "a confirm shows its own button words (Don’t Send / Send), otherwise Don’t Allow / Allow")
        // The alert (no view on screen): Return and the focus say no, so only a click sends.
        let sendAlert = NSAlert()
        let yesResponse = Confirmations.addConfirmButtons(sendAlert, request("q-send", options: ["Don’t Send", "Send"]))
        let yesIndex = yesResponse.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let yesButton = sendAlert.buttons.indices.contains(yesIndex) ? sendAlert.buttons[yesIndex] : nil
        check(sendAlert.buttons.filter { $0.keyEquivalent == "\r" }.map(\.title) == ["Don’t Send"] && yesButton?.title == "Send"
              && yesButton?.keyEquivalent == "" && (sendAlert.window.initialFirstResponder as? NSButton)?.title == "Don’t Send",
              "in the alert Return and the focus are on Don’t Send; only a click on Send sends")

        let pick = Task { await approvals.ask(request("q2", "select", options: ["Once", "Always"])) }
        await settle()
        approvals.answer("q2", .value("Once"))
        check(await pick.value == .value("Once"), "a choice reaches the caller")

        let first = Task { await approvals.ask(request("q3")) }
        let second = Task { await approvals.ask(request("q4")) }
        await settle()
        check(approvals.questions.count == 2, "two questions wait side by side")
        approvals.cancelAll()
        let cancelled = [await first.value, await second.value]
        check(cancelled == [.cancelled, .cancelled], "cancelling answers every open question")
        check(approvals.questions.isEmpty, "nothing is left after cancelling")

        let timed = Task { await approvals.ask(request("q5", timeout: 50)) }
        await settle()
        check(approvals.questions.count == 1, "a question with a timeout is listed")
        let started = Date()
        let late = await timed.value
        check(late == .cancelled && Date().timeIntervalSince(started) < 2, "Pi's timeout cancels the question")
        check(approvals.questions.isEmpty, "a timed-out question disappears")

        // The last view that shows questions goes (a new conversation replaced the transcript): open questions go to the
        // alert, unless another view takes over within the same turn.
        var alerted: [String] = []
        approvals.fallback = { request in alerted.append(request.id); return .confirmed(false) }
        let open = Task { await approvals.ask(request("q6")) }
        await settle()
        approvals.dismiss("check")
        approvals.present("check") { revealed += 1 }
        await settle()
        check(alerted.isEmpty && approvals.questions.map(\.id) == ["q6"], "a view that takes over within the turn keeps the question")
        approvals.dismiss("check")
        await settle()
        check(alerted == ["q6"] && approvals.questions.isEmpty, "with no view left, an open question goes to the alert")
        approvals.answer("q6", .cancelled)   // a failed check must not keep the run waiting
        check(await open.value == .confirmed(false), "the alert's answer reaches the caller")
        approvals.present("check") { revealed += 1 }

        let turnA = PippaMCPTurn(), turnB = PippaMCPTurn()
        let card = ResultCard.mail(MailCard(query: "Synthetic", mails: [], total: 0, calendar: .current))
        let host = PippaMCPService.configured(.demo(), asksForAccess: false)
        host.turns.begin(turnA)
        var note = PippaMCPReadNote(tool: "mail_search", read: true, line: "Synthetic", card: card)
        note.turnID = turnA.id
        host.onRead?(note)
        host.turns.end(turnA)
        host.turns.begin(turnB)
        note.turnID = nil
        host.onRead?(note)
        check(PippaMCPService.takeReadCards(turnID: turnB.id).isEmpty, "A newer answer cannot take another turn’s or unscoped cards")
        check(PippaMCPService.takeReadCards(turnID: turnA.id) == [card], "An ended answer still collects its own cards")
        note.turnID = turnA.id
        host.onRead?(note)
        check(PippaMCPService.takeReadCards(turnID: turnA.id).isEmpty, "A note arriving after its cards were collected is discarded")
        host.turns.end(turnB)

        await actionCardChecks(approvals, check: check)
        await answeredQuestionChecks(approvals, check: check)
        await runUndoChecks(check: check)
        await runSteerChecks(check: check)
        await runSteerBurstChecks(approvals, check: check)
        await runQueueChecks(check: check)
        await runPDFBesideAnswerChecks(check: check)
        failures += Int(await HeadlessAskChecks.run())

        print(failures == 0 ? "approvals: all checks passed" : "approvals: \(failures) failed")
        return failures == 0 ? 0 : 1
    }
}

extension ApprovalsChecks {
    /// One-card `select` choice parsing, whitespace rejection, answered-question persistence, JSON round-trip and
    /// backwards-compatible decoding, and cancellation/timeout/stop outcomes (A5, A6, A7).
    static func answeredQuestionChecks(_ approvals: Approvals, check: (Bool, String) -> Void) async {
        // A6: Shared `ApprovalChoices` helper detects English and German `otherChoice` sentinels.
        let enChoices = ApprovalChoices.parse(["Opt 1", "Opt 2", "Opt 3", "Opt 4", "Something else…"])
        let deChoices = ApprovalChoices.parse(["Lena Berger", "Lena Koch", "Etwas anderes …"])
        let plainChoices = ApprovalChoices.parse(["Once", "Always"])
        check(enChoices.options == ["Opt 1", "Opt 2", "Opt 3", "Opt 4"] && enChoices.allowsCustomText && enChoices.customPrompt == "Something else…"
              && deChoices.options == ["Lena Berger", "Lena Koch"] && deChoices.allowsCustomText
              && plainChoices.options == ["Once", "Always"] && !plainChoices.allowsCustomText && plainChoices.customPrompt == nil,
              "shared choice parser splits trailing otherChoice sentinels in English and German while keeping plain choices intact")

        // A7: Whitespace-only free text is never accepted as a valid answer.
        check(ApprovalChoices.validatedText("") == nil
              && ApprovalChoices.validatedText("   \t\n  ") == nil
              && ApprovalChoices.validatedText("  Lena from work  ") == "Lena from work",
              "whitespace-only free text is rejected and valid free text is trimmed")

        // A5 & A7: Answering, cancelling, timing out and stopping record read-only entries on the running ChatMessage.
        let chat = ChatModel.shared
        let saved = (chat.conversations, chat.currentID)
        let id = "answered-question-check"
        chat.showSample([Conversation(id: id, title: "Synthetic", updated: Date(),
                                      messages: [ChatMessage(role: .user, text: "Check"), ChatMessage(role: .assistant, text: "")])],
                        current: id, answering: true)
        defer { chat.showSample(saved.0, current: saved.1, answering: false) }

        func settle() async { for _ in 0..<5 { await Task.yield() } }

        let confirmTask = Task {
            await approvals.ask(PiUIRequest(id: "aq-confirm", method: "confirm", title: "Search the web?",
                                            message: "Pippa wants to look this up online."))
        }
        await settle()
        approvals.answer("aq-confirm", .confirmed(true))
        _ = await confirmTask.value

        let selectTask = Task {
            await approvals.ask(PiUIRequest(id: "aq-select", method: "select", title: "Which Lena?", message: "",
                                            options: ["Lena B.", "Lena K.", "Lena M.", "Lena S.", "Something else…"]))
        }
        await settle()
        approvals.answer("aq-select", .value("Lena from work"))
        _ = await selectTask.value

        let cancelTask = Task {
            await approvals.ask(PiUIRequest(id: "aq-cancel", method: "select", title: "Pick folder", message: "",
                                            options: ["Documents", "Downloads"]))
        }
        await settle()
        approvals.answer("aq-cancel", .cancelled)
        _ = await cancelTask.value

        let timeoutTask = Task {
            await approvals.ask(PiUIRequest(id: "aq-timeout", method: "confirm", title: "Timed out?",
                                            message: "Should cancel automatically.", timeout: 40))
        }
        await settle()
        _ = await timeoutTask.value

        let stopTask = Task {
            await approvals.ask(PiUIRequest(id: "aq-stop", method: "confirm", title: "Stopped?",
                                            message: "Cancelled when the answer stops."))
        }
        await settle()
        approvals.cancelAll()
        _ = await stopTask.value

        let whitespaceRecord = AnsweredQuestion.from(
            Approvals.Question(id: "aq-blank", request: PiUIRequest(id: "aq-blank", method: "input", title: "Folder name?", message: ""),
                               conversationID: id, asked: Date()),
            response: .value("   \n\t ")
        )
        check(whitespaceRecord.outcome == .cancelled && whitespaceRecord.answer == nil,
              "whitespace-only value response is recorded as cancelled, never answered")

        let message = chat.conversations.first(where: { $0.id == id })?.messages.last
        let recorded = message?.answeredQuestions ?? []
        check(approvals.questions.isEmpty && recorded.count == 5,
              "answered, cancelled, timed-out and stopped questions are recorded on the ChatMessage and cleared from open questions")
        if recorded.count == 5 {
            check(recorded[0].kind == .confirm && recorded[0].outcome == .allowed && recorded[0].title == "Search the web?"
                  && recorded[0].detail == "Pippa wants to look this up online."
                  && recorded[1].kind == .select && recorded[1].outcome == .answered && recorded[1].answer == "Lena from work",
                  "confirm and select answers keep their kind, title, detail and chosen value")
            check(recorded[2].outcome == .cancelled && recorded[2].answer == nil
                  && recorded[3].outcome == .cancelled && recorded[3].answer == nil
                  && recorded[4].outcome == .cancelled && recorded[4].answer == nil,
                  "cancel, timeout and stop all record cancelled and never allowed")
        }

        // A5: JSON round-trip and backwards compatibility with legacy ChatMessage JSON lacking `answeredQuestions`.
        if let message,
           let encoded = try? JSONEncoder().encode(message),
           let decoded = try? JSONDecoder().decode(ChatMessage.self, from: encoded) {
            check(decoded.answeredQuestions == message.answeredQuestions && decoded == message,
                  "ChatMessage with answeredQuestions survives JSONEncoder/JSONDecoder round-trip")
        } else {
            check(false, "ChatMessage with answeredQuestions survives JSONEncoder/JSONDecoder round-trip")
        }

        let legacyJSON = #"{"id":"6F1A0C2E-AAAA-4C55-9E0B-000000000002","role":"assistant","text":"Legacy answer","files":[],"steps":[],"cards":[],"receipts":[]}"#
        let legacy = try? JSONDecoder().decode(ChatMessage.self, from: Data(legacyJSON.utf8))
        check(legacy?.text == "Legacy answer" && legacy?.answeredQuestions == nil,
              "legacy ChatMessage JSON without answeredQuestions decodes cleanly")
    }
    /// A follow-up while Pippa answers (`ChatModel.steer`, `PiSession.steer`): only typed words in the conversation
    /// that answers, never with files, a review, a single question, an approved message or after a settings change.
    static func runSteerChecks(check: (Bool, String) -> Void) async {
        let session = PiSession.shared
        let approval = ShareApproval(destination: ShareDestination(key: "fixture", label: "Fixture", provider: "Fixture"),
                                     question: "Check", parts: [])
        check(PiSession.steerable(.typed("x"), handoff: false) && PiSession.steerable(.local("x"), handoff: false)
              && !PiSession.steerable(.typed("x"), handoff: true) && !PiSession.steerable(.approved(approval), handoff: false)
              && !PiSession.steerable(.approved(approval), handoff: true),
              "only the person's own words in their conversation take follow-ups; a single question or an approved message never")
        check(!session.canSteer, "no follow-up goes anywhere while no answer runs")
        // A client that never started stands in for the running Pi: Pi refuses, nothing counts as sent.
        let temporary = FileManager.default.temporaryDirectory
        let idle = PiRPCClient(configuration: PiRPCConfiguration(executable: URL(fileURLWithPath: "/usr/bin/false"), workingDirectory: temporary))
        session.allowSteering(idle, revision: session.settingsRevision - 1)
        check(!session.canSteer, "a turn admitted under older settings takes no follow-up")
        session.allowSteering(idle, revision: session.settingsRevision)
        check(session.canSteer, "a turn admitted under the current settings takes a follow-up")
        check(await session.steer("Nur diese Woche") == false, "a follow-up Pi does not accept reports nothing sent")

        let chat = ChatModel()
        let id = "steer-check"
        chat.replaceForSnapshot([Conversation(id: id, title: "Synthetic", updated: Date(),
                                              messages: [ChatMessage(role: .user, text: "Frage"), ChatMessage(role: .assistant, text: "")])],
                                current: id, answering: true)
        check(chat.canSteerHere, "while the answer here runs, typed words may go into it")
        chat.draft = "  Nur diese Woche  "
        chat.steer()
        let cleared = chat.draft.isEmpty
        for _ in 0..<100 where chat.draft.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        check(cleared && chat.draft == "Nur diese Woche", "a follow-up leaves the composer at once and comes back when Pi refuses it")
        chat.attachments = [URL(fileURLWithPath: "/synthetic/notice.txt")]
        check(!chat.canSteerHere, "with files attached nothing goes into the running answer")
        chat.attachments = []
        chat.review = ShareReview(plan: SharePlan(destination: approval.destination, question: "Check", candidates: [], rules: SourceSharing()),
                                  handoff: false, files: [])
        check(!chat.canSteerHere, "while a review is open nothing goes into the running answer")
        chat.review = nil
        chat.replaceForSnapshot([Conversation(id: id, title: "Synthetic", updated: Date(), messages: []),
                                 Conversation(id: "other", title: "Other", updated: Date(), messages: [])], current: id, answering: true)
        chat.currentID = "other"
        check(!chat.canSteerHere, "a follow-up never goes into an answer running in another conversation")
        chat.currentID = id
        check(chat.canSteerHere, "back in the answering conversation the follow-up may go again")
        session.settingsChanged()
        check(!session.canSteer && !chat.canSteerHere, "after the AI settings changed the running answer takes no follow-up")
        chat.draft = "Noch etwas"
        chat.steer()
        check(chat.draft == "Noch etwas", "a refused follow-up never leaves the composer")
        // Undelivered steering returned by Stop goes back into the answering conversation's composer, never another's.
        chat.replaceForSnapshot([Conversation(id: id, title: "Synthetic", updated: Date(), messages: []),
                                 Conversation(id: "other", title: "Other", updated: Date(), messages: [])], current: id, answering: false)
        chat.draft = ""
        chat.restoreDraft("Nur diese Woche", to: id)
        check(chat.draft == "Nur diese Woche", "undelivered steering cleared on Stop returns to the composer when empty")
        chat.currentID = "other"
        chat.draft = ""
        chat.restoreDraft("Für das erste Gespräch", to: id)
        check(chat.draft.isEmpty, "undelivered steering for another conversation never overwrites the visible composer")
        chat.select(id)
        check(chat.draft == "Für das erste Gespräch", "selecting the stopped conversation restores its preserved steering text")
        chat.replaceForSnapshot([], current: nil, answering: false)
    }

    /// A21: follow-ups typed in quick succession go to Pi as one message, and a follow-up cancels the answer's open
    /// question cards (never allows them), with a record that says why.
    static func runSteerBurstChecks(_ approvals: Approvals, check: (Bool, String) -> Void) async {
        let session = PiSession.shared, chat = ChatModel.shared
        let saved = (chat.conversations, chat.currentID), savedSender = chat.steerSender, savedDelay = ChatModel.steerCoalesceDelay
        let id = "steer-burst-check"
        chat.showSample([Conversation(id: id, title: "Synthetic", updated: Date(),
                                      messages: [ChatMessage(role: .user, text: "Frage"), ChatMessage(role: .assistant, text: "")])],
                        current: id, answering: true)
        let idle = PiRPCClient(configuration: PiRPCConfiguration(executable: URL(fileURLWithPath: "/usr/bin/false"),
                                                                 workingDirectory: FileManager.default.temporaryDirectory))
        session.allowSteering(idle, revision: session.settingsRevision)
        var sent: [String] = []
        chat.steerSender = { sent.append($0); return true }
        ChatModel.steerCoalesceDelay = .milliseconds(40)
        defer {
            chat.steerSender = savedSender
            ChatModel.steerCoalesceDelay = savedDelay
            session.settingsChanged()
            chat.showSample(saved.0, current: saved.1, answering: false)
        }
        func wait(until done: () -> Bool) async {
            for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
        }

        chat.draft = "first"
        chat.steer()
        check(chat.canSteerHere, "a follow-up on its way never locks out the next one")
        chat.draft = " second "
        chat.steer()
        check(chat.draft.isEmpty && sent.isEmpty, "rapid follow-ups leave the composer at once and wait together")
        await wait { !sent.isEmpty }
        try? await Task.sleep(for: .milliseconds(80))
        check(sent == ["first\nsecond"], "two follow-ups within the window reach Pi as one message")

        let card = Task {
            await approvals.ask(PiUIRequest(id: "steer-confirm", method: "confirm", title: "Send this mail?",
                                            message: "To: anna@example.test", options: ["Don’t Send", "Send"]))
        }
        for _ in 0..<5 { await Task.yield() }
        check(approvals.questions.map(\.id) == ["steer-confirm"] && approvals.questions.first?.conversationID == id,
              "the answer's confirmation card is open")
        chat.draft = "Doch nicht senden"
        chat.steer()
        let response = await card.value
        let record = chat.conversations.first { $0.id == id }?.messages.last?.answeredQuestions?.last
        check(response == .cancelled && approvals.questions.isEmpty && record?.id == "steer-confirm" && record?.outcome == .cancelled
              && record?.answer == T("Follow-up sent", table: "App") && record?.displayAnswer == T("Follow-up sent", table: "App"),
              "a follow-up cancels the open card (never allows it) and records it as cancelled for the follow-up")
        check(AnsweredQuestion(id: "plain", kind: .confirm, title: "x", outcome: .cancelled, answeredAt: Date()).displayAnswer
              == T("Cancelled", table: "Views"), "a plain cancellation still says Cancelled")
        await wait { sent.count == 2 }
        check(sent.last == "Doch nicht senden", "the follow-up still reaches Pi after the card was cancelled")

        chat.steerSender = { _ in false }
        chat.draft = "Abgelehnt"
        chat.steer()
        await wait { !chat.draft.isEmpty }
        check(chat.draft == "Abgelehnt", "a burst Pi refuses comes back into the composer")

        ChatModel.steerCoalesceDelay = .seconds(30)
        chat.steerSender = { sent.append($0); return true }
        chat.draft = "Noch nicht raus"
        chat.steer()
        chat.stop()
        check(chat.draft == "Noch nicht raus" && !sent.contains("Noch nicht raus"),
              "Stop returns follow-ups not yet sent to the composer, and they never reach a later answer")
        // Stop's own `PiSession.stop` cancels whichever native turn is active: it settles here, before the next check.
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// A20: a message written while another conversation answers waits there, comes back on Cancel, disappears with
    /// its conversation, goes out once the answer ends, and never goes out under AI settings changed meanwhile.
    static func runQueueChecks(check: (Bool, String) -> Void) async {
        let chat = ChatModel()
        let a = "queue-check-a", b = "queue-check-b"
        func conversations() -> [Conversation] {
            [Conversation(id: a, title: "A", updated: Date(), messages: [ChatMessage(role: .user, text: "Frage"), ChatMessage(role: .assistant, text: "")]),
             Conversation(id: b, title: "B", updated: Date(), messages: [])]
        }
        var started: [(ChatModel.QueuedSend, PiSession.Outgoing)] = []
        chat.startQueuedForCheck = { queued, outgoing, _ in started.append((queued, outgoing)) }
        func answeringInA(showing current: String?) {
            chat.replaceForSnapshot(conversations(), current: a, answering: true)
            chat.currentID = current
            chat.draft = ""; chat.attachments = []; chat.problem = nil
        }

        answeringInA(showing: b)
        chat.draft = "  Und morgen?  "
        check(chat.canQueueHere && !chat.canSteerHere, "while A answers, B may queue a message (and never steer A)")
        chat.send()
        check(chat.queuedSends[b]?.text == "Und morgen?" && chat.queuedHere?.conversationID == b && chat.draft.isEmpty
              && chat.queuedSends[b]?.settingsRevision == PiSession.shared.settingsRevision,
              "Send in B while A answers queues the message under the current settings and clears the composer")
        chat.draft = "Noch eins"
        check(!chat.canQueueHere, "one waiting message per conversation")
        chat.draft = ""
        chat.cancelQueued(in: b)
        check(chat.queuedSends.isEmpty && chat.draft == "Und morgen?", "Cancel takes the waiting message back into the composer")

        chat.send()
        chat.delete(b)
        chat.replaceForSnapshot(conversations(), current: a, answering: false)
        chat.drainNextQueued()
        check(chat.queuedSends.isEmpty && started.isEmpty, "a deleted conversation's waiting message never goes out")

        answeringInA(showing: nil)
        chat.draft = "Neues Gespräch"
        let before = chat.conversations.count
        chat.send()
        let fresh = chat.currentID
        check(chat.conversations.count == before + 1 && fresh != nil && fresh != a && chat.queuedSends[fresh ?? ""] != nil,
              "a message queued from an empty composer gets its own conversation in the sidebar")
        if let fresh { chat.cancelQueued(in: fresh); chat.delete(fresh) }

        answeringInA(showing: b)
        chat.draft = "Und morgen?"
        chat.send()
        chat.drainNextQueued()
        check(started.isEmpty && chat.queuedSends[b] != nil, "nothing waiting goes out while the other answer still runs")
        chat.replaceForSnapshot(conversations(), current: a, answering: false)
        chat.drainNextQueued()
        check(started.count == 1 && started.first?.0.conversationID == b && started.first?.0.text == "Und morgen?"
              && chat.queuedSends.isEmpty, "once A has finished, B's waiting message goes out into B")

        started = []
        answeringInA(showing: b)
        chat.draft = "Unter alten Einstellungen"
        chat.send()
        PiSession.shared.settingsChanged()
        chat.replaceForSnapshot(conversations(), current: b, answering: false)
        chat.draft = ""; chat.problem = nil
        chat.drainNextQueued()
        let changed = T("The AI settings changed while your message waited. Check it and send it again.", table: "App")
        check(started.isEmpty && chat.queuedSends.isEmpty && chat.draft == "Unter alten Einstellungen" && chat.problem == changed,
              "after the AI settings changed, a waiting message never goes out: it comes back with a sentence")

        answeringInA(showing: b)
        chat.draft = "Im Hintergrund"
        chat.send()
        PiSession.shared.settingsChanged()
        chat.replaceForSnapshot(conversations(), current: a, answering: false)
        chat.problem = nil
        chat.drainNextQueued()
        check(started.isEmpty && chat.problem == nil, "a changed waiting message in another conversation says nothing here")
        chat.select(b)
        check(chat.draft == "Im Hintergrund" && chat.problem == changed, "opening its conversation shows the message and why it came back")

        // Changing sharing rules or capabilities without bumping settingsRevision still blocks auto-send (R3).
        started = []
        answeringInA(showing: b)
        chat.draft = "Mit geänderten Regeln"
        chat.send()
        var altered = SettingsModel.shared.inferenceSettings
        altered.sharing.mail = altered.sharing.mail == .localOnly ? .ask : .localOnly
        chat.replaceForSnapshot(conversations(), current: b, answering: false)
        chat.draft = ""; chat.problem = nil
        chat.drainNextQueued(currentSettings: altered)
        check(started.isEmpty && chat.queuedSends.isEmpty && chat.draft == "Mit geänderten Regeln" && chat.problem == changed,
              "changed sharing rules or capabilities without a settings revision bump still block a queued message")

        // Restoring an undelivered follow-up never drops text typed meanwhile (R4).
        chat.draft = "Neuer Satz"
        chat.restoreDraft("Alter Nachtrag", to: b)
        check(chat.draft == "Alter Nachtrag\n\nNeuer Satz",
              "restoring an undelivered follow-up preserves newer text already in the composer")
        chat.replaceForSnapshot([], current: nil, answering: false)
    }

    /// A19: One PDF beside a running answer: its own turn never replaces or cancels the answer's, in the MCP host or in
    /// the chat, and both finish on their own.
    static func runPDFBesideAnswerChecks(check: (Bool, String) -> Void) async {
        let savedBase = PippaMCPService.baseHost
        // The demo host has no job journal: the conversion fails at once, without touching a real file.
        PippaMCPService.baseHost = { .demo() }
        defer { PippaMCPService.baseHost = savedBase }
        let answer = PippaMCPTurn()
        PippaMCPService.currentHost.turns.begin(answer)
        let fresh = !answer.writes.snapshot.cancelled
        let result = await PippaMCPService.makePDF([URL(fileURLWithPath: "/synthetic/Scan.pdf")])
        check(fresh && PippaMCPService.currentHost.turns.active === answer && !answer.writes.snapshot.cancelled && result.failed,
              "One PDF never replaces or cancels the running answer's turn and writes")
        PippaMCPService.currentHost.turns.end(answer)
        check(PippaMCPService.currentHost.turns.active == nil, "the answer's turn still ends on its own")

        let chat = ChatModel()
        let a = "pdf-check-a", b = "pdf-check-b"
        chat.replaceForSnapshot([Conversation(id: a, title: "A", updated: Date(), messages: [ChatMessage(role: .user, text: "Frage"), ChatMessage(role: .assistant, text: "")]),
                                 Conversation(id: b, title: "B", updated: Date(), messages: [])], current: a, answering: true)
        chat.currentID = b
        chat.attachments = [URL(fileURLWithPath: "/synthetic/Scan.pdf")]
        chat.makePDF()
        check(chat.isMakingPDF && chat.pdfConversationID == b && chat.isAnswering && chat.answeringID == a && chat.attachments.isEmpty,
              "One PDF starts in B while A answers, without touching A's answer")
        for _ in 0..<300 where chat.isMakingPDF { try? await Task.sleep(for: .milliseconds(10)) }
        let reply = chat.conversations.first { $0.id == b }?.messages.last
        check(!chat.isMakingPDF && chat.isAnswering && chat.answeringID == a && reply?.role == .assistant && reply?.error != nil,
              "the PDF finishes on its own while A still answers")

        chat.currentID = a
        chat.attachments = [URL(fileURLWithPath: "/synthetic/Scan.pdf")]
        let count = chat.conversations.count
        chat.makePDF()
        check(chat.pdfConversationID != a && chat.conversations.count == count + 1
              && chat.conversations.first { $0.id == a }?.messages.count == 2,
              "One PDF from the answering conversation goes into a new one, so the answer's words stay its own")
        chat.stopPDF()
        let stopped = chat.conversations.first { $0.id == chat.currentID }?.messages.last
        check(!chat.isMakingPDF && stopped?.stopped == true && chat.isAnswering, "Stop ends the PDF at once and leaves the answer running")
        // The cancelled job settles under the demo host before the real one comes back.
        try? await Task.sleep(for: .milliseconds(200))
        chat.replaceForSnapshot([], current: nil, answering: false)
    }

    /// Undo for a whole answer from the chat (`ChatModel.undoRun`), on a journal in a temporary folder: the next
    /// question tells the model what was taken back, and the receipt wording follows what is still undoable.
    static func runUndoChecks(check: (Bool, String) -> Void) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-run-undo-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let journal = try? Executor(baseDirectory: folder) else { return check(false, "a run journal opens in a temporary folder") }
        let original = PippaMCPService.baseHost
        PippaMCPService.baseHost = {
            var host = PippaMCPHost.demo()
            host.reminderJournal = journal
            host.runRecipes["check.kind"] = { _ in .undone }
            return host
        }
        defer { PippaMCPService.baseHost = original }
        let run = UUID()
        let rows = (try? await journal.planRunActions(run: run, [RunActionDraft(tool: "move_files", object: RunObject(kind: "check.kind", fields: [:]),
                                                                                label: "Letter.pdf")], dispatched: true)) ?? []
        _ = try? await journal.completeRunActions(rows.map { RunActionResult(id: $0.id, verified: true) })
        let chat = ChatModel.shared, saved = (chat.conversations, chat.currentID)
        let id = "run-undo-check"
        var answer = ChatMessage(role: .assistant, text: "Moved.")
        answer.run = RunSummary(run: run, changes: 1, checked: 1, undoable: 1)
        chat.showSample([Conversation(id: id, title: "Synthetic", updated: Date(), messages: [answer])], current: id, answering: false)
        chat.undoRun(in: answer.id)
        for _ in 0..<200 where chat.undoneNotes[id] == nil { try? await Task.sleep(for: .milliseconds(10)) }
        let notes = chat.undoneNotes[id] ?? []
        let prompt = ChatModel.prompt("And now?", files: [], frontApp: nil, undone: notes)
        check(notes == ["Letter.pdf"] && prompt.contains("Letter.pdf") && chat.conversations.first?.messages.first?.run?.undone == 1,
              "after Undo of a whole answer, the next question tells the model what was taken back")
        chat.showSample(saved.0, current: saved.1, answering: false)

        let partly = RunSummary(run: run, changes: 3, checked: 3, undoable: 2, undone: 1)
        check(RunReceiptRow.title(partly).hasPrefix(RunReceiptRow.title(RunSummary(run: run, changes: 3, checked: 3, undoable: 3))),
              "after one receipt's Undo the run receipt still counts the changes that are still active")
        check(RunReceiptRow.title(RunSummary(run: run, changes: 3, checked: 3, undone: 3)) == T("%lld changes undone", table: "App", 3),
              "with nothing left to undo the run receipt reads as the outcome of Undo")
        check(ReceiptRow.title(PippaMCPWriteReceipt(action: "mailDraft", outcome: "unclear", name: "Re: Fixture"))
              == T("Unclear, please check", table: "App"), "an unclear Mail draft never reads as no draft")
    }

    /// Irreversible and external tools ask on the same question card (`PippaMCPService.configured` → `confirmAction`),
    /// with a check-only tool: only the button dispatches, Stop and a late press do not, `--ask` never asks.
    static func actionCardChecks(_ approvals: Approvals, check expect: (Bool, String) -> Void) async {
        final class Runs: @unchecked Sendable {
            private let lock = NSLock(); private var count = 0
            func add() { lock.withLock { count += 1 } }
            var value: Int { lock.withLock { count } }
        }
        let runs = Runs()
        func host(asksForAccess: Bool) -> (PippaMCPTools, PippaMCPTurns, PippaMCPTurn) {
            var host = PippaMCPService.configured(.demo(), asksForAccess: asksForAccess)
            host.turns = PippaMCPTurns()
            host.extraTools = [PippaMCPHostTool(name: "check_send", actionClass: .external, describe: { arguments in
                PippaMCPConfirmation(tool: "check_send", actionClass: .external, title: "Send this message?",
                                     recipient: arguments["to"] as? String, content: arguments["text"] as? String ?? "")
            }, run: { _ in runs.add(); return PippaMCPToolResult(text: #"{"done":true}"#, isError: false) })]
            let turn = PippaMCPTurn()
            host.turns.begin(turn)
            return (PippaMCPTools(host: host), host.turns, turn)
        }
        struct Outcome: Sendable { let done: Bool?; let dispatched: Bool? }
        nonisolated func send(_ tools: PippaMCPTools) async -> Outcome {
            let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": [
                "name": "check_send", "arguments": ["to": "anna@example.test", "text": "Hallo Anna, bis morgen."]]])
            let reply = await tools.handle(body).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let text = (((reply?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
            return Outcome(done: json["done"] as? Bool, dispatched: json["dispatched"] as? Bool)
        }
        func question() async -> Approvals.Question? {
            for _ in 0..<200 {
                if let first = approvals.questions.first { return first }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return nil
        }
        let (tools, turns, turn) = host(asksForAccess: true)
        let allowed = Task { await send(tools) }
        let card = await question()
        expect(card?.request.method == "confirm" && card?.request.title == "Send this message?"
               && card?.request.message == "anna@example.test\n\nHallo Anna, bis morgen.", "an external tool asks on the question card with recipient and exact text")
        expect(runs.value == 0, "nothing runs while the card is open")
        if let card { approvals.answer(card.id, .confirmed(true)) }
        expect(await allowed.value.done == true && runs.value == 1, "the button's yes dispatches the tool once")

        let stopped = Task { await send(tools) }
        let open = await question()
        // Stop: the answer ends, its questions go with it; the button pressed afterwards finds nothing.
        turns.end(turn)
        approvals.cancelAll()
        let result = await stopped.value
        if let open { approvals.answer(open.id, .confirmed(true)) }
        expect(open != nil && result.dispatched == false && runs.value == 1, "Stop while the card is open: not dispatched, a late yes does nothing")

        let (headless, _, _) = host(asksForAccess: false)
        let declined = await send(headless)
        expect(approvals.questions.isEmpty && declined.dispatched == false && runs.value == 1, "Pippa --ask answers no without a card")
    }
}

/// Also run by `Pippa --check-approvals`: the conversation files as the store reads them at launch, in a temporary folder.
@MainActor
enum ConversationStoreChecks {
    static func run() -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print("\(ok ? "PASS" : "FAIL") \(name)")
            if !ok { failures += 1 }
        }
        func mailSource(_ id: String, arguments: String = #"{"message_id":"old@example.test"}"#) -> ChatSource? {
            let result = #"{"data":{"subject":"Repeated subject","messageID":"\#(id)"}}"#
            return SourceLog.source(tool: "mcp__pippa__mail_read", arguments: arguments, result: result)
        }
        // One receipt for a run of mail moves, in plain words; receipts saved before mail moves still load.
        do {
            let german = Bundle.module.preferredLocalizations.first == "de"
            let moved = RunReceiptRow.title(RunSummary(run: UUID(), changes: 18, checked: 18, undoable: 18, mailMoves: 18))
            let mixed = RunReceiptRow.title(RunSummary(run: UUID(), changes: 3, checked: 3, undoable: 3, mailMoves: 2))
            let unclearOnly = RunReceiptRow.title(RunSummary(run: UUID(), changes: 1, unclear: 1, mailMoves: 1))
            let unclearSome = RunReceiptRow.title(RunSummary(run: UUID(), changes: 18, checked: 17, unclear: 1, undoable: 17, mailMoves: 18))
            check(unclearOnly == (german ? "1 Mail unklar, bitte nachsehen" : "1 mail unclear, please check")
                  && unclearSome == (german ? "17 Mails verschoben und geprüft, 1 unklar, bitte nachsehen" : "17 mails moved and checked, 1 unclear, please check"),
                  "a mail move receipt calls only mails read back in the target moved; unclear ones are counted apart")
            let old = try? JSONDecoder().decode(RunSummary.self, from: Data(#"{"run":"6F1A0C2E-AAAA-4C55-9E0B-000000000001","changes":2,"checked":2,"unclear":0,"undoable":2,"undone":0,"left":0,"failed":0}"#.utf8))
            check(moved == (german ? "18 Mails verschoben, alle geprüft" : "18 mails moved, all checked")
                  && mixed == (german ? "3 Änderungen, alle geprüft" : "3 changes, all checked") && old?.mailMoves == nil && old?.changes == 2,
                  "a run of mail moves reads \"18 mails moved, all checked\"; mixed runs count changes; older receipts load")
        }
        // "Writing…" follows what comes in right now, not whether the answer has text already.
        let events: [PiRPCEvent] = [.textDelta("\n\n"), .thinkingDelta("hm"), .textDelta("Ich schaue nach."),
                                    .assistantEnded(text: "", stopReason: "toolUse", error: nil), .thinkingDelta("weiter"),
                                    .toolStarted(id: "1", name: "read", arguments: "{}"), .textDelta("Fertig"), .textDelta(" "),
                                    .thinkingDelta("noch etwas")]
        var writing = false
        let states = events.map { event in writing = ChatModel.writing(writing, after: event); return writing }
        check(states == [false, false, true, false, false, false, true, true, false],
              "Writing shows only while words come in: not for opening line breaks, not while thinking or reading after a first sentence")
        // The island's chain ends on her thinking or on the answer as it is written, never on both, and never while a step runs.
        var working = ChatMessage(role: .assistant, text: "**Die Frist** endet\n\nam 19. November.", thinking: "Erst  lesen,\ndann rechnen.")
        let thinkingNow = IslandChain.now(message: working, writing: false), writingNow = IslandChain.now(message: working, writing: true)
        working.steps = [ChatStep(id: "1", label: "Lese", done: false)]
        let stepNow = IslandChain.now(message: working, writing: true)
        check(thinkingNow.writing == false && thinkingNow.tail == nil
              && writingNow.writing && writingNow.tail == "Die Frist endet am 19. November."
              && stepNow.writing == false && stepNow.tail == nil,
              "the island's chain ends on \"Thinking…\" without her notes, or on the answer written so far as plain text")
        // The chain's height: as steps run and end one after another, it only grows, up to four rows, then stays.
        do {
            var heights: [Int] = []
            for steps in 1...8 {
                for nowRow in [false, true] {
                    let shown = IslandChain.shownSteps(steps, nowRow: nowRow)
                    heights.append((steps > shown ? 1 : 0) + shown + (nowRow ? 1 : 0))
                }
            }
            check(zip(heights, heights.dropFirst()).allSatisfy { $0 <= $1 } && heights.max() == IslandChain.rows && heights.suffix(10).allSatisfy { $0 == IslandChain.rows },
                  "the island's step chain grows to four rows and then keeps its height while steps run and end")
        }
        // A question in the island goes on with the latest conversation while it is recent; an old one or "New
        // conversation" starts fresh.
        do {
            let chat = ChatModel.shared, island = Island.shared
            let saved = (chat.conversations, chat.currentID)
            let message = ChatMessage(role: .user, text: "Frage")
            chat.showSample([Conversation(id: "old", title: "Alt", updated: Date().addingTimeInterval(-3600), messages: [message]),
                             Conversation(id: "new", title: "Neu", updated: Date().addingTimeInterval(-120), messages: [message])],
                            current: nil, answering: false)
            let recent = island.followUp?.id
            island.startsFresh = true
            let fresh = island.followUp
            island.startsFresh = false
            chat.showSample([Conversation(id: "old", title: "Alt", updated: Date().addingTimeInterval(-3600), messages: [message])],
                            current: nil, answering: false)
            let stale = island.followUp
            // Picked in the island (its row or ↑): goes on with it however old; ⌘N and closing the island drop it.
            island.continuing = "old"
            let picked = island.followUp?.id
            island.startsFresh = true
            let pickedThenFresh = island.followUp
            island.startsFresh = false
            // A picked conversation deleted meanwhile: a new one, never another.
            island.continuing = "gone"
            let gone = island.followUp
            island.continuing = nil
            // The ten minutes count from the opening: opened eight minutes after its last message, it stays a follow-up
            // although that message is now eleven minutes old; opened after twelve, it is new.
            chat.showSample([Conversation(id: "edge", title: "Rand", updated: Date().addingTimeInterval(-660), messages: [message])],
                            current: nil, answering: false)
            island.openedAt = Date().addingTimeInterval(-180)
            let keptWhileOpen = island.followUp?.id
            island.openedAt = Date().addingTimeInterval(60)
            let openedLate = island.followUp
            island.openedAt = nil
            chat.showSample(saved.0, current: saved.1, answering: false)
            check(gone == nil && keptWhileOpen == "edge" && openedLate == nil,
                  "the follow-up rule holds for the whole opening and never falls back to another conversation")
            check(recent == "new" && fresh == nil && stale == nil,
                  "a question in the island follows up the conversation of the last ten minutes; older or after New Conversation it starts a new one")
            check(picked == "old" && pickedThenFresh == nil,
                  "a conversation picked in the island is followed up however old it is, until New Conversation")
        }
        let strokes = (0..<3).map { Scribble.stroke($0, at: 12.5) }
        check(strokes.allSatisfy { $0.count == 91 && $0.allSatisfy { abs($0.x) <= 0.9 && abs($0.y) <= 0.9 } }
              && Scribble.stroke(0, at: 12.5) != Scribble.stroke(0, at: 13),
              "Pippa's handwriting stays inside her mark's square and keeps moving")
        let reading = StepLabel.text(tool: "read", arguments: #"{"path":"/Users/me/Documents/Thesis.docx"}"#)
        check(StepLabel.progress(reading, part: 3, of: 10, merging: false) == T("%@ · Part %lld of %lld", table: "App", reading, 3, 10)
              && StepLabel.progress(reading, part: 3, of: 10, merging: false).hasSuffix("Thesis.docx · " + (T("Open", table: "App") == "Öffnen" ? "Teil 3 von 10" : "Part 3 of 10"))
              && StepLabel.progress(reading, part: 1, of: 2, merging: true) != StepLabel.progress(reading, part: 1, of: 2, merging: false),
              "a long document's step says which part is being read, in the app's language")
        // A tool the model invented is never shown by its raw name; a web address is a page, not a file.
        let unknownTool = StepLabel.text(tool: "web_fetch_content", arguments: "{}")
        let webAddress = StepLabel.text(tool: "mcp__pippa__read_document", arguments: #"{"path":"https://x.de/a.pdf"}"#)
        let localFile = StepLabel.text(tool: "read_document", arguments: #"{"path":"/Users/a/b.pdf"}"#)
        check(unknownTool == T("Using a tool", table: "App") && !unknownTool.contains("web_fetch_content")
              && webAddress == T("Reading a web page", table: "App")
              && localFile == T("Reading %@", table: "App", "b.pdf"),
              "an unknown tool's step says only that a tool is used; a web address reads a page, a path reads its file")
        // Live steps name what they work on, short, and fall back to the plain words without it.
        do {
            func label(_ tool: String, _ arguments: String) -> String { StepLabel.text(tool: tool, arguments: arguments) }
            let named: [(String, String, String)] = [
                ("web_search", #"{"queries":["Öffnungszeiten Bürgeramt Köln"]}"#, T("Searching the web for “%@”", table: "App", "Öffnungszeiten Bürgeramt Köln")),
                ("web_search", #"{"query":"Wetter Berlin"}"#, T("Searching the web for “%@”", table: "App", "Wetter Berlin")),
                ("fetch_content", #"{"url":"https://www.zeit.de/politik/a"}"#, T("Reading a page on %@", table: "App", "zeit.de")),
                ("fetch_content", #"{"urls":["https://example.org/x","https://b.test"]}"#, T("Reading a page on %@", table: "App", "example.org")),
                ("mcp__pippa__browse", #"{"action":"open","url":"https://www.bahn.de/"}"#, T("Browsing %@", table: "App", "bahn.de")),
                ("mcp__pippa__mail_search", #"{"query":"Stadtwerke"}"#, T("Searching Mail for “%@”", table: "App", "Stadtwerke")),
                ("mcp__pippa__mail_move", #"{"refs":["m1"],"to":"Work/Invoices","dry_run":true}"#, T("Planning mail moves to %@", table: "App", "Invoices")),
                ("mcp__pippa__mail_move", #"{"plan":"p1","dry_run":true}"#, T("Planning mail moves", table: "App")),
                ("mcp__pippa__mail_move", #"{"refs":["m1"],"to":"Invoices"}"#, T("Moving mails to %@", table: "App", "Invoices")),
                ("mcp__pippa__mail_folders", #"{"account":"Work"}"#, T("Reading the Mail folders of %@", table: "App", "Work")),
                ("mcp__pippa__mail_draft", #"{"subject":"Termin am Freitag","to":"a@example.test"}"#, T("Writing a Mail draft: %@", table: "App", "Termin am Freitag")),
                ("mcp__pippa__mail_draft", #"{"to":"a@example.test"}"#, T("Writing a Mail draft to %@", table: "App", "a@example.test")),
                ("mcp__pippa__calendar_add", #"{"title":"Zahnarzt","date":"2026-11-27"}"#, T("Adding “%@” to Calendar", table: "App", "Zahnarzt")),
                ("mcp__pippa__reminder_add", #"{"title":"Miete überweisen"}"#, T("Adding the reminder “%@”", table: "App", "Miete überweisen")),
                ("mcp__pippa__photos_search", #"{"query":"Strand"}"#, T("Searching Photos for “%@”", table: "App", "Strand")),
            ]
            let wrong = named.filter { label($0.0, $0.1) != $0.2 }.map { "\($0.0) \($0.1) → \(label($0.0, $0.1))" }
            check(wrong.isEmpty, "a live step names its search, site, folder, subject or title\(wrong.isEmpty ? "" : ": " + wrong.joined(separator: "; "))")
            let plain: [(String, String)] = [
                ("web_search", T("Searching the web", table: "App")), ("fetch_content", T("Reading a web page", table: "App")),
                ("browse", T("Browsing a web page", table: "App")), ("mail_search", T("Reading Mail", table: "App")),
                ("mail_move", T("Moving mails", table: "App")), ("mail_folders", T("Reading Mail", table: "App")),
                ("mail_draft", T("Writing a Mail draft", table: "App")), ("calendar_add", T("Adding to Calendar", table: "App")),
                ("reminder_add", T("Adding a reminder", table: "App")), ("photos_search", T("Searching Photos", table: "App")),
            ]
            let empty = [#"{}"#, #"{"query":"  ","queries":[],"url":"","title":"","subject":"","to":"","account":""}"#, "not json"]
            let unplain = plain.filter { tool, words in empty.contains { label(tool, $0) != words } }.map(\.0)
            check(unplain.isEmpty, "without arguments a live step keeps its plain words\(unplain.isEmpty ? "" : ": " + unplain.joined(separator: ", "))")
            let long = label("web_search", #"{"query":"Wie lange ist die Kündigungsfrist für meinen Mietvertrag in Köln eigentlich"}"#)
            let browseOther = label("browse", #"{"action":"snapshot","url":"https://www.bahn.de/"}"#)
            check(long.count < T("Searching the web for “%@”", table: "App", "").count + 38 && long.contains("…") && !long.contains("eigentlich")
                  && browseOther == T("Browsing a web page", table: "App") && StepLabel.host(of: "no address") == "",
                  "a long detail is cut short with an ellipsis; browser steps other than open and non-addresses keep the plain words")
        }
        let shipped = (PippaPiLaunch.tools + Array(PippaActionClasses.table.keys)).filter { !$0.contains("*") }
        let unlabelled = shipped.filter { StepLabel.text(tool: $0, arguments: "{}") == T("Using a tool", table: "App") }
        check(!shipped.isEmpty && unlabelled.isEmpty,
              "every tool Pippa ships keeps its own plain-words step label\(unlabelled.isEmpty ? "" : ": " + unlabelled.joined(separator: ", "))")
        let firstMail = mailSource("old@example.test"), secondMail = mailSource("new@example.test")
        let accountMail = SourceLog.source(tool: "mail_read", arguments: #"{"mail_ref":"m123456789012"}"#,
                                          result: #"{"data":{"subject":"Repeated subject","messageID":"old@example.test","account":"Work","bodyTruncated":true}}"#)
        check(accountMail?.location.isEmpty == true && accountMail?.name.contains("Work") == true,
              "an account-specific Mail source never opens an account-blind message link")
        check(SourceLog.detail(result: #"{"data":{"bodyTruncated":true}}"#, mail: true) == T("Beginning only", table: "App"),
              "a clipped email body is identified as a partial read")
        do {
            let chat = ChatModel.shared, saved = (ChatModel.shared.conversations, ChatModel.shared.currentID)
            let id = "mail-partial-check"
            chat.showSample([Conversation(id: id, title: "Synthetic", updated: Date(), messages: [ChatMessage(role: .assistant, text: "")])],
                            current: id, answering: true)
            chat.apply(.toolEnded(id: "synthetic-mail", name: "mcp__pippa__mail_read", isError: false,
                                  result: #"{"data":{"subject":"Synthetic mail","account":"Work","bodyTruncated":true}}"#), in: id)
            check(chat.conversations.first?.messages.last?.sources?.first?.detail == T("Beginning only", table: "App"),
                  "a completed Mail tool updates the actual chat source with its partial-read disclosure")
            chat.apply(.toolEnded(id: "synthetic-mail-metadata", name: "mcp__pippa__mail_read", isError: false,
                                  result: #"{"data":{"subject":"Synthetic mail","account":"Work","bodyTruncated":false,"truncated":true}}"#), in: id)
            check(chat.conversations.first?.messages.last?.sources?.first?.detail == nil,
                  "an attachment-list limit never claims that the email body was clipped")
            chat.apply(.toolEnded(id: "synthetic-mail-whole", name: "mcp__pippa__mail_read", isError: false,
                                  result: #"{"data":{"subject":"Synthetic mail","account":"Work","bodyTruncated":false}}"#), in: id)
            check(chat.conversations.first?.messages.last?.sources?.first?.detail == nil,
                  "a complete email is not labeled as a whole document")
            // A codemode script: one step in plain words; the calls it makes add no steps but still count as read.
            chat.apply(.toolStarted(id: "script", name: "codemode", arguments: #"{"code":"…"}"#), in: id)
            for n in 1...3 {
                chat.apply(.toolStarted(id: "script/\(n)", name: "mcp__pippa__mail_search", arguments: "{}", parent: "script"), in: id)
                chat.apply(.toolEnded(id: "script/\(n)", name: "mcp__pippa__mail_search", isError: false, result: "{}", parent: "script"), in: id)
            }
            chat.apply(.toolEnded(id: "script", name: "codemode", isError: false, result: "Script completed"), in: id)
            let scripted = chat.conversations.first?.messages.last
            check(scripted?.steps.map(\.label) == [T("Working through the list", table: "App")] && scripted?.steps.first?.done == true
                  && scripted?.provenance?.contains(.mail) == true,
                  "a script is one plain step, not one per call it makes; what its calls read still counts")
            // A follow-up the person sent while she works (`ChatModel.steer`): the reply so far ends, the follow-up
            // is their message, and everything after it goes into a new reply.
            chat.apply(.toolStarted(id: "open-step", name: "mcp__pippa__calendar_read", arguments: "{}"), in: id)
            chat.apply(.textDelta("Ich schaue nach."), in: id)
            let before = chat.conversations.first?.messages.count ?? 0
            chat.apply(.userMessage("Nur bis 19. November 2026, bitte"), in: id)
            let afterFollowUp = chat.conversations.first?.messages ?? []
            chat.apply(.textDelta("Bis zum 19. November 2026 ist nichts eingetragen."), in: id)
            chat.apply(.toolStarted(id: "after", name: "mcp__pippa__reminders_read", arguments: "{}"), in: id)
            chat.apply(.toolEnded(id: "after", name: "mcp__pippa__reminders_read", isError: false, result: "{}"), in: id)
            let messages = chat.conversations.first?.messages ?? []
            let followUp = messages.count >= 2 ? messages[messages.count - 2] : nil
            let earlier = messages.count >= 3 ? messages[messages.count - 3] : nil
            check(afterFollowUp.count == before + 2 && followUp?.role == .user && followUp?.text == "Nur bis 19. November 2026, bitte"
                  && earlier?.role == .assistant && earlier?.text == "Ich schaue nach." && earlier?.steps.allSatisfy(\.done) == true,
                  "a follow-up shows as the person's message after the reply so far, whose open steps end there")
            check(messages.last?.role == .assistant && messages.last?.text == "Bis zum 19. November 2026 ist nichts eingetragen."
                  && messages.last?.steps.map(\.id) == ["after"] && messages.last?.steps.first?.done == true
                  && followUp?.steps.isEmpty == true,
                  "what Pi writes and does after a follow-up goes into a new reply, never into the person's message")
            check(chat.evidence.supported(in: "19. November 2026").isEmpty == false,
                  "a date the person named in a follow-up counts as said, not as unsupported")
            // A reply that had not begun leaves no empty bubble behind.
            chat.showSample([Conversation(id: id, title: "Synthetic", updated: Date(),
                                          messages: [ChatMessage(role: .user, text: "Frage"), ChatMessage(role: .assistant, text: "")])],
                            current: id, answering: true)
            chat.apply(.userMessage("Kürzer, bitte"), in: id)
            check(chat.conversations.first?.messages.map(\.role) == [.user, .user, .assistant]
                  && chat.conversations.first?.messages.last?.text == "",
                  "a follow-up before the reply began replaces the empty reply instead of leaving it behind")
            chat.showSample(saved.0, current: saved.1, answering: false)
        }
        check(firstMail?.kind == .mail && firstMail?.name == "Repeated subject" && firstMail?.location == "message://%3Cold%40example%2Etest%3E",
              "a mail read by id gets its title and openable identity from the result")
        check(firstMail != nil && secondMail != nil && Set([firstMail, secondMail]).count == 2,
              "two read mails with the same subject remain distinct sources")
        check(mailSource("old@example.test", arguments: #"{"subject":"Wrong subject"}"#)?.name == "Repeated subject",
              "the mail result supplies the source title, never a look-alike subject in the arguments")
        check(SourceLog.source(tool: "mail_read", arguments: #"{"subject":"Not read yet"}"#) == nil
              && SourceLog.source(tool: "mail_read", arguments: "{}", result: #"{"status":"not_found"}"#) == nil,
              "a mail call without a successful read result is no source")
        check(mailSource("invalid id")?.location.isEmpty == true,
              "an invalid message identity cannot become an openable URL")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-store-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ConversationStore(folder: root.appendingPathComponent("conversations", isDirectory: true)).load()
        check(first.conversations.isEmpty && first.unreadable == 0, "a first run without a folder is an empty history, not a failure")

        let folder = root.appendingPathComponent("conversations", isDirectory: true)
        let store = ConversationStore(folder: folder)
        store.save(Conversation(id: "kept", title: "Kept", updated: Date(), messages: []))
        store.flush()
        try? Data("{ not a conversation".utf8).write(to: folder.appendingPathComponent("broken.json"))
        let mixed = store.load()
        check(mixed.conversations.map(\.id) == ["kept"] && mixed.unreadable == 1, "an unreadable file is counted, and the readable ones still load")

        let file = root.appendingPathComponent("not-a-folder")
        try? Data().write(to: file)
        let blocked = ConversationStore(folder: file).load()
        check(blocked.conversations.isEmpty && blocked.unreadable == 1, "a folder that cannot be read is a failure, not an empty history")

        print(failures == 0 ? "conversation store: all checks passed" : "conversation store: \(failures) failed")
        return failures == 0 ? 0 : 1
    }
}
