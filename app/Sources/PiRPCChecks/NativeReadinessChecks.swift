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
        let names = mode == "missing-policy" ? [PiNativeReadiness.command] : [PiNativeReadiness.command, PiActionPolicy.command]
        response(["commands": mode == "missing-command" ? [] : names.map { ["name": $0,
                                                                           "source": mode == "wrong-source" ? "prompt" : "extension"] }])
        return true
    }
    guard command == "prompt", let message = request["message"] as? String,
          [PiNativeReadiness.command, PiActionPolicy.command].contains(String(message.split(separator: " ").first?.dropFirst() ?? "")) else { return false }
    if mode == "hang-prompt" { return true }
    let nonce = String(message.split(separator: " ").last ?? "")
    let kind = message.hasPrefix("/" + PiActionPolicy.command) ? PiActionPolicy.command : PiNativeReadiness.command
    let scope = ProcessInfo.processInfo.environment[PiActionPolicy.environmentVariable] ?? "standard"
    let draft = scope == "draftOnly"
    var receipt: [String: Any] = ["v": 1, "nonce": nonce, "status": "ready",
        "tools": kind == PiActionPolicy.command ? (draft ? PiActionPolicy.draftTools : PippaPiLaunch.tools)
            : (draft ? PiActionPolicy.nativeReaders : PiNativeReadiness.tools),
        "registeredTools": PiNativeReadiness.tools, "policy": scope]
    if kind == PiActionPolicy.command && mode == "wrong-policy" { receipt["policy"] = "draftOnly" }
    if kind == PiActionPolicy.command && mode == "wide-draft" { receipt["tools"] = PiActionPolicy.draftTools + ["write"] }
    if mode == "missing-registered" { receipt.removeValue(forKey: "registeredTools") }
    if mode == "wrong-nonce" { receipt["nonce"] = UUID().uuidString }
    if mode == "partial" { receipt["tools"] = Array(PiNativeReadiness.tools.dropFirst()) }
    if mode == "missing-file-preparation" {
        receipt["registeredTools"] = PiNativeReadiness.tools.filter { $0 != "mcp__pippa__prepare_files" }
    }
    if mode == "wrong-registration" { receipt["status"] = "registrationMismatch" }
    if mode == "malformed" { receipt["v"] = true }
    if mode != "missing-receipt" {
        emit(["type": "entry_appended", "entry": ["type": "custom", "customType": kind, "data": receipt]])
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

    func make(_ mode: String, policy: PiActionPolicy = .standard) -> (PiRPCClient, URL) {
        let log = temporary.appendingPathComponent(UUID().uuidString + ".jsonl")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        return (PiRPCClient(configuration: .init(executable: executable, workingDirectory: temporary,
            environment: ["PIPPA_TEST_NATIVE_READINESS": mode, "PIPPA_TEST_NATIVE_LOG": log.path, PiActionPolicy.environmentVariable: policy.rawValue])), log)
    }
    for (mode, expected) in [
        ("missing-command", PiNativeReadiness.Failure.commandMissing), ("wrong-source", .commandMissing), ("missing-policy", .commandMissing),
        ("wrong-policy", .invalidReceipt), ("missing-registered", .invalidReceipt),
        ("missing-file-preparation", .invalidReceipt),
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
        if mode == "missing-command" || mode == "wrong-source" || mode == "missing-policy" {
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
    let scoped = PippaPiLaunch.configuration(launcher: launcher, workingDirectory: temporary, paths: paths, sessionID: nil,
                                             language: "en", environment: [PiActionPolicy.environmentVariable: "standard"], actionPolicy: .draftOnly)
    let toolIndex = scoped.arguments.firstIndex(of: "--tools")!
    check("Trusted draft scope overrides environment and declares only local readers",
          scoped.environment[PiActionPolicy.environmentVariable] == "draftOnly"
          && Set(scoped.arguments[toolIndex + 1].split(separator: ",").map(String.init)) == Set(PiActionPolicy.draftLaunchTools)
          && scoped.extensions.first?.lastPathComponent == "pippa-policy.ts")
    check("Native file preparation is required for registration but cannot write in draft-only scope",
          PiNativeReadiness.tools.contains("mcp__pippa__prepare_files")
          && !PiActionPolicy.nativeReaders.contains("mcp__pippa__prepare_files")
          && !PiActionPolicy.draftTools.contains("mcp__pippa__prepare_files")
          && PippaPiLaunch.tools.contains("mcp__pippa__*"))
    check("The native chart card is required for standard registration but is not a draft-only reader",
          PiNativeReadiness.tools.last == "mcp__pippa__make_chart"
          && !PiActionPolicy.nativeReaders.contains("mcp__pippa__make_chart")
          && !PiActionPolicy.draftTools.contains("mcp__pippa__make_chart")
          && !PiTurnReceipt.pippaWriters.contains("make_chart"))
    for mode in ["ready", "wide-draft"] {
        let (draft, _) = make(mode, policy: .draftOnly)
        try await draft.start()
        var admitted = false
        do { try await draft.verifyNativeTools(actionPolicy: .draftOnly, timeout: .seconds(1)); admitted = true } catch {}
        check("Draft admission checks native inventory and immutable active scope (\(mode))", admitted == (mode == "ready"))
        await draft.shutdown()
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
