import Foundation
import PiRPC

/// Exercise the evidence-to-receipt boundary, including successful-looking malformed native replies.
@MainActor func runOutcomeChecks() {
    func result(_ text: String, details: [String: Any]? = nil) -> [String: Any] {
        var value: [String: Any] = ["content": [["type": "text", "text": text]]]
        if let details { value["details"] = details }
        return value
    }
    let native = "mcp__pippa__reminder_add"
    let uncertain = [
        "Connection closed before the native app replied", "{broken", "{\"done\":1}", "{\"done\":true}",
        "{\"done\":false,\"state\":\"unclear\"}", "{\"done\":false,\"dispatched\":true,\"status\":\"failed\"}",
        "{\"done\":false,\"status\":\"new_future_status\"}",
        "{\"done\":false,\"status\":\"failed\",\"dispatched\":1}",
        "{\"done\":false,\"status\":\"failed\",\"dispatched\":\"true\"}"
    ]
    check("Native missing or malformed confirmations never become a success or a no-effect claim",
          uncertain.allSatisfy { PiTurnReceipt.classify(tool: native, isError: true, result: result($0)) == .unclear }
          && PiTurnReceipt.classify(tool: native, isError: false, result: result("{\"done\":1}")) == .unclear
          && PiTurnReceipt.classify(tool: native, isError: false, result: nil) == .unclear)
    check("Only a native boolean confirmation reports success",
          PiTurnReceipt.classify(tool: native, isError: false, result: result("{\"done\":true}")) == .done)
    let prepare = "mcp__pippa__prepare_files"
    check("Prepared files require the same native confirmation and uncertainty rules as other changes",
          PiTurnReceipt.pippaWriters.contains("prepare_files")
          && PiTurnReceipt.classify(tool: prepare, isError: false, result: result("{\"done\":true,\"path\":\"/fixture/result.pdf\"}")) == .done
          && PiTurnReceipt.classify(tool: prepare, isError: false, result: result("Connection closed")) == .unclear
          && PiTurnReceipt.classify(tool: prepare, isError: true, result: result("{\"done\":false,\"status\":\"not_dispatched\",\"dispatched\":false}")) == .blocked)
    check("Native refusals and duplicate blocks remain known pre-dispatch outcomes",
          ["invalid_arguments", "not_dispatched", "busy", "cancelled"].allSatisfy { status in
              PiTurnReceipt.classify(tool: native, isError: status != "busy",
                                     result: result("{\"done\":false,\"dispatched\":false,\"status\":\"\(status)\"}")) == .blocked
          })
    check("Shell failure differs from no dispatch and from interruption",
          PiTurnReceipt.classify(tool: "bash", isError: true, result: result("exit 1", details: ["pippaExecution": "attempted"])) == .failed
          && PiTurnReceipt.classify(tool: "bash", isError: true, result: result("Stopped", details: ["pippaExecution": "not_dispatched"])) == .blocked
          && PiTurnReceipt.classify(tool: "bash", isError: true, result: result("Timed out", details: ["pippaExecution": "uncertain"])) == .unclear
          && PiTurnReceipt.classify(tool: "bash", isError: true, result: result("{\"pippaExecution\":\"not_dispatched\"}")) == .failed)
    check("Missing envelopes and malformed text stay unconfirmed; valid empty success stays successful",
          PiTurnReceipt.classify(tool: "write", isError: false, result: nil) == .unclear
          && PiTurnReceipt.classify(tool: "write", isError: false, result: ["content": [["type": "text"]]]) == .unclear
          && PiTurnReceipt.classify(tool: "write", isError: false, result: ["content": []]) == .done)

    var receipt = PiTurnReceipt()
    receipt.observe(.toolStarted(id: "original", name: native, arguments: "{}"))
    receipt.observe(.toolEnded(id: "original", name: native, isError: true, result: "Reply lost", outcome: .unclear))
    receipt.observe(.toolStarted(id: "blocked", name: native, arguments: "{}"))
    receipt.observe(.toolEnded(id: "blocked", name: native, isError: true,
                               result: "{\"done\":false,\"status\":\"not_dispatched\",\"dispatched\":false}"))
    receipt.observe(.toolStarted(id: "pending", name: "write", arguments: "{}"))
    receipt.observe(.toolStarted(id: "failed", name: "bash", arguments: "{}"))
    receipt.observe(.toolEnded(id: "failed", name: "bash", isError: true, result: "Exit code 1"))
    receipt.observe(.toolStarted(id: "good", name: "write", arguments: "{}"))
    receipt.observe(.toolEnded(id: "good", name: "write", isError: false, result: "Done"))
    check("A later blocked retry preserves the original uncertainty, pending call, failed attempt and success",
          receipt.records.map(\.outcome) == [.unclear, .blocked, .unclear, .failed, .done])
    var next = PiTurnReceipt()
    next.observe(.toolStarted(id: "again", name: native, arguments: "{}"))
    next.observe(.toolEnded(id: "again", name: native, isError: false, result: "{\"done\":true}"))
    check("A new turn collects its own confirmed result", next.records.map(\.outcome) == [.done])

    let denied: [String: Any] = ["schema": 1, "code": "EACCES", "path": "/Users/fixture/Documents/Private"]
    let envelope = result("Access denied", details: ["pippaFileAccess": denied])
    let failure = PiFileAccessFailure.decode(tool: "list_folder", isError: true, result: envelope)
    check("Folder repair requires typed denial from the dedicated reader, never output text or another tool",
          failure?.code == "EACCES" && failure?.path == "/Users/fixture/Documents/Private"
          && PiFileAccessFailure.decode(tool: "read", isError: true, result: envelope) == nil
          && PiFileAccessFailure.decode(tool: "list_folder", isError: false, result: envelope) == nil
          && PiFileAccessFailure.decode(tool: "list_folder", isError: true, result: result("EACCES: /Users/fixture/Documents")) == nil)
    let invalid: [[String: Any]] = [denied.merging(["schema": true]) { _, b in b },
        denied.merging(["code": "ENOENT"]) { _, b in b }, denied.merging(["path": "relative"]) { _, b in b },
        denied.merging(["path": "/fixture\nforged"]) { _, b in b }, denied.merging(["schema": 2]) { _, b in b }]
    check("Malformed or future folder permission evidence is ignored",
          invalid.allSatisfy { PiFileAccessFailure.decode(tool: "list_folder", isError: true,
              result: result("Denied", details: ["pippaFileAccess": $0])) == nil })
    var deniedReceipt = PiTurnReceipt()
    deniedReceipt.observe(.toolStarted(id: "denied-folder", name: "list_folder", arguments: "{}"))
    deniedReceipt.observe(.toolEnded(id: "denied-folder", name: "list_folder", isError: true, result: "Denied",
                                    outcome: .failed, fileAccessFailure: failure))
    check("Denied folder reads stay visible with their own target and no claimed mutation",
          deniedReceipt.records.count == 1 && deniedReceipt.records.first?.action == "look"
          && deniedReceipt.records.first?.outcome == .blocked && deniedReceipt.records.first?.fileAccessFailure == failure)
    deniedReceipt.observe(.toolEnded(id: "denied-folder", name: "list_folder", isError: false, result: "Read", outcome: .done))
    check("A later successful read does not retain stale permission repair", deniedReceipt.records.isEmpty)
}
