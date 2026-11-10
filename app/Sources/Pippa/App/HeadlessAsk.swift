import Foundation
import PiRPC
import PippaCore

/// `Pippa --ask "…"`: one question through `PiSession`, printed as plain lines. For acceptance runs without the window.
/// Nobody can answer there: it uses existing grants only and declines every question (`PiSession.Interaction.headless`).
@MainActor
enum HeadlessAsk {
    static func setup() async -> Int32 {
        let setup = SetupModel.shared
        setup.begin()
        var last = ""
        while true {
            let line = String(describing: setup.state)
            if line != last, !line.hasPrefix("downloading") || line.count < 60 { print(line); last = line }
            switch setup.state {
            case .ready: return 0
            case .failed(let problem): print("FAILED: \(problem.message) — \(problem.details)"); return 1
            case .askDownload: setup.load()
            default: break
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// How one `--ask` run ended, as the process saw it: a status of the run, not a verdict on the answer. The last output
    /// line is `PIPPA_ASK_RESULT {"status":"…"}`; the exit code is 0 only for `completed`.
    enum Status: String {
        case completed, needs_access, needs_input, failed

        var exitCode: Int32 {
            switch self {
            case .completed: 0
            case .failed: 1
            case .needs_access: 2
            case .needs_input: 3
            }
        }

        var line: String { "PIPPA_ASK_RESULT {\"status\":\"\(rawValue)\"}" }

        var explanation: String {
            switch self {
            case .completed: "the run finished; this does not check the answer"
            case .needs_access: "a tool needs access that is not granted yet; --ask never asks for it"
            case .needs_input: "Pi asked a question; --ask declines every question"
            case .failed: "the run or one of its tools failed"
            }
        }
    }

    /// The status from Pi's events (tool results and model turns are read as the app's tools and Pi report them, never
    /// from the answer text) and from the questions `--ask` declined. Failed beats needs_access beats needs_input.
    struct Outcome {
        private var failed = false
        private var access = false
        /// Tools Pi stopped before any effect for a reason that is not access (e.g. a declined question).
        private var blocked = 0

        mutating func observe(_ event: PiRPCEvent) {
            switch event {
            case .toolEnded(_, let name, let isError, let result, let outcome, let fileAccessFailure):
                if fileAccessFailure != nil || (isError && Self.needsAccess(tool: name, result: result)) { access = true }
                // A native validation/read/write error is not an unanswered question. Keep its failure even when
                // another tool needs access or an unrelated Pi question was declined later in this run.
                else if isError && PiTurnReceipt.pippaTool(name) != nil { failed = true }
                else if outcome == .blocked { blocked += 1 }
                else if isError || outcome == .failed || outcome == .unclear { failed = true }
            case .assistantEnded(_, let reason, let error):
                if reason == "error" || reason == "aborted" || error != nil { failed = true }
            case .settled(let aborted):
                if aborted { failed = true }
            default:
                break
            }
        }

        func status(declinedQuestions: Int) -> Status {
            if failed || (blocked > 0 && !access && declinedQuestions == 0) { return .failed }
            if access { return .needs_access }
            return declinedQuestions > 0 ? .needs_input : .completed
        }

        /// Pippa's own tools put `status` into their JSON result: `needs_access` (never decided) or `denied`.
        static func needsAccess(tool: String, result: String) -> Bool {
            guard PiTurnReceipt.pippaTool(tool) != nil,
                  let json = (try? JSONSerialization.jsonObject(with: Data(result.utf8))) as? [String: Any],
                  let status = json["status"] as? String else { return false }
            return status == "needs_access" || status == "denied"
        }
    }

    final class Questions: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func declined() { lock.withLock { count += 1 } }
        var total: Int { lock.withLock { count } }
    }

    typealias Ask = @MainActor (String, String, @escaping (PiRPCEvent) -> Void) async throws -> Void

    /// `ask` and `write` default to the real session and standard output; checks pass their own.
    static func run(_ question: String,
                    ask: Ask = { text, conversation, onEvent in try await PiSession.shared.ask(text, conversation: conversation, onEvent: onEvent) },
                    write: @escaping (String) -> Void = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) }) async -> Int32 {
        let started = Date()
        func say(_ line: String) { write(String(format: "%6.1fs ", Date().timeIntervalSince(started)) + line) }
        // Nobody is at the keyboard: only existing grants are used, and no question can open a dialog.
        let questions = Questions()
        PiSession.shared.interaction = .headless(declined: { _ in questions.declined() })
        defer { PiSession.shared.interaction = .window }
        var answer = ""
        var evidence = DateEvidence()
        var outcome = Outcome()
        var thrown = false
        evidence.add(prompt: question)
        _ = PippaMCPService.readNotes.take(); _ = PippaMCPService.writeNotes.take()
        do {
            try await ask(question, "ask-" + UUID().uuidString.lowercased()) { event in
                evidence.observe(event)
                outcome.observe(event)
                switch event {
                case .textDelta(let delta): answer += delta
                case .toolStarted(_, let name, let arguments): say("→ \(name) \(arguments.prefix(300))")
                case .toolEnded(_, let name, let isError, let result, _, _): say("← \(name)\(isError ? " ERROR" : "") \(result.prefix(300).replacingOccurrences(of: "\n", with: " "))")
                case .assistantEnded(_, let reason, let error): say("· model turn ended: \(reason)\(error.map { " " + $0 } ?? "")")
                default: break
                }
            }
        } catch {
            say("FAILED: \(error.localizedDescription)")
            thrown = true
        }
        for card in PippaMCPService.readNotes.take().compactMap(\.card) { say("[card] \(String(describing: card).prefix(200))") }
        for receipt in PippaMCPService.writeNotes.take() { say("[done] \(receipt.action) \(receipt.outcome) \(receipt.name)") }
        if !thrown {
            say("ANSWER (\(Int(Date().timeIntervalSince(started))) s):\n\(answer)")
            let dates = evidence.unsupported(in: answer)
            if !dates.isEmpty { say("[not in the sources] \(dates.joined(separator: ", "))") }
        }
        let status = thrown ? Status.failed : outcome.status(declinedQuestions: questions.total)
        await PiSession.shared.shutdown()
        if let server = PiSession.shared.ownedServer { await server.stop() }
        say("\(status.rawValue): \(status.explanation)")
        write(status.line)
        return status.exitCode
    }
}
