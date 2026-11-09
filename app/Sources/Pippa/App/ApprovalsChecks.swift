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

        print(failures == 0 ? "approvals: all checks passed" : "approvals: \(failures) failed")
        return failures == 0 ? 0 : 1
    }
}
