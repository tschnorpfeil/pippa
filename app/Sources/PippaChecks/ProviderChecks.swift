import Foundation
import PippaCore

func runProviderChecks() async {
    check("Provider errors preserve expired-login and usage-limit guidance") {
        PiProviderClient.problem(in: "401 Unauthorized: token expired") == .signedOut
            && PiProviderClient.problem(in: "invalid_grant: refresh token revoked") == .signedOut
            && PiProviderClient.problem(in: "No API key found for openai") == .signedOut
            && PiProviderClient.problem(in: "socket hang up") == nil
    }
    check("A rate limit waits and continues; a used-up allowance is told apart, also when it comes as 429") {
        ["429 Too Many Requests", "Rate limit exceeded, retry later", "too many requests", "{\"type\":\"rate_limit_error\"}",
         "429 Rate limit reached for gpt-4o in organization org-x on requests per min (RPM): Limit 500"]
            .allSatisfy { PiProviderClient.problem(in: $0) == .rateLimit }
            && ["You have reached your usage limit", "insufficient_quota", "Monthly limit reached", "Billing hard limit hit",
                "429 Too Many Requests: usage limit reached", "Rate limit: your quota is used up",
                "{\"type\":\"usage_limit_reached\"}", "FreeUsageLimitError", "429 insufficient_quota"]
            .allSatisfy { PiProviderClient.problem(in: $0) == .quota }
            && PiProviderClient.problem(in: "429 Resource has been exhausted (e.g. check quota).") == .rateLimit
            && ["connect ECONNREFUSED 127.0.0.1:8429", "request id req_42900a failed", "read 14290 bytes"]
            .allSatisfy { PiProviderClient.problem(in: $0) == nil }
    }
    check("After Sign in with ChatGPT the model in use stays, else Pi's default is preselected, never the oldest on the list") {
        let models = ["gpt-4", "gpt-5.5", "o3"].map { PiProvider.Model(id: $0, name: $0) }
        let openai = PiProvider(id: "openai", name: "OpenAI", configured: true, methods: [], models: models, defaultModel: "gpt-5.5")
        let unknownDefault = PiProvider(id: "x", name: "X", configured: true, methods: [], models: models, defaultModel: "gone")
        let decoded = try? JSONDecoder().decode(PiProvider.self, from: Data(#"{"id":"a","name":"A","configured":false,"methods":[],"models":[]}"#.utf8))
        return openai.preselected("o3") == "o3" && openai.preselected(nil) == "gpt-5.5" && openai.preselected("removed") == "gpt-5.5"
            && unknownDefault.preselected(nil) == "" && decoded?.defaultModel == nil
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
    check("Optional abilities: older settings keep both on for both routes, and each switch saves on its own") {
        let base = root.appendingPathComponent("capability-settings")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appendingPathComponent("inference-settings.json")
        try Data(#"{"policy":"localOnly","piModel":{"providerID":"openrouter","modelID":"fixture","providerName":"OpenRouter"}}"#.utf8).write(to: file)
        let legacy = InferenceSettings.load(from: base)
        guard legacy.activePiModel?.providerID == "openrouter", legacy.capabilities == OptionalCapabilities(),
              [false, true].allSatisfy({ legacy.capabilities[online: $0] == .init(web: true, memory: true) }) else { return false }
        try Data(#"{"policy":"localOnly","capabilities":{"local":{"web":false}}}"#.utf8).write(to: file)
        let partial = InferenceSettings.load(from: base).capabilities
        guard partial.local == .init(web: false, memory: true), partial.online == .init() else { return false }
        var settings = legacy
        settings.capabilities[online: false].memory = false
        settings.capabilities[online: true].web = false
        try settings.save(to: base)
        let saved = InferenceSettings.load(from: base)
        return saved.activePiModel == legacy.activePiModel
            && saved.capabilities.local == .init(web: true, memory: false) && saved.capabilities.online == .init(web: false, memory: true)
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
    check("First run leads with this Mac when it can run the AI, else with online AI, and never shows setup to people already online") {
        let unsupported = PiSetupState.failed(PiSetupProblem(message: "Too little memory", details: "No local model fits this Mac", canRetry: false))
        let retryable = PiSetupState.failed(PiSetupProblem(.notEnoughSpace(bytes: 1)))
        let open: [PiSetupState] = [.askDownload(bytes: 5_400_000_000), .downloading(progress: 0.4, remaining: 60), retryable, unsupported]
        let online = InferenceSettings(piModel: .init(providerID: "anthropic", modelID: "fixture", providerName: "Anthropic"))
        let chatGPT = InferenceSettings(subscriptionModel: "gpt-fixture")
        return FirstRunSetup.lead(.askDownload(bytes: 1)) == .local && FirstRunSetup.lead(.downloading(progress: 0, remaining: nil)) == .local
            && FirstRunSetup.lead(retryable) == .local && FirstRunSetup.lead(unsupported) == .online
            && open.allSatisfy { FirstRunSetup.needsAttention($0, usesOnlineAI: false) }
            && [online, chatGPT].allSatisfy { $0.usesOnlineAI && open.allSatisfy { !FirstRunSetup.needsAttention($0, usesOnlineAI: true) } }
            && !FirstRunSetup.needsAttention(.ready(adoptedFrom: nil), usesOnlineAI: false)
            && !FirstRunSetup.needsAttention(.preparing(adoptingFrom: nil), usesOnlineAI: false)
    }
    check("First-run sheet offers signed-in providers first, then ones Pippa can sign into, at most four") {
        let login = [PiProvider.Method(id: "api_key", name: "API key")]
        let providers = [
            PiProvider(id: "custom", name: "Custom", configured: false, methods: [], models: []),
            PiProvider(id: "xai", name: "xAI", configured: false, methods: login, models: []),
            PiProvider(id: "openai", name: "OpenAI", configured: false, methods: login, models: []),
            PiProvider(id: "openrouter", name: "OpenRouter", configured: true, methods: login, models: []),
            PiProvider(id: "pippa-online", name: "Old", configured: true, methods: [], models: []),
            PiProvider(id: "anthropic", name: "Anthropic", configured: false, methods: login, models: []),
            PiProvider(id: "google", name: "Google", configured: false, methods: login, models: []),
        ]
        return FirstRunSetup.recommended(providers).map(\.id) == ["openrouter", "anthropic", "openai", "google"]
    }
    check("First-run sheet: sign-in never switches the route; cancel and failure return to sign-in; Use <provider> activates the recommended model") {
        let login = [PiProvider.Method(id: "oauth", name: "Sign in")]
        let models = [PiProvider.Model(id: "old", name: "Old"), PiProvider.Model(id: "best", name: "Best")]
        let signedOut = PiProvider(id: "openai", name: "OpenAI", configured: false, methods: login, models: [])
        let signedIn = PiProvider(id: "openai", name: "OpenAI", configured: true, methods: login, models: models, defaultModel: "best")
        let noDefault = PiProvider(id: "openai", name: "OpenAI", configured: true, methods: login, models: models)
        let empty = PiProvider(id: "openai", name: "OpenAI", configured: true, methods: login, models: [])
        func stage(_ list: [PiProvider], _ picked: PiProvider?, model: String = "", loading: Bool = false, connecting: Bool = false,
                   failed: Bool = false, active: PiModelSelection? = nil) -> FirstRunSetup.OnlineStage {
            FirstRunSetup.onlineStage(providers: list, picked: picked, modelID: model, loading: loading, connecting: connecting,
                                      failed: failed, active: active)
        }
        let inUse = PiModelSelection(providerID: "openai", modelID: "best", providerName: "OpenAI")
        let other = PiModelSelection(providerID: "anthropic", modelID: "fixture", providerName: "Anthropic")
        let external = PiProvider(id: "external", name: "External", configured: false, methods: [], models: [])
        guard stage([external], nil) == .unavailable, stage([], nil, loading: true) == .loading, stage([], nil, failed: true) == .unavailable,
              stage([signedOut], nil) == .choose, stage([signedOut], signedOut) == .signIn(signedOut),
              stage([signedOut], signedOut, connecting: true) == .signingIn(signedOut),
              // Cancelled or failed sign-in: back to the same buttons, nothing saved.
              stage([signedOut], signedOut, failed: true) == .signIn(signedOut),
              stage([empty], empty) == .noModels(empty), stage([noDefault], noDefault, model: noDefault.preselected(nil)) == .chooseModel(noDefault),
              stage([signedIn], signedIn, model: signedIn.preselected(nil)) == .activate(signedIn, model: models[1]),
              // Someone online elsewhere stays there until they click Use OpenAI.
              stage([signedIn], signedIn, model: "best", active: other) == .activate(signedIn, model: models[1]),
              stage([signedIn], signedIn, model: "best", active: inUse) == .inUse(signedIn) else { return false }
        var before = InferenceSettings(subscriptionModel: "gpt-legacy")
        before.capabilities[online: true].web = false
        before.capabilities[online: false].memory = false
        before.connection = ModelConnection(provider: .openAI, endpoint: URL(string: "https://example.invalid/v1"), modelID: "own")
        let after = FirstRunSetup.activated(before, provider: signedIn, model: models[1])
        return after.activePiModel == PiModelSelection(providerID: "openai", modelID: "best", providerName: "OpenAI", modelName: "Best")
            && after.subscriptionModel == nil && after.policy == .localOnly && after.capabilities == before.capabilities
            && after.connection == before.connection
            && after.activePiModel?.launchArguments == ["--provider", "openai", "--model", "best"]
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
