import Foundation
import PiRPC

// The check executable also serves as a deterministic Pi stand-in. This exercises the actual process, JSONL,
// command correlation, and event-stream path without loading a model or reading the person's Pi configuration.
if CommandLine.arguments.contains("--version") {
    print("1.5.0")
    exit(0)
}

func emit(_ record: [String: Any]) {
    var data = try! JSONSerialization.data(withJSONObject: record)
    data.append(10)
    try! FileHandle.standardOutput.write(contentsOf: data)
}

func assistant(_ text: String, stop: String) {
    emit(["type": "message_update", "assistantMessageEvent": ["type": "text_delta", "delta": text]])
    emit(["type": "message_end", "message": ["role": "assistant", "content": [["type": "text", "text": text]], "stopReason": stop]])
}

if CommandLine.arguments.contains("--mode") {
    while let line = readLine(), let data = line.data(using: .utf8),
          let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        let id = request["id"] as? String ?? ""
        let command = request["type"] as? String ?? ""
        if handleReadinessFixture(request) { continue }
        func response(_ disposition: String? = nil) {
            var record: [String: Any] = ["type": "response", "id": id, "command": command, "success": true]
            if let disposition { record["data"] = ["disposition": disposition] }
            emit(record)
        }
        switch command {
        case "prompt":
            switch request["message"] as? String {
            case "folder-permission-protocol":
                response("started")
                emit(["type": "tool_execution_start", "toolCallId": "denied-folder", "toolName": "list_folder", "args": ["path": "/Users/fixture/Documents/Private"]])
                emit(["type": "tool_execution_end", "toolCallId": "denied-folder", "toolName": "list_folder", "isError": true,
                      "result": ["content": [["type": "text", "text": String(repeating: "x", count: 30_000)]],
                                 "details": ["pippaFileAccess": ["schema": 1, "code": "EPERM", "path": "/Users/fixture/Documents/Private"]]]])
                emit(["type": "agent_settled", "aborted": false])
            case "digest-protocol":
                response("started")
                // `read` on a long document (runtime/pippa-tools/digest.ts): one update per part, notes in the details.
                let call = "long-read", path = "/Users/fixture/Documents/Thesis.docx"
                emit(["type": "tool_execution_start", "toolCallId": call, "toolName": "read", "args": ["path": path]])
                for (part, phase) in [(1, "notes"), (2, "notes"), (3, "notes"), (1, "merge")] {
                    emit(["type": "tool_execution_update", "toolCallId": call, "toolName": "read", "args": ["path": path],
                          "partialResult": ["content": [["type": "text", "text": "Part \(part) of 3"]],
                                            "details": ["pippaProgress": ["part": part, "of": phase == "merge" ? 1 : 3, "phase": phase]]]])
                }
                // Another tool's partial output is no progress.
                emit(["type": "tool_execution_update", "toolCallId": call, "toolName": "bash", "args": [:],
                      "partialResult": ["content": [["type": "text", "text": "partial output"]], "details": [:]]])
                emit(["type": "tool_execution_end", "toolCallId": call, "toolName": "read", "isError": false,
                      "result": ["content": [["type": "text", "text": "[Notes on Thesis.docx: lines 1-1931 …]"]],
                                 "details": ["pippaDocument": ["path": path, "via": "textutil"],
                                             "pippaDigest": ["notes": "/Users/fixture/Library/Application Support/Pippa/digests/Thesis.docx.0123456789.md",
                                                             "lines": 1931, "parts": 3, "gaps": [], "cached": false]]]])
                emit(["type": "agent_settled", "aborted": false])
            case "outcome-protocol":
                response("started")
                for (id, fields) in [
                    ("missing", ["isError": false]),
                    ("numeric", ["isError": 0, "result": ["content": [["type": "text", "text": "Done"]]]]),
                    ("empty", ["isError": false, "result": ["content": []]]),
                    ("native", ["isError": false, "result": ["content": [["type": "text", "text": "{\"padding\":\"" + String(repeating: "x", count: 800) + "\",\"done\":false,\"state\":\"unclear\"}"]]]])
                ] as [(String, [String: Any])] {
                    let tool = id == "native" ? "mcp__pippa__mail_draft" : "write"
                    emit(["type": "tool_execution_start", "toolCallId": id, "toolName": tool, "args": [:]])
                    emit(["type": "tool_execution_end", "toolCallId": id, "toolName": tool].merging(fields) { _, new in new })
                }
                emit(["type": "agent_settled", "aborted": false])
            case "move-protocol":
                response("started")
                // move_files with `to: "trash"` (files.ts) is a trash line; any other destination is a move.
                let calls: [(id: String, args: [String: Any], text: String, details: [String: Any])] = [
                    ("trash", ["from": "/Users/fixture/Downloads/alt.pdf", "to": "trash"], "Moved alt.pdf to the Trash.",
                     ["from": "/Users/fixture/Downloads/alt.pdf", "trash": true, "to": "/Users/fixture/.Trash/alt.pdf"]),
                    ("move", ["from": "/Users/fixture/Downloads/neu.pdf", "to": "/Users/fixture/Documents/Steuer"], "Moved.",
                     ["from": "/Users/fixture/Downloads/neu.pdf", "to": "/Users/fixture/Documents/Steuer/neu.pdf"]),
                ]
                for call in calls {
                    emit(["type": "tool_execution_start", "toolCallId": call.id, "toolName": "move_files", "args": call.args])
                    emit(["type": "tool_execution_end", "toolCallId": call.id, "toolName": "move_files", "isError": false,
                          "result": ["content": [["type": "text", "text": call.text]], "details": call.details]])
                }
                emit(["type": "agent_settled", "aborted": false])
            case "handled":
                response("handled")
            case "immediate":
                // Completion can beat command acknowledgement; clients must subscribe before writing.
                assistant("Already done", stop: "stop")
                emit(["type": "agent_settled", "aborted": false])
                response("started")
            case "continuation":
                response("started")
                assistant("First pass", stop: "toolUse")
                emit(["type": "agent_end", "messages": [], "willRetry": false])
                assistant("Queued follow-up", stop: "stop")
                emit(["type": "agent_end", "messages": [], "willRetry": false])
                emit(["type": "agent_settled", "aborted": false])
            case "abort-during-tool":
                response("started")
                assistant("Working", stop: "toolUse")
                emit(["type": "tool_execution_start", "toolCallId": "pending-tool", "toolName": "fixture", "args": [:]])
            case "abort-between-turns":
                response("started")
                assistant("First answer", stop: "stop")
                emit(["type": "agent_end", "messages": [], "willRetry": false])
                // An extension or queued-work cancellation need not emit another assistant message.
                emit(["type": "agent_settled", "aborted": true])
            default:
                response("started")
                assistant("Done", stop: "stop")
                emit(["type": "agent_settled", "aborted": false])
            }
        case "abort":
            emit(["type": "tool_execution_end", "toolCallId": "pending-tool", "toolName": "fixture", "isError": true,
                  "result": ["content": [["type": "text", "text": "Cancelled"]]]])
            emit(["type": "agent_end", "messages": [], "willRetry": false])
            emit(["type": "agent_settled", "aborted": true])
            response()
        default:
            response()
        }
    }
    exit(0)
}

