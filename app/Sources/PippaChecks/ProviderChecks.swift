import Foundation
import PippaCore

func runProviderChecks() async {
    check("Provider errors preserve expired-login and usage-limit guidance") {
        PiProviderClient.problem(in: "401 Unauthorized: token expired") == .signedOut
            && PiProviderClient.problem(in: "invalid_grant: refresh token revoked") == .signedOut
            && PiProviderClient.problem(in: "No API key found for openai") == .signedOut
            && PiProviderClient.problem(in: "429 Too Many Requests: usage limit reached") == .limit
            && PiProviderClient.problem(in: "socket hang up") == nil
    }
    check("Pi routing persists provider/model metadata, defaults to local, and preserves old ChatGPT selections") {
        let base = root.appendingPathComponent("provider-settings")
        let selection = PiModelSelection(providerID: "openrouter", modelID: "anthropic/claude-fixture", providerName: "OpenRouter")
        try InferenceSettings(piModel: selection).save(to: base)
        let loaded = InferenceSettings.load(from: base)
        guard loaded.activePiModel == selection, loaded.usesOnlineAI,
              loaded.activePiModel?.launchArguments == ["--provider", "openrouter", "--model", "anthropic/claude-fixture"] else { return false }
        try InferenceSettings(subscriptionModel: "gpt-fixture").save(to: base)
        guard InferenceSettings.load(from: base).activePiModel?.providerID == "openai" else { return false }
        try InferenceSettings().save(to: base)
        return !InferenceSettings.load(from: base).usesOnlineAI
    }
    check("Pi routing rejects malformed saved provider selections and never copies credentials") {
        let base = root.appendingPathComponent("bad-provider-settings")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let bad = PiModelSelection(providerID: "openai\n", modelID: "fixture", providerName: "OpenAI")
        guard !bad.isValid, (try? InferenceSettings(piModel: bad).save(to: base)) == nil else { return false }
        try Data(#"{"policy":"localOnly","piModel":{"providerID":"","modelID":"fixture","providerName":"OpenAI"}}"#.utf8)
            .write(to: base.appendingPathComponent("inference-settings.json"))
        guard !InferenceSettings.load(from: base).usesOnlineAI else { return false }
        try InferenceSettings(piModel: .init(providerID: "xai", modelID: "grok-fixture", providerName: "xAI")).save(to: base)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("inference-settings.json"))) as? [String: Any]
        return object?["apiKey"] == nil && object?["credential"] == nil && object?["token"] == nil
    }
    check("Pi provider presentation prioritizes requested providers while retaining unknown providers") {
        let data = Data(#"[{"id":"new-provider","name":"New","configured":false,"methods":[],"models":[]},{"id":"pippa-online","name":"Old","configured":true,"methods":[],"models":[]},{"id":"xai","name":"xAI","configured":false,"methods":[],"models":[]},{"id":"anthropic","name":"Anthropic","configured":true,"methods":[],"models":[]}]"#.utf8)
        let providers = PiProvider.ordered(try JSONDecoder().decode([PiProvider].self, from: data))
        return providers.map(\.id) == ["anthropic", "xai", "new-provider"]
    }
    let environment = ProcessInfo.processInfo.environment
    guard let nodePath = environment["PIPPA_NODE_BINARY"] ?? PiPayload.locate(environment: environment)?.node.path
            ?? (environment["PATH"] ?? "").split(separator: ":").map({ String($0) + "/node" }).first(where: FileManager.default.isExecutableFile),
          FileManager.default.isExecutableFile(atPath: nodePath) else {
        failures += 1; print("✗ Provider checks require PIPPA_NODE_BINARY or PIPPA_PI_PAYLOAD"); return
    }
    let folder = root.appendingPathComponent("provider-bridge")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func client(_ script: String) -> PiProviderClient {
        let file = folder.appendingPathComponent("helper-\(UUID().uuidString).mjs")
        try! ("const out = value => process.stdout.write(JSON.stringify(value) + '\\n');\nsetTimeout(()=>process.exit(3),2500).unref();\n" + script).write(to: file, atomically: true, encoding: .utf8)
        return PiProviderClient(node: URL(fileURLWithPath: nodePath), release: folder, helper: file,
                                environment: ["HOME": folder.path, "PATH": "/usr/bin:/bin"])
    }
    await checkAsync("Provider bridge carries a secret through stdin and accepts a final prompt dismissal") {
        let helper = client("""
            out({event:'prompt',id:'key',type:'secret',message:'Key'});
            process.stdin.setEncoding('utf8'); let input='';
            process.stdin.on('data', chunk => { input+=chunk; if(!input.includes('\\n')) return;
              const reply=JSON.parse(input.trim());
              if(reply.id!=='key' || reply.value!=='fixture-secret' || process.argv.includes(reply.value)) process.exit(2);
              out({event:'done'}); out({event:'dismiss',id:'key'}); process.exit(0);
            });
            """)
        let received = LockedBox<[String]>([])
        let event = try await helper.run(["login", "openrouter", "api_key"]) { event in
            received.mutate { $0.append(event.event ?? "") }
            if event.event == "prompt", let id = event.id { try? helper.respond(id: id, value: "fixture-secret") }
        }
        return event.event == "done" && received.value == ["prompt", "done", "dismiss"]
    }
    await checkAsync("Provider bridge cancellation ends the process and cannot be lost before launch") {
        let before = client("out({event:'done'});")
        before.cancel()
        do { _ = try await before.run(["catalog"]); return false } catch PiProviderClient.Failure.cancelled {} catch { return false }
        let ready = LockedBox(false)
        let hanging = client("out({event:'progress',message:'ready'}); setInterval(()=>{},1000); process.on('SIGTERM',()=>{out({event:'error',code:'cancelled'});process.exit(0)});")
        let task = Task { try await hanging.run(["login", "openai", "oauth"]) { _ in ready.mutate { $0 = true } } }
        for _ in 0..<100 { if ready.value { break }; try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        do { _ = try await task.value; return false } catch { return ready.value }
    }
    await checkAsync("Provider bridge maps authentication failures without exposing raw provider errors") {
        do { _ = try await client("out({event:'error',code:'port_busy'});process.exit(1);").run(["login"]); return false }
        catch PiProviderClient.Failure.portBusy { return true }
        catch { return false }
    }
    if let payload = environment["PIPPA_PI_PAYLOAD"] {
        await checkAsync("Bundled Pi catalog reaches Swift with real provider methods and no model requests") {
            let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let helper = checkout.appendingPathComponent("runtime/pippa-auth/pi-providers.mjs")
            let actual = PiProviderClient(node: URL(fileURLWithPath: nodePath), release: URL(fileURLWithPath: payload).appendingPathComponent("release"), helper: helper,
                                          environment: ["HOME": folder.path, "PATH": "/usr/bin:/bin", "PI_CODING_AGENT_DIR": folder.appendingPathComponent("agent").path, "PI_OFFLINE": "1", "PI_TELEMETRY": "0"])
            let result = try await actual.run(["catalog"])
            guard let providers = result.providers else { return false }
            return ["anthropic", "openai", "openrouter", "opencode", "xai"].allSatisfy { id in providers.contains { $0.id == id && !$0.methods.isEmpty } }
                && providers.first(where: { $0.id == "openai" })?.methods.contains(where: { $0.id == "oauth" }) == true
        }
    }
}
