import Foundation
import PippaCore

/// Own online service as Pi's own provider `pippa-online` (Pi talks to the service; the key reaches only Pippa's Pi
/// through its environment). No network, no Pi, no keychain.
@MainActor func runR10Checks() async {
    let base = root.appendingPathComponent("r10", isDirectory: true)
    try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    let openAI = ModelConnection(provider: .openAI, modelID: "gpt-x")
    let anthropic = ModelConnection(provider: .anthropic, modelID: "claude-x")
    let compatible = ModelConnection(provider: .compatible, endpoint: URL(string: "https://llm.example/api/v1/"), modelID: "m")

    check("models.json: pippa-online points at the service itself, key only as $PIPPA_ONLINE_KEY, API per service") {
        let o = PiOnlineProvider.entry(openAI), a = PiOnlineProvider.entry(anthropic), c = PiOnlineProvider.entry(compatible)
        return o["baseUrl"] as? String == "https://api.openai.com/v1" && o["api"] as? String == "openai-completions"
            && a["baseUrl"] as? String == "https://api.anthropic.com" && a["api"] as? String == "anthropic-messages"
            && c["baseUrl"] as? String == "https://llm.example/api/v1"
            && o["apiKey"] as? String == "$PIPPA_ONLINE_KEY" && a["apiKey"] as? String == "$PIPPA_ONLINE_KEY"
            && PiOnlineProvider.launchArguments(openAI) == ["--provider", "pippa-online", "--model", "gpt-x"]
    }
    check("Test connection uses the same addresses as Pi") {
        let o = try ModelConnectionTest.request(openAI, apiKey: "k"), a = try ModelConnectionTest.request(anthropic, apiKey: "k")
        return o.url?.absoluteString == "https://api.openai.com/v1/chat/completions"
            && a.url?.absoluteString == "https://api.anthropic.com/v1/messages"
    }
    check("models.json: adding and removing only touches pippa-online; an unreadable file stays unchanged") {
        let url = base.appendingPathComponent("models.json")
        let original = #"{"providers":{"pippa-local":{"baseUrl":"http://127.0.0.1:1/v1"},"ollama":{"apiKey":"x"}},"other":1}"#
        try Data(original.utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        guard try PiOnlineProvider.sync(openAI, modelsJSON: url), try !PiOnlineProvider.sync(openAI, modelsJSON: url) else { return false }
        let mode = (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let providers = written?["providers"] as? [String: Any]
        guard providers?["pippa-local"] != nil, providers?["ollama"] != nil, providers?["pippa-online"] != nil,
              written?["other"] as? Int == 1, mode == 0o640 else { return false }
        guard try PiOnlineProvider.sync(nil, modelsJSON: url), PiOnlineProvider.current(modelsJSON: url) == nil,
              PiInstaller.providerModelIDs(modelsJSON: url).isEmpty, (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])?["other"] as? Int == 1
        else { return false }
        let broken = base.appendingPathComponent("broken.json")
        try Data("{ // comment\n}".utf8).write(to: broken)
        let unreadable = (try? PiOnlineProvider.sync(openAI, modelsJSON: broken)) == nil
        let missing = base.appendingPathComponent("missing.json")
        let brokenText = String(decoding: try Data(contentsOf: broken), as: UTF8.self)
        let removedMissing = try PiOnlineProvider.sync(nil, modelsJSON: missing)
        return unreadable && brokenText == "{ // comment\n}" && !removedMissing && !fm.fileExists(atPath: missing.path)
    }
    check("Path: off = local; \"ask\" and \"always\" from earlier versions both mean on") {
        PiOnlineProvider.activeConnection(InferenceSettings(policy: .localOnly, connection: openAI)) == nil
            && PiOnlineProvider.activeConnection(InferenceSettings(policy: .ask, connection: openAI)) == openAI
            && PiOnlineProvider.activeConnection(InferenceSettings(policy: .customAlways, connection: openAI)) == openAI
            && PiOnlineProvider.activeConnection(InferenceSettings(policy: .ask, connection: nil)) == nil
    }
}
