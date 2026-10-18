import Foundation
import PiRPC
import PippaCore

// Small talk without thinking (SmallTalk, PiRPCChat.chat): which messages count, which models, and the RPC order
// against a small Python program that plays `pi --mode rpc` (no model).

/// Stand-in for Pi in RPC mode: logs each command (with the level of `set_thinking_level`) to $FAKE_PI_LOG, answers
/// `get_state` with the session's thinking level and settles every prompt at once.
private let fakeRPCPi = """
#!/usr/bin/python3
import json, os, sys
if "--version" in sys.argv:
    print("\(PiRPCClient.supportedVersionPrefix)0"); sys.exit(0)
log = os.environ["FAKE_PI_LOG"]
level = os.environ.get("FAKE_PI_LEVEL", "medium")
def send(o):
    sys.stdout.write(json.dumps(o) + "\\n"); sys.stdout.flush()
for line in sys.stdin:
    c = json.loads(line)
    t = c["type"]
    with open(log, "a") as f: f.write(t + (" " + c["level"] if t == "set_thinking_level" else "") + "\\n")
    if t == "get_state":
        send({"type": "response", "id": c["id"], "command": t, "success": True, "data": {"thinkingLevel": level}})
    elif t == "set_thinking_level":
        level = c["level"]
        send({"type": "response", "id": c["id"], "command": t, "success": True})
    else:
        send({"type": "response", "id": c["id"], "command": t, "success": True})
        if t == "prompt": send({"type": "agent_settled"})
"""

func runSmallTalkChecks() async {
    check("Small talk: greetings, thanks and goodbyes count; anything with a task or a yes/no does not") {
        let talk = ["Hey Pippa, wie gehts?", "Hallo!", "Wie geht es dir?", "Danke!", "Vielen Dank, super", "Gute Nacht",
                    "Moin", "Wer bist du?", "Hi Pippa, how are you?", "Thanks so much", "Good morning", "Tschüss, bis später"]
        let work = ["Wie geht das?", "Danke, mach weiter", "Ok", "Ja", "Nein", "Gerne", "Hallo, fass die Rechnung zusammen",
                    "Wie wird das Wetter morgen?", "Hey Pippa, was steht hier?", "Thanks, now reply to the mail", "",
                    "Hallo Pippa wie geht es dir heute so und was machst du"]
        return talk.allSatisfy(SmallTalk.matches) && !work.contains(where: SmallTalk.matches)
    }
    check("Small talk: thinking off only on Qwen, only when the session thinks, only for small talk") {
        let greeting = "Hey Pippa, wie gehts?"
        return SmallTalk.turnThinkingLevel(message: greeting, modelKey: "qwen3.5-9b-q4", current: "medium") == "off"
            && SmallTalk.turnThinkingLevel(message: greeting, modelKey: "qwen3.5-4b-q4", current: "off") == nil
            && SmallTalk.turnThinkingLevel(message: greeting, modelKey: "k2-horizon-7b", current: "medium") == nil
            && SmallTalk.turnThinkingLevel(message: greeting, modelKey: nil, current: "medium") == nil
            && SmallTalk.turnThinkingLevel(message: "Fass das zusammen", modelKey: "qwen3.5-9b-q4", current: "medium") == nil
    }

    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("pippa-smalltalk-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }
    let pi = dir.appendingPathComponent("pi")
    try? fakeRPCPi.write(to: pi, atomically: true, encoding: .utf8)
    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pi.path)
    func client(_ log: String) -> PiRPCClient {
        PiRPCClient(configuration: PiRPCConfiguration(executable: pi, workingDirectory: dir,
                                                      environment: ["FAKE_PI_LOG": dir.appendingPathComponent(log).path]))
    }
    func logged(_ log: String) -> [String] {
        ((try? String(contentsOf: dir.appendingPathComponent(log), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    /// One turn as PiRPCChat.chat runs it.
    func turn(_ client: PiRPCClient, _ text: String, model: String) async throws {
        if SmallTalk.matches(text) {
            await client.useThinkingLevel { SmallTalk.turnThinkingLevel(message: text, modelKey: model, current: $0) }
        } else {
            await client.restoreThinkingLevel()
        }
        for try await _ in try await client.prompt(text) {}
        await client.restoreThinkingLevel()
    }

    await checkAsync("Small talk RPC: level off before the prompt and back after it; other turns and K2 send nothing extra") {
        let qwen = client("qwen.log"), k2 = client("k2.log")
        try await qwen.start(); try await k2.start()
        try await turn(qwen, "Hey Pippa, wie gehts?", model: "qwen3.5-9b-q4")
        try await turn(qwen, "Fass die Rechnung zusammen", model: "qwen3.5-9b-q4")
        try await turn(k2, "Hey Pippa, wie gehts?", model: "k2-horizon-7b")
        let restored = await qwen.thinkingToRestore == nil
        await qwen.shutdown(); await k2.shutdown()
        return restored && logged("qwen.log") == ["get_state", "set_thinking_level off", "prompt", "set_thinking_level medium", "prompt"]
            && logged("k2.log") == ["get_state", "prompt"]
    }
    await checkAsync("Small talk RPC: a level a stopped Pi left is set back by the next Pi before its first prompt") {
        let first = client("first.log")
        try await first.start()
        await first.useThinkingLevel { SmallTalk.turnThinkingLevel(message: "Hallo", modelKey: "qwen3.5-9b-q4", current: $0) }
        let left = await first.thinkingToRestore
        await first.shutdown()
        let next = client("next.log")
        try await next.start()
        await next.restoreLater(left)
        try await turn(next, "Fass die Rechnung zusammen", model: "qwen3.5-9b-q4")
        await next.shutdown()
        return left == "medium" && logged("first.log") == ["get_state", "set_thinking_level off"]
            && logged("next.log") == ["set_thinking_level medium", "prompt"]
    }
}
