import Foundation
import PiRPC

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

        failures += Int(await HeadlessAskChecks.run())

        print(failures == 0 ? "approvals: all checks passed" : "approvals: \(failures) failed")
        return failures == 0 ? 0 : 1
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
        let long = IslandChain.tail(String(repeating: "Wort ", count: 60) + "Ende", plain: false) ?? ""
        check(thinkingNow.writing == false && thinkingNow.tail == "Erst lesen, dann rechnen."
              && writingNow.writing && writingNow.tail == "Die Frist endet am 19. November."
              && stepNow.writing == false && stepNow.tail == nil
              && long.hasPrefix("…Wort ") && long.hasSuffix("Ende") && long.count <= 151,
              "the island's chain ends on the thinking or the answer written so far, as plain flowing text cut at a word")
        let strokes = (0..<3).map { Scribble.stroke($0, at: 12.5) }
        check(strokes.allSatisfy { $0.count == 91 && $0.allSatisfy { abs($0.x) <= 0.9 && abs($0.y) <= 0.9 } }
              && Scribble.stroke(0, at: 12.5) != Scribble.stroke(0, at: 13),
              "Pippa's handwriting stays inside her mark's square and keeps moving")
        let reading = StepLabel.text(tool: "read", arguments: #"{"path":"/Users/me/Documents/Thesis.docx"}"#)
        check(StepLabel.progress(reading, part: 3, of: 10, merging: false) == T("%@ · Part %lld of %lld", table: "App", reading, 3, 10)
              && StepLabel.progress(reading, part: 3, of: 10, merging: false).hasSuffix("Thesis.docx · " + (T("Open", table: "App") == "Öffnen" ? "Teil 3 von 10" : "Part 3 of 10"))
              && StepLabel.progress(reading, part: 1, of: 2, merging: true) != StepLabel.progress(reading, part: 1, of: 2, merging: false),
              "a long document's step says which part is being read, in the app's language")
        let firstMail = mailSource("old@example.test"), secondMail = mailSource("new@example.test")
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