// A broken protocol must fail CI instead of waiting forever for a missing settled event.
let watchdog = Task.detached {
    try await Task.sleep(for: .seconds(20))
    FileHandle.standardError.write(Data("Pi RPC checks timed out.\n".utf8))
    exit(1)
}
defer { watchdog.cancel() }

var failures = 0
@MainActor func check(_ name: String, _ passed: Bool) {
    print("\(passed ? "✓" : "✗") \(name)")
    if !passed { failures += 1 }
}

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-rpc-checks-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let client = PiRPCClient(configuration: PiRPCConfiguration(executable: executable, workingDirectory: temporary))
try await client.start()
try await runCommandLifetimeChecks(executable: executable, temporary: temporary)

func collect(_ prompt: String) async throws -> [PiRPCEvent] {
    var events: [PiRPCEvent] = []
    for try await event in try await client.prompt(prompt) { events.append(event) }
    return events
}

let immediate = try await collect("immediate")
check("Completion before acknowledgement preserves text and settlement", immediate == [
    .textDelta("Already done"), .assistantEnded(text: "Already done", stopReason: "stop", error: nil), .settled(aborted: false)
])
check("Settled client is idle", await client.isAnswering == false)

let handled = try await collect("handled")
let idleAfterHandled = await client.isAnswering == false
check("Handled prompts finish without waiting for a run", handled.isEmpty && idleAfterHandled)

