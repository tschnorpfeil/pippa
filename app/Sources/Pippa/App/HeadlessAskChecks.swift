import Foundation
import PiRPC
import PippaCore

/// Also run by `Pippa --check-approvals`: what `Pippa --ask` may and may not do without a person at the keyboard.
/// The runs go through `HeadlessAsk.run`, `PiSession.interaction` and the app's own MCP host (`PippaMCPService`), with stand-in
/// readers and writers and a scripted Pi that calls Pippa's real tools. No model, no real Calendar, no permission request.
@MainActor
enum HeadlessAskChecks {
    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() { lock.withLock { value += 1 } }
        var total: Int { lock.withLock { value } }
    }

    /// Counts how often a system permission prompt would have been requested.
    private final class CountingIntegrations: AppIntegrations, @unchecked Sendable {
        let base: DemoIntegrations
        let requests = Count()
        init(_ base: DemoIntegrations) { self.base = base }
        func access(_ integration: Integration) async -> IntegrationAccess { await base.access(integration) }
        func prepareMailAccess() async -> IntegrationAccess { await base.prepareMailAccess() }
        func requestAccess(_ integration: Integration) async -> IntegrationAccess { requests.add(); return await base.requestAccess(integration) }
        func remove(_ item: CreatedItem) async throws -> RemoveResult { try await base.remove(item) }
        func selectedMail() async throws -> MailMessage? { try await base.selectedMail() }
        func events(in interval: DateInterval, limit: Int) async throws -> CalendarFetch { try await base.events(in: interval, limit: limit) }
    }

    private struct Fixture {
        let demo: DemoIntegrations
        let integrations: CountingIntegrations
        /// Pippa's own sentence before the system prompt: a stand-in for the alert.
        let explained = Count()
        var host: PippaMCPHost

        init(granted: Bool) {
            demo = DemoIntegrations(granted: granted)
            integrations = CountingIntegrations(demo)
            let explained = self.explained
            host = PippaMCPHost(integrations: integrations, sheets: DemoSheetReader(granted: granted), hostData: DemoHostData(integrations: demo),
                                explainAccess: { _, _ in explained.add(); return true })
            host.writer = demo
        }
    }

    private struct ToolReply { let isError: Bool; let text: String; var status: String? {
        ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])?["status"] as? String
    } }

    /// One tool call through Pippa's real MCP server logic, with the host the app itself is currently using.
    private static func call(_ name: String, _ arguments: [String: Any]) async -> ToolReply {
        let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                               "params": ["name": name, "arguments": arguments]])
        let reply = await PippaMCPTools(host: PippaMCPService.currentHost).handle(body)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let result = reply?["result"] as? [String: Any]
        let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        return ToolReply(isError: result?["isError"] as? Bool ?? true, text: text)
    }

    /// What Pi's RPC client reports for that call (`tool_execution_end`).
    private static func ended(_ tool: String, _ reply: ToolReply) -> PiRPCEvent {
        let envelope: [String: Any] = ["content": [["type": "text", "text": reply.text]]]
        return .toolEnded(id: UUID().uuidString, name: tool, isError: reply.isError, result: reply.text,
                          outcome: PiTurnReceipt.classify(tool: tool, isError: reply.isError, result: envelope), fileAccessFailure: nil)
    }

    private static func plainTool(_ name: String, isError: Bool, result: String, blocked: Bool = false, id: String = UUID().uuidString) -> PiRPCEvent {
        .toolEnded(id: id, name: name, isError: isError, result: result,
                   outcome: blocked ? .blocked : isError ? .failed : .done, fileAccessFailure: nil)
    }

    private struct Run { let code: Int32; let lines: [String]
        var markers: [String] { lines.filter { $0.contains("PIPPA_ASK_RESULT") } }
        func ended(with status: HeadlessAsk.Status) -> Bool { markers == [status.line] && lines.last == status.line && code == status.exitCode }
    }

    /// `HeadlessAsk.run` with a scripted Pi: `script` plays what Pi would do during the answer.
    private static func headless(_ fixture: Fixture, answer: String = "Done.",
                                 script: @escaping @MainActor ((PiRPCEvent) -> Void) async throws -> Void) async -> Run {
        let original = PippaMCPService.baseHost
        PippaMCPService.baseHost = { fixture.host }
        defer { PippaMCPService.baseHost = original }
        var lines: [String] = []
        let code = await HeadlessAsk.run("What is on my calendar?", ask: { _, _, emit in
            let turn = PippaMCPTurn()
            PippaMCPService.begin(turn)
            defer { PippaMCPService.end(turn) }
            try await script(emit)
            emit(.textDelta(answer))
            emit(.settled(aborted: false))
        }, write: { lines.append($0) })
        return Run(code: code, lines: lines)
    }

    static func run() async -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print("\(ok ? "PASS" : "FAIL") \(name)")
            if !ok { failures += 1 }
        }
        func question(_ id: String, _ method: String) -> PiUIRequest {
            PiUIRequest(id: id, method: method, title: "Run this command?", message: "Pippa wants to change something.", options: ["Once", "Always"])
        }

        // Access that was never decided: reads and writes say needs_access and nothing is requested or explained.
        let fresh = Fixture(granted: false)
        var replies: [ToolReply] = []
        let noAccess = await headless(fresh) { emit in
            for (tool, name, arguments) in [("mcp__pippa__calendar_read", "calendar_read", ["period": "today"] as [String: Any]),
                                            ("mcp__pippa__calendar_add", "calendar_add", ["title": "Test appointment", "date": "tomorrow"])] {
                let reply = await call(name, arguments)
                replies.append(reply)
                emit(ended(tool, reply))
            }
        }
        check(replies.map(\.status) == ["needs_access", "needs_access"] && replies.allSatisfy(\.isError), "--ask: a fresh calendar read and write both say needs_access")
        check(fresh.integrations.requests.total == 0 && fresh.explained.total == 0, "--ask: no permission is requested and Pippa's sentence is not shown")
        check(fresh.demo.createdCount == 0, "--ask: a write without access creates nothing")
        check(noAccess.ended(with: .needs_access), "--ask: needs_access ends with that one summary line and exit code 2")
        check(PiSession.shared.interaction.asksForAccess && PippaMCPService.asksForAccess, "after --ask the window's interactive default is back")

        // Granted access still reaches the readers and writers.
        let granted = Fixture(granted: true)
        var grantedReplies: [ToolReply] = []
        let usable = await headless(granted) { emit in
            for (tool, name, arguments) in [("mcp__pippa__calendar_read", "calendar_read", ["period": "today"] as [String: Any]),
                                            ("mcp__pippa__calendar_add", "calendar_add", ["title": "Test appointment", "date": "tomorrow"])] {
                let reply = await call(name, arguments)
                grantedReplies.append(reply)
                emit(ended(tool, reply))
            }
        }
        check(grantedReplies.count == 2 && grantedReplies.allSatisfy { !$0.isError }, "--ask: granted access still reads and writes")
        check(granted.demo.createdCount == 1 && granted.integrations.requests.total == 0 && granted.explained.total == 0,
              "--ask: the granted write reached the stand-in writer without any request")
        check(usable.ended(with: .completed), "--ask: a run without problems is completed, exit code 0")

        // The same host policy in the window keeps asking (not run: it would open Pippa's alert).
        let window = PippaMCPService.configured(Fixture(granted: false).host, asksForAccess: true)
        let silent = PippaMCPService.configured(Fixture(granted: false).host, asksForAccess: false)
        check(window.askForAccess && window.explainAccess != nil && !silent.askForAccess, "the window's host asks for access; the headless host does not")

        // Pi's questions: declined in --ask, shown in the window.
        let approvals = Approvals.shared
        approvals.present("headless-check")
        defer { approvals.dismiss("headless-check") }
        let declined = Count()
        let silentUI = PiSession.Interaction.headless(declined: { _ in declined.add() })
        var answers: [PiUIResponse] = []
        for method in ["confirm", "select", "input", "editor"] { answers.append(await silentUI.uiHandler(question("h-\(method)", method))) }
        check(answers == [.confirmed(false), .cancelled, .cancelled, .cancelled] && declined.total == 4,
              "--ask: a confirmation is denied, a choice, input or editor is cancelled")
        check(approvals.questions.isEmpty, "--ask: no question reaches a dialog or the chat's question card")
        let shown = Task { await PiSession.Interaction.window.uiHandler(question("w-1", "confirm")) }
        for _ in 0..<5 { await Task.yield() }
        check(approvals.questions.map(\.id) == ["w-1"], "the window still shows Pi's question to the person")
        approvals.answer("w-1", .confirmed(true))
        check(await shown.value == .confirmed(true), "the window's answer comes from the person")

        // The summary comes from events and declined questions, not from the answer's words.
        let needsInput = await headless(Fixture(granted: true)) { emit in
            let reply = await PiSession.shared.interaction.uiHandler(question("run-1", "confirm"))
            emit(plainTool("bash", isError: true, result: "Not run: the person said no.", blocked: true))
            if reply != .confirmed(false) { emit(plainTool("bash", isError: true, result: "answered by mistake")) }
        }
        check(needsInput.ended(with: .needs_input), "--ask: a declined question is needs_input (the blocked command is not a failure), exit code 3")
        let unexplained = await headless(Fixture(granted: true)) { emit in emit(plainTool("bash", isError: true, result: "Blocked", blocked: true)) }
        check(unexplained.ended(with: .failed), "--ask: a blocked tool without a recorded cause is failed")
        let blockedAndAccess = await headless(Fixture(granted: false)) { emit in
            emit(plainTool("bash", isError: true, result: "App control is not allowed.", blocked: true))
            emit(ended("mcp__pippa__calendar_read", await call("calendar_read", ["period": "today"])))
        }
        check(blockedAndAccess.ended(with: .failed), "--ask: a blocked shell command without a question stays failed after missing calendar access")
        let toolFailed = await headless(Fixture(granted: true), answer: "Everything worked.") { emit in
            emit(plainTool("bash", isError: true, result: "exit 1"))
        }
        check(toolFailed.ended(with: .failed), "--ask: a failed tool is failed although the model then answers")
        let everything = await headless(Fixture(granted: false)) { emit in
            _ = await PiSession.shared.interaction.uiHandler(question("run-2", "select"))
            emit(ended("mcp__pippa__calendar_read", await call("calendar_read", ["period": "today"])))
            emit(plainTool("bash", isError: true, result: "exit 1"))
        }
        check(everything.ended(with: .failed), "--ask: failed wins over needs_access and needs_input")
        let accessAndInput = await headless(Fixture(granted: false)) { emit in
            _ = await PiSession.shared.interaction.uiHandler(question("run-3", "confirm"))
            emit(ended("mcp__pippa__calendar_read", await call("calendar_read", ["period": "today"])))
        }
        check(accessAndInput.ended(with: .needs_access), "--ask: needs_access wins over needs_input")
        for withAccessFailure in [true, false] {
            let fixture = Fixture(granted: !withAccessFailure)
            var nativeStatus: String?
            let mixed = await headless(fixture) { emit in
                let invalid = await call("calendar_add", ["title": "Test appointment", "date": "not-a-date"])
                nativeStatus = invalid.status
                emit(ended("mcp__pippa__calendar_add", invalid))
                if withAccessFailure {
                    emit(ended("mcp__pippa__calendar_read", await call("calendar_read", ["period": "today"])))
                } else {
                    _ = await PiSession.shared.interaction.uiHandler(question("mixed-error", "confirm"))
                }
            }
            check(nativeStatus == "invalid_arguments" && mixed.ended(with: .failed) && fixture.demo.createdCount == 0,
                  "--ask: invalid native arguments stay failed after \(withAccessFailure ? "missing access" : "an unrelated declined question")")
        }
        let words = await headless(Fixture(granted: true), answer: "I have no access to your calendar (needs_access).") { emit in
            emit(plainTool("read", isError: false, result: "{\"status\":\"needs_access\"}"))
        }
        check(words.ended(with: .completed), "--ask: the words needs_access in an answer or in a file's text do not change the status")
        let foreign = await headless(Fixture(granted: true)) { emit in
            emit(plainTool("bash", isError: true, result: "{\"status\":\"needs_access\"}"))
        }
        check(foreign.ended(with: .failed), "--ask: only Pippa's own tools can report needs_access")
        let modelError = await headless(Fixture(granted: true)) { emit in emit(.assistantEnded(text: "", stopReason: "error", error: "provider down")) }
        check(modelError.ended(with: .failed), "--ask: a model error is failed")
        let unclear = await headless(Fixture(granted: true)) { emit in
            emit(.toolEnded(id: "u", name: "mcp__pippa__calendar_add", isError: false, result: "{}", outcome: .unclear, fileAccessFailure: nil))
        }
        check(unclear.ended(with: .failed), "--ask: a write with an unclear outcome is failed")
        let folder = await headless(Fixture(granted: true)) { emit in
            emit(.toolEnded(id: "f", name: "list_folder", isError: true, result: "denied", outcome: .failed,
                            fileAccessFailure: PiFileAccessFailure.decode(
                                tool: "list_folder", isError: true,
                                result: ["details": ["pippaFileAccess": ["schema": 1, "code": "EACCES", "path": "/Users/test/Documents"]]])))
        }
        check(folder.ended(with: .needs_access), "--ask: a folder Pippa may not open is needs_access")
        let dated = await headless(Fixture(granted: true), answer: "Der Termin ist am 12.03.2031.") { emit in
            emit(.toolStarted(id: "d", name: "read", arguments: "{}"))
            emit(plainTool("read", isError: false, result: "Der Termin ist am 01.12.2026 um 10 Uhr.", id: "d"))
        }
        check(dated.ended(with: .completed) && dated.lines.contains { $0.contains("[not in the sources]") },
              "--ask: an answer with a date from nowhere is still reported by the date check, and completed does not say it is right")
        let thrown = await headless(Fixture(granted: true)) { _ in throw PiSession.Failure.model("provider unreachable") }
        check(thrown.ended(with: .failed) && thrown.lines.contains { $0.contains("FAILED: provider unreachable") }, "--ask: an error ends with failed, exit code 1 and one summary line")
        check(PiSession.shared.interaction.asksForAccess && PippaMCPService.asksForAccess, "the interactive default survives every run")

        // The real binary, without a Pi to start: the error path prints the marker once as the last line.
        check(await subprocessFailure(), "Pippa --ask without a Pi payload fails with exit code 1 and one PIPPA_ASK_RESULT line")

        print(failures == 0 ? "headless ask: all checks passed" : "headless ask: \(failures) failed")
        return Int32(failures == 0 ? 0 : 1)
    }

    /// Runs this executable as `--ask` against a payload folder that does not exist: `PiSession` fails before it starts anything.
    private static func subprocessFailure() async -> Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--ask", "Is this reachable?"]
        var environment = ProcessInfo.processInfo.environment
        environment["PIPPA_PI_PAYLOAD"] = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-no-payload-\(UUID().uuidString)").path
        environment["PIPPA_DEMO"] = "1"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        let data = await Task.detached { output.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        return process.terminationStatus == HeadlessAsk.Status.failed.exitCode
            && lines.filter { $0.contains("PIPPA_ASK_RESULT") } == [HeadlessAsk.Status.failed.line] && lines.last == HeadlessAsk.Status.failed.line
    }
}
