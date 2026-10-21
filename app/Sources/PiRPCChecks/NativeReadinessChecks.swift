import Foundation
import PiRPC

// The stand-in records protocol commands, proving failure does not send an unknown slash command to a model.
func handleReadinessFixture(_ request: [String: Any]) -> Bool {
    guard let mode = ProcessInfo.processInfo.environment["PIPPA_TEST_NATIVE_READINESS"] else { return false }
    if let path = ProcessInfo.processInfo.environment["PIPPA_TEST_NATIVE_LOG"],
       let handle = FileHandle(forWritingAtPath: path), let data = try? JSONSerialization.data(withJSONObject: request) {
        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data + Data([10])); try? handle.close()
    }
    let command = request["type"] as? String ?? ""
    let id = request["id"] as? String ?? ""
    func response(_ data: [String: Any]) {
        emit(["type": "response", "id": id, "command": command, "success": true, "data": data])
    }
    if command == "get_commands" {
        if mode == "hang-command" { return true }
        response(["commands": mode == "missing-command" ? [] : [["name": PiNativeReadiness.command,
                                                                 "source": mode == "wrong-source" ? "prompt" : "extension"]]])
        return true
    }
    guard command == "prompt", let message = request["message"] as? String,
          message.hasPrefix("/" + PiNativeReadiness.command + " ") else { return false }
    if mode == "hang-prompt" { return true }
    let nonce = String(message.split(separator: " ").last ?? "")
    var receipt: [String: Any] = ["v": 1, "nonce": nonce, "status": "ready", "tools": PiNativeReadiness.tools]
    if mode == "wrong-nonce" { receipt["nonce"] = UUID().uuidString }
    if mode == "partial" { receipt["tools"] = Array(PiNativeReadiness.tools.dropFirst()) }
    if mode == "wrong-registration" { receipt["status"] = "registrationMismatch" }
    if mode == "malformed" { receipt["v"] = true }
    if mode != "missing-receipt" {
        emit(["type": "entry_appended", "entry": ["type": "custom", "customType": PiNativeReadiness.command, "data": receipt]])
    }
    response(["disposition": "handled"])
    return true
}

@MainActor func runNativeReadinessChecks(executable: URL, temporary: URL) async throws {
    let paths = PippaPiLaunch.Paths(extensionsDirectory: temporary, webExtension: nil, sessionDirectory: temporary)
    let launcher = PippaPiLaunch.Launcher(executable: executable)
    let noMCP = PippaPiLaunch.configuration(launcher: launcher, workingDirectory: temporary, paths: paths,
                                          sessionID: nil, language: "en")
    var withMCP = noMCP
    let endpoint = PippaPiLaunch.MCPEndpoint(url: URL(string: "http://127.0.0.1:1234/mcp")!, token: String(repeating: "a", count: 64))
    let extensionFile = temporary.appendingPathComponent("pippa-mcp.ts")
    PippaPiLaunch.addMCP(endpoint, extension: extensionFile, to: &withMCP)
    PippaPiLaunch.addMCP(endpoint, extension: extensionFile, to: &withMCP)
    check("MCP launches attach the scoped connector without enabling user extensions or global MCP configuration",
          noMCP.arguments.contains("--no-extensions") && !noMCP.arguments.contains("builtin:mcp")
          && withMCP.arguments == noMCP.arguments && !noMCP.extensions.contains(extensionFile)
          && withMCP.extensions.filter { $0 == extensionFile }.count == 1
          && withMCP.environment["PI_CODING_AGENT_DIR"] == nil)

    func make(_ mode: String) -> (PiRPCClient, URL) {
        let log = temporary.appendingPathComponent(UUID().uuidString + ".jsonl")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        return (PiRPCClient(configuration: .init(executable: executable, workingDirectory: temporary,
            environment: ["PIPPA_TEST_NATIVE_READINESS": mode, "PIPPA_TEST_NATIVE_LOG": log.path])), log)
    }
    for (mode, expected) in [
        ("missing-command", PiNativeReadiness.Failure.commandMissing), ("wrong-source", .commandMissing),
        ("wrong-nonce", .invalidReceipt), ("partial", .invalidReceipt), ("missing-receipt", .invalidReceipt),
        ("malformed", .invalidReceipt), ("wrong-registration", .registrationMismatch),
        ("hang-command", .timedOut), ("hang-prompt", .timedOut)
    ] {
        let (client, log) = make(mode)
        try await client.start()
        var found: PiNativeReadiness.Failure?
        do { try await client.verifyNativeTools(timeout: .milliseconds(300)) }
        catch { found = error as? PiNativeReadiness.Failure }
        check("Native readiness rejects \(mode) without admitting user work", found == expected)
        if mode == "missing-command" || mode == "wrong-source" {
            check("Unknown or non-extension readiness command is never prompted (\(mode))",
                  !(try String(contentsOf: log, encoding: .utf8)).contains("\"type\":\"prompt\""))
        }
        await client.shutdown()
    }
    for cancelTask in [true, false] {
        let (client, _) = make("hang-prompt")
        try await client.start()
        let task = Task { try await client.verifyNativeTools(timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(80))
        if cancelTask { task.cancel() } else { await client.cancelNativeReadiness() }
        var stopped = false
        do { try await task.value }
        catch { stopped = error is CancellationError || error as? PiNativeReadiness.Failure == .cancelled }
        check("Native readiness releases pending commands on \(cancelTask ? "task cancellation" : "Stop")", stopped)
        await client.shutdown()
    }
    let (fresh, _) = make("ready")
    try await fresh.start()
    try await fresh.verifyNativeTools(timeout: .seconds(1))
    var settled = false
    for try await event in try await fresh.prompt("First real user request") {
        if event == .settled(aborted: false) { settled = true }
    }
    check("A fresh process proves native readiness and accepts the user request after earlier failures", settled)
    await fresh.shutdown()
}