let continuation = try await collect("continuation")
check("agent_end leaves queued continuation in the same stream", continuation == [
    .textDelta("First pass"), .assistantEnded(text: "First pass", stopReason: "toolUse", error: nil),
    .textDelta("Queued follow-up"), .assistantEnded(text: "Queued follow-up", stopReason: "stop", error: nil), .settled(aborted: false)
])

var cancelled: [PiRPCEvent] = []
for try await event in try await client.prompt("abort-during-tool") {
    cancelled.append(event)
    if case .toolStarted = event { try await client.abort() }
}
check("Abort during tool execution preserves cancellation without an aborted assistant", cancelled.last == .settled(aborted: true)
      && cancelled.contains(.assistantEnded(text: "Working", stopReason: "toolUse", error: nil))
      && cancelled.contains(.toolEnded(id: "pending-tool", name: "fixture", isError: true, result: "Cancelled", outcome: .failed)))

let between = try await collect("abort-between-turns")
check("Cancellation after a completed assistant is not reported as successful settlement", between.last == .settled(aborted: true)
      && between.contains(.assistantEnded(text: "First answer", stopReason: "stop", error: nil)))
let recovered = try await collect("next-prompt")
check("A cancelled run releases the client for the next prompt", recovered.last == .settled(aborted: false))

let outcomes = try await collect("outcome-protocol")
var outcomeReceipt = PiTurnReceipt()
for event in outcomes { outcomeReceipt.observe(event) }
check("RPC keeps absent and malformed results uncertain, permits valid empty success, and classifies full native JSON",
      outcomeReceipt.records.map(\.outcome) == [.unclear, .unclear, .done, .unclear])
runOutcomeChecks()
runLaunchChecks()
var moveReceipt = PiTurnReceipt()
for event in try await collect("move-protocol") { moveReceipt.observe(event) }
check("move_files to the Trash is a trash line; to a folder it is a move with the folder's name",
      moveReceipt.records.map(\.action) == ["trash", "move"] && moveReceipt.records.map(\.name) == ["alt.pdf", "neu.pdf"]
      && moveReceipt.records.map(\.toName) == [nil, "Steuer"] && moveReceipt.records.map(\.outcome) == [.done, .done])
var folderReceipt = PiTurnReceipt()
for event in try await collect("folder-permission-protocol") { folderReceipt.observe(event) }
check("Real RPC decoding retains structured folder denial even when display output is truncated",
      folderReceipt.records.first?.fileAccessFailure?.code == "EPERM"
      && folderReceipt.records.first?.fileAccessFailure?.path == "/Users/fixture/Documents/Private")
let digest = try await collect("digest-protocol")
let digestProgress = digest.compactMap { event -> [Int]? in
    if case .toolProgress(let id, let part, let of, let merging) = event, id == "long-read" { return [part, of, merging ? 1 : 0] }
    return nil
}
let notesAt = digest.firstIndex(of: .toolNotes(id: "long-read", path: "/Users/fixture/Library/Application Support/Pippa/digests/Thesis.docx.0123456789.md"))
let endedAt = digest.firstIndex { if case .toolEnded(let id, _, let isError, _, _, _) = $0 { return id == "long-read" && !isError }; return false }
check("A long document's read reports each part and the merge round; other tools' partial output is no progress",
      digestProgress == [[1, 3, 0], [2, 3, 0], [3, 3, 0], [1, 1, 1]])
check("The notes file of a long document reaches the app right before the read ends",
      notesAt != nil && endedAt != nil && notesAt! + 1 == endedAt!)
try await runNativeReadinessChecks(executable: executable, temporary: temporary)
await client.shutdown()
print(failures == 0 ? "Pi RPC checks passed." : "\(failures) Pi RPC check(s) failed.")
exit(failures == 0 ? 0 : 1)
