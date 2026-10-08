import Foundation
import PippaCore

/// Own online service only through Pippa's proxy, model choice on the RPC path. No network, no Pi, no keychain;
/// the proxy is only created, not started. End to end: PiRPCR10Spike.
@MainActor func runR10Checks() async {
    let base = root.appendingPathComponent("r10", isDirectory: true)
    try? fm.createDirectory(at: base, withIntermediateDirectories: true)
    let openAI = ModelConnection(provider: .openAI, modelID: "gpt-x")
    let anthropic = ModelConnection(provider: .anthropic, modelID: "claude-x")
    let compatible = ModelConnection(provider: .compatible, endpoint: URL(string: "https://llm.example/api/v1/"), modelID: "m")

    check("models.json: pippa-online points to 127.0.0.1, key only as !command from Pippa's environment, API per service") {
        let o = PiOnlineProvider.entry(openAI, port: 40001), a = PiOnlineProvider.entry(anthropic, port: 40001)
        return o["baseUrl"] as? String == "http://127.0.0.1:40001/v1" && o["api"] as? String == "openai-completions"
            && a["baseUrl"] as? String == "http://127.0.0.1:40001" && a["api"] as? String == "anthropic-messages"
            && (o["apiKey"] as? String) == "!printf '%s' \"$PIPPA_ONLINE_TOKEN\""
            && !String(describing: o).contains("api.openai.com") && !String(describing: a).contains("api.anthropic.com")
            && PiOnlineProvider.launchArguments(openAI) == ["--provider", "pippa-online", "--model", "gpt-x"]
    }
    check("models.json: adding and removing only touches pippa-online; an unreadable file stays unchanged") {
        let url = base.appendingPathComponent("models.json")
        let original = #"{"providers":{"pippa-local":{"baseUrl":"http://127.0.0.1:1/v1"},"ollama":{"apiKey":"x"}},"other":1}"#
        try Data(original.utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        guard try PiOnlineProvider.sync(openAI, port: 40002, modelsJSON: url), try !PiOnlineProvider.sync(openAI, port: 40002, modelsJSON: url) else { return false }
        let mode = (try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let providers = written?["providers"] as? [String: Any]
        guard providers?["pippa-local"] != nil, providers?["ollama"] != nil, providers?["pippa-online"] != nil,
              written?["other"] as? Int == 1, mode == 0o640 else { return false }
        guard try PiOnlineProvider.sync(nil, port: 0, modelsJSON: url), PiOnlineProvider.current(modelsJSON: url) == nil,
              PiInstaller.providerModelIDs(modelsJSON: url).isEmpty, (try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])?["other"] as? Int == 1
        else { return false }
        let broken = base.appendingPathComponent("broken.json")
        try Data("{ // comment\n}".utf8).write(to: broken)
        let unreadable = (try? PiOnlineProvider.sync(openAI, port: 1, modelsJSON: broken)) == nil
        let missing = base.appendingPathComponent("missing.json")
        let brokenText = String(decoding: try Data(contentsOf: broken), as: UTF8.self)
        let removedMissing = try PiOnlineProvider.sync(nil, port: 0, modelsJSON: missing)
        return unreadable && brokenText == "{ // comment\n}" && !removedMissing && !fm.fileExists(atPath: missing.path)
    }
    check("Path: off = local; \"ask\" and \"always\" both go through the proxy (asks every time)") {
        PiOnlineProvider.activeConnection(InferenceSettings(policy: .localOnly, connection: openAI)) == nil
            && PiOnlineProvider.activeConnection(InferenceSettings(policy: .ask, connection: openAI)) == openAI
            && PiOnlineProvider.activeConnection(InferenceSettings(policy: .customAlways, connection: openAI)) == openAI
            && PiOnlineProvider.activeConnection(InferenceSettings(policy: .ask, connection: nil)) == nil
    }

    func proxy(_ connection: ModelConnection) throws -> PippaOnlineProxy {
        try PippaOnlineProxy(connection: connection, port: 40003, needsApproval: true, token: "t0ken",
                             credential: { nil }, decide: { _ in .deny })
    }
    func request(_ method: String = "POST", path: String = "/v1/chat/completions", headers: [String: String]) -> PippaHTTPRequest {
        PippaHTTPRequest(method: method, path: path, headers: headers, body: Data("{}".utf8))
    }
    check("Proxy: loopback host only, no browser, only with the access token, only POST on the one path") {
        let p = try proxy(openAI)
        let ok = ["host": "127.0.0.1:40003", "authorization": "Bearer t0ken", "content-type": "application/json"]
        func status(_ r: PippaHTTPRequest) -> Int? { p.admission(r, port: 40003)?.status }
        return status(request(headers: ok)) == nil
            && status(request(headers: ok.merging(["authorization": "Bearer nope"]) { $1 })) == 401
            && status(request(headers: ok.filter { $0.key != "authorization" }.merging(["x-api-key": "t0ken"]) { $1 })) == nil
            && status(request(headers: ok.merging(["origin": "https://evil.example"]) { $1 })) == 403
            && status(request(headers: ok.merging(["host": "evil.example:40003"]) { $1 })) == 403
            && status(request("GET", headers: ok)) == 405
            && status(request(path: "/v1/embeddings", headers: ok)) == 404
            && status(request(path: "/v1/chat/completions?x=1", headers: ok)) == 404
            && status(request(headers: ok.merging(["content-type": "text/plain"]) { $1 })) == 415
    }
    check("Proxy: upstream paths per service (OpenAI, Anthropic with ?beta=true, compatible with its own path)") {
        let o = try proxy(openAI), a = try proxy(anthropic), c = try proxy(compatible)
        return o.upstreamURL(for: "/v1/chat/completions")?.absoluteString == "https://api.openai.com/v1/chat/completions"
            && a.upstreamURL(for: "/v1/messages?beta=true")?.absoluteString == "https://api.anthropic.com/v1/messages?beta=true"
            && a.upstreamURL(for: "/v1/messages?evil=1") == nil && a.upstreamURL(for: "/v1/complete") == nil
            && c.upstreamURL(for: "/v1/chat/completions")?.absoluteString == "https://llm.example/api/v1/chat/completions"
            && o.upstreamURL(for: "/chat/completions") == nil
    }
    check("Proxy: \"No\" as an error in the service's shape; sentence without words that make Pi retry") {
        let o = try proxy(openAI).errorResponse(403, PippaOnlineProxy.declinedMessage)
        let a = try proxy(anthropic).errorResponse(403, PippaOnlineProxy.declinedMessage)
        let oj = try JSONSerialization.jsonObject(with: o.body) as? [String: Any]
        let aj = try JSONSerialization.jsonObject(with: a.body) as? [String: Any]
        let message = PippaOnlineProxy.declinedMessage.lowercased()
        let retry = ["overloaded", "rate", "429", "500", "502", "503", "504", "timeout", "timed out", "terminated", "connection", "network",
                     "fetch failed", "socket", "unavailable", "server error", "internal error"]
        return o.status == 403 && (oj?["error"] as? [String: Any])?["message"] as? String == PippaOnlineProxy.declinedMessage
            && aj?["type"] as? String == "error" && (aj?["error"] as? [String: Any])?["message"] as? String == PippaOnlineProxy.declinedMessage
            && !retry.contains { message.contains($0) } && !message.contains(where: \.isNumber)
    }
    check("Card: counts messages, tool results, images; names shown items, also with umlauts and quotation marks") {
        let shown = [URL(fileURLWithPath: "/Users/x/Brief Hausverwaltung.pdf"), URL(fileURLWithPath: "/Users/x/Kündigung \"alt\".pdf"),
                     URL(fileURLWithPath: "/Users/x/nicht-dabei.txt")]
        let openAIBody: [String: Any] = ["model": "gpt-x", "messages": [
            ["role": "system", "content": "Du bist Pippa"],
            ["role": "user", "content": "Gezeigt: /Users/x/Brief Hausverwaltung.pdf"],
            ["role": "assistant", "content": "", "tool_calls": []],
            ["role": "tool", "content": "Text aus Kündigung \"alt\".pdf"],
            ["role": "user", "content": [["type": "text", "text": "und das Bild"], ["type": "image_url", "image_url": ["url": "data:"]]]]]]
        let o = PippaOnlineAsk.make(PippaOnlineOutgoing(connection: openAI, body: try JSONSerialization.data(withJSONObject: openAIBody)), shown: shown)
        let anthropicBody: [String: Any] = ["model": "claude-x", "system": "Pippa", "messages": [
            ["role": "user", "content": [["type": "text", "text": "Hallo"]]],
            ["role": "assistant", "content": [["type": "tool_use", "id": "1", "name": "read", "input": [:]]]],
            ["role": "user", "content": [["type": "tool_result", "tool_use_id": "1", "content": [["type": "image", "source": [:]]]]]]]]
        let a = PippaOnlineAsk.make(PippaOnlineOutgoing(connection: anthropic, body: try JSONSerialization.data(withJSONObject: anthropicBody)), shown: shown)
        return o.messages == 4 && o.toolResults == 1 && o.images == 1 && o.model == "gpt-x" && o.service == "OpenAI"
            && o.shownIncluded == ["Brief Hausverwaltung.pdf", "Kündigung \"alt\".pdf"]
            && a.messages == 3 && a.toolResults == 1 && a.images == 1 && a.shownIncluded.isEmpty && a.service == "Anthropic"
            && PippaOnlineAsk.make(PippaOnlineOutgoing(connection: compatible, body: Data()), shown: []).service == "llm.example"
    }
    check("\"For this conversation\": applies only to this conversation, this connection and exactly what was shown") {
        var grants = PippaOnlineGrants()
        let file = URL(fileURLWithPath: "/tmp/a.pdf")
        grants.grant(conversation: "c1", connection: openAI, shown: [file])
        var changed = openAI
        changed.modelID = "gpt-y"
        let ok = grants.allows(conversation: "c1", connection: openAI, shown: [file])
            && !grants.allows(conversation: "c2", connection: openAI, shown: [file])
            && !grants.allows(conversation: "c1", connection: openAI, shown: [file, URL(fileURLWithPath: "/tmp/b.pdf")])
            && !grants.allows(conversation: "c1", connection: changed, shown: [file])
        grants.removeAll()
        return ok && !grants.allows(conversation: "c1", connection: openAI, shown: [file])
    }
    check("Receipt from code: \"Online gefragt: …\", \"Nicht online gefragt: … (du hast abgelehnt)\", one line per result, never undoable") {
        let items = PippaOnlineRecord.receiptItems([.init(service: "OpenAI", outcome: .done, bytes: 1), .init(service: "OpenAI", outcome: .done, bytes: 2),
                                                    .init(service: "OpenAI", outcome: .declined, bytes: 3)])
        let de = ActionReceipt(items: items).lines(language: "de").map(\.text)
        let en = ActionReceipt(items: [ActionReceipt.Item(action: "online", outcome: "failed", name: "Anthropic")]).lines(language: "en").map(\.text)
        return de == ["Online gefragt: OpenAI", "Nicht online gefragt: OpenAI (du hast abgelehnt)"] && en == ["Asked online: Anthropic (didn’t work)"]
            && !items.contains(where: \.canUndo)
    }
    check("Model choice removed: an old choice (piModel, modelOverride) in settings.json is read and ignored; the table applies") {
        let gib: UInt64 = 1_073_741_824
        let old = base.appendingPathComponent("old-settings", isDirectory: true)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try Data(#"{"llamaPort":1234,"piModel":"qwen3.5-4b-q4","modelOverride":"qwen3.5-9b-q4","automaticChosen":true}"#.utf8)
            .write(to: old.appendingPathComponent("settings.json"))
        let loaded = PippaSettings.load(from: old)
        try loaded.save(to: old)
        let rewritten = String(decoding: try Data(contentsOf: old.appendingPathComponent("settings.json")), as: UTF8.self)
        return loaded.llamaPort == 1234 && PippaSettings.load(from: old).llamaPort == 1234
            && !rewritten.contains("piModel") && !rewritten.contains("modelOverride")
            && PiSetupFlow.choice(override: nil, physicalMemory: 24 * gib)?.model.key == "gemma-4-12b"
            && PiSetupFlow.choice(override: nil, physicalMemory: 8 * gib)?.model.key == "qwen3.5-4b-q4"
    }

    // MARK: Card (PippaOnlineDesk)

    func outgoing(_ text: String) -> PippaOnlineOutgoing {
        let body: [String: Any] = ["model": "gpt-x", "messages": [["role": "user", "content": text]]]
        return PippaOnlineOutgoing(connection: openAI, body: (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
    }
    let shownFile = URL(fileURLWithPath: "/tmp/r10/Mietvertrag.pdf")
    func deskCheck1() async throws -> Bool {
        let desk = PippaOnlineDesk()
        desk.answerAutomatically = { _ in .once }
        guard await desk.decide(outgoing("Hallo")) == .deny else { return false }   // no answer in progress
        desk.begin(.init(conversation: "c1", shown: [shownFile]))
        let a = await desk.decide(outgoing("Hallo")), b = await desk.decide(outgoing("Hallo und Werkzeugergebnis"))
        guard a == .allow, b == .allow, desk.cardsShown == 1 else { return false }
        let c = await desk.decide(outgoing("Inhalt aus Mietvertrag.pdf"))
        guard c == .allow, desk.cardsShown == 2, await desk.decide(outgoing("Mietvertrag.pdf noch einmal")) == .allow, desk.cardsShown == 2 else { return false }
        desk.end()
        desk.begin(.init(conversation: "c1", shown: [shownFile]))
        _ = await desk.decide(outgoing("Hallo"))
        return desk.cardsShown == 3
    }
    let deskResult1 = (try? await deskCheck1()) ?? false
    check("Card: \"Only this time\" applies to all rounds of the message; new card only for newly included shown items; then it expires") { deskResult1 }
    func deskCheck2() async throws -> Bool {
        let desk = PippaOnlineDesk()
        desk.begin(.init(conversation: "c1", shown: []))
        let first = Task { await desk.decide(outgoing("Hallo")) }
        while desk.open == nil { await Task.yield() }
        let second = Task { await desk.decide(outgoing("Hallo")) }
        for _ in 0..<50 { await Task.yield() }
        guard desk.cardsShown == 1 else { return false }
        desk.answer(.deny)
        let results = (await first.value, await second.value)
        return results == (.deny, .deny) && desk.cardsShown == 1 && desk.open == nil
    }
    let deskResult2 = (try? await deskCheck2()) ?? false
    check("Card: if Pi asks again while a card is open (timeout), no second card; one answer applies to both") { deskResult2 }
    func deskCheck3() async throws -> Bool {
        let desk = PippaOnlineDesk()
        var switches = 0
        desk.switchToLocal = { _ in switches += 1; return true }
        desk.answerAutomatically = { _ in .local }
        desk.begin(.init(conversation: "c1", shown: []))
        let a = await desk.decide(outgoing("Hallo")), b = await desk.decide(outgoing("Hallo"))
        guard a == .local, b == .local, switches == 1, desk.cardsShown == 1 else { return false }
        desk.end()
        desk.switchToLocal = { _ in false }
        desk.begin(.init(conversation: "c1", shown: []))
        return await desk.decide(outgoing("Hallo")) == .deny
    }
    let deskResult3 = (try? await deskCheck3()) ?? false
    check("Card: \"On this Mac\" switches once; further requests of this answer do not go out; failed = No") { deskResult3 }
    func deskCheck4() async throws -> Bool {
        let desk = PippaOnlineDesk()
        desk.begin(.init(conversation: "c1", shown: []))
        let pending = Task { await desk.decide(outgoing("Hallo")) }
        while desk.open == nil { await Task.yield() }
        desk.end()
        return await pending.value == .deny && desk.open == nil
    }
    let deskResult4 = (try? await deskCheck4()) ?? false
    check("Card: end of the answer closes an open card as \"No\"") { deskResult4 }
}
