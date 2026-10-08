import Foundation
import Network
import PiRPC
import PippaCore

// R10 end-to-end probe: own online service only through Pippa's approval.
// Everything in a fake HOME under .build (`R10_HOME`), models from ~/Library/Caches/pippa-live read only (APFS clone),
// no real online service and no real key: stand-in services (an OpenAI-compatible server on 127.0.0.1 and
// a URLProtocol for the https addresses of OpenAI and Anthropic, no network). The test key lives in the keychain only during
// the run, under a service name used for tests only, and is deleted afterwards.
//
//   scripts/pi-rpc-spike.sh r10 [s|p|all]
//
// p: proxy: approval "Once only", "No", "For this conversation", newly shown items; streaming; Anthropic and OpenAI
//    (stand-in via URLProtocol); origin check; Pi in a terminal without Pippa; key never on disk, in the log or in
//    Pi's environment.

setvbuf(stdout, nil, _IOLBF, 0)
let env = ProcessInfo.processInfo.environment
let which = CommandLine.arguments.dropFirst().first ?? "all"
let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let home = URL(fileURLWithPath: env["R10_HOME"] ?? repo.appendingPathComponent(".build/r10-home").path, isDirectory: true)
let cache = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches/pippa-live", isDirectory: true)
let logDir = URL(fileURLWithPath: env["PIPPA_LOG_DIR"] ?? repo.appendingPathComponent(".build/r10-logs").path, isDirectory: true)
let clock = ContinuousClock()
func ms(_ d: Duration) -> Int { Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000) }
func oneLine(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ⏎ ") }

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ what: String) {
    print("  \(ok ? "✓" : "✗") \(what)")
    if !ok { failures += 1 }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock(); private var value: T
    init(_ v: T) { value = v }
    var get: T { lock.withLock { value } }
    func set(_ f: (inout T) -> Void) { lock.withLock { f(&value) } }
}

guard let payload = PiPayload.locate(environment: env) else { print("PIPPA_PI_PAYLOAD fehlt"); exit(2) }
let roots = PiInstallRoots(home: home, payload: payload, searchPath: [home.appendingPathComponent(".local/bin")])
let cacheModels = [ModelLocation(url: cache.appendingPathComponent("models", isDirectory: true), source: "Testcache")]
let guardPath = repo.appendingPathComponent("runtime/pippa-guard/pippa-guard.ts")
let work = home.appendingPathComponent("work", isDirectory: true)
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)

/// Pi as in the app (PippaPiLaunch.configuration with guard and file tools), without a session on disk.
func piConfiguration(_ spec: PiLaunchSpec, piArguments: [String]? = nil, extra: [String: String] = [:]) -> PiRPCConfiguration {
    let launcher = PippaPiLaunch.Launcher(executable: spec.executable, launcherArguments: spec.launcherArguments,
                                          piArguments: piArguments ?? spec.piArguments, environment: spec.environment)
    let paths = PippaPiLaunch.Paths(guardExtension: guardPath, toolsExtension: guardPath.deletingLastPathComponent().appendingPathComponent("pippa-tools.ts"),
                                    sessionDirectory: home.appendingPathComponent("sessions", isDirectory: true))
    var environment = ["PI_CODING_AGENT_DIR": roots.agentDirectory.path, "PIPPA_UNDO_DIR": home.appendingPathComponent("undo").path,
                       "PIPPA_TRASH_DIR": home.appendingPathComponent("trash").path]
    environment.merge(extra) { $1 }
    return PippaPiLaunch.configuration(launcher: launcher, workingDirectory: work, paths: paths, sessionID: nil, language: "de", environment: environment)
}

struct Turn { var text: String; var deltas: [(Int, String)]; var stop: String; var error: String? }

func ask(_ client: PiRPCClient, _ prompt: String) async throws -> Turn {
    let start = clock.now
    var turn = Turn(text: "", deltas: [], stop: "", error: nil)
    for try await event in try await client.prompt(prompt) {
        switch event {
        case .textDelta(let d): turn.text += d; turn.deltas.append((ms(clock.now - start), d))
        case .assistantEnded(_, let reason, let error): turn.stop = reason; turn.error = error
        default: break
        }
    }
    return turn
}

func writeAgentSettings() throws {
    try FileManager.default.createDirectory(at: roots.agentDirectory, withIntermediateDirectories: true)
    try Data("{\n  \"defaultProjectTrust\": \"never\",\n  \"quietStartup\": true\n}\n".utf8)
        .write(to: roots.agentDirectory.appendingPathComponent("settings.json"))
}

// MARK: s — dropped: model choice no longer exists (docs/settings-simplification.md), the model is dictated by the
// table by memory (`ModelSelector.choose`).

@discardableResult
func shell(_ tool: String, _ arguments: [String], environment: [String: String]? = nil) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = arguments
    p.standardInput = FileHandle.nullDevice
    if let environment { p.environment = environment }
    let pipe = Pipe()
    p.standardOutput = pipe; p.standardError = pipe
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

// MARK: Stand-in services

/// What a stand-in service received (for the checks only; the key is compared, never printed).
struct Received: Sendable { var path: String; var authorization: String?; var apiKey: String?; var version: String?; var bytes: Int }
let received = Box<[Received]>([])
/// Cases 6/7: if a path is set and the person's request ends with "LIES …", the stand-in service calls Pi's `read`.
let stubToolPath = Box<String?>(nil)

func toolCallEvents(model: String, path: String) -> [String] {
    let args = String(decoding: try! JSONSerialization.data(withJSONObject: ["path": path], options: [.withoutEscapingSlashes]), as: UTF8.self)
    let escaped = String(decoding: try! JSONSerialization.data(withJSONObject: [args], options: [.withoutEscapingSlashes]), as: UTF8.self).dropFirst().dropLast()
    return ["data: {\"id\":\"c2\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"\(model)\",\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\(escaped)}}]},\"finish_reason\":null}]}\n\n",
            "data: {\"id\":\"c2\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"\(model)\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n",
            "data: [DONE]\n\n"]
}
let words = ["Hallo", " aus", " dem", " Ersatz", "-Dienst", "."]

func openAIEvents(model: String) -> [String] {
    var events = words.enumerated().map { i, w in
        "data: {\"id\":\"c1\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"\(model)\",\"choices\":[{\"index\":0,\"delta\":{\(i == 0 ? "\"role\":\"assistant\"," : "")\"content\":\"\(w)\"},\"finish_reason\":null}]}\n\n"
    }
    events.append("data: {\"id\":\"c1\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"\(model)\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":6,\"total_tokens\":16}}\n\n")
    events.append("data: [DONE]\n\n")
    return events
}

func anthropicEvents() -> [String] {
    var events = ["event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[],\"model\":\"stub\",\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":10,\"output_tokens\":1}}}\n\n",
                  "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"]
    events += words.map { "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\($0)\"}}\n\n" }
    events += ["event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
               "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":6}}\n\n",
               "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"]
    return events
}

/// An OpenAI-compatible stand-in service on 127.0.0.1: SSE in chunks 300 ms apart (streaming visible).
final class StubServer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "r10.stub")
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }
    var port: UInt16 { listener.port?.rawValue ?? 0 }
    func start() async throws {
        listener.newConnectionHandler = { [self] c in c.start(queue: queue); receive(c, Data()) }
        listener.start(queue: queue)
        while listener.port == nil || listener.port?.rawValue == 0 { try await Task.sleep(for: .milliseconds(20)) }
    }
    func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, done, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            switch PippaHTTPRequest.parse(buffer) {
            case .incomplete: if done || error != nil { c.cancel() } else { receive(c, buffer) }
            case .invalid: c.cancel()
            case .complete(let r):
                received.set { $0.append(Received(path: r.path, authorization: r.headers["authorization"], apiKey: r.headers["x-api-key"],
                                                  version: r.headers["anthropic-version"], bytes: r.body.count)) }
                let object = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any]
                let model = object?["model"] as? String ?? "stub"
                let last = (object?["messages"] as? [[String: Any]])?.last
                let lastText = last.flatMap { try? JSONSerialization.data(withJSONObject: $0) }.map { String(decoding: $0, as: UTF8.self) } ?? ""
                c.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n".utf8), completion: .idempotent)
                let events = if let path = stubToolPath.get, last?["role"] as? String == "user", lastText.contains("LIES") {
                    toolCallEvents(model: model, path: path)
                } else { openAIEvents(model: model) }
                for (i, e) in events.enumerated() {
                    queue.asyncAfter(deadline: .now() + .milliseconds(300 * i)) {
                        c.send(content: Data(e.utf8), completion: .contentProcessed { _ in if i == events.count - 1 { c.cancel() } })
                    }
                }
            }
        }
    }
}

/// Stand-in for https://api.openai.com and https://api.anthropic.com in the proxy's URLSession: never the network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; body.append(buffer, count: n) }
            stream.close()
        }
        let url = request.url!
        received.set { $0.append(Received(path: url.path + (url.query.map { "?" + $0 } ?? ""), authorization: request.value(forHTTPHeaderField: "Authorization"),
                                          apiKey: request.value(forHTTPHeaderField: "x-api-key"), version: request.value(forHTTPHeaderField: "anthropic-version"),
                                          bytes: body.count)) }
        guard url.host == "api.openai.com" || url.host == "api.anthropic.com" else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let events = url.host == "api.anthropic.com" ? anthropicEvents() : openAIEvents(model: "gpt-stub")
        for (i, e) in events.enumerated() {
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(300 * i)) { [self] in
                client?.urlProtocol(self, didLoad: Data(e.utf8))
                if i == events.count - 1 { client?.urlProtocolDidFinishLoading(self) }
            }
        }
    }
    override func stopLoading() {}
}

// MARK: p — proxy

func rawHTTP(port: UInt16, _ request: String, host: String = "127.0.0.1") -> String {
    shell("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "5"] + request.split(separator: "\u{1F}").map(String.init)
          + ["http://\(host):\(port)/v1/chat/completions"])
}

func lanAddress() -> String? {
    var result: String?
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return nil }
    defer { freeifaddrs(list) }
    var cursor = list
    while let entry = cursor {
        let flags = Int32(entry.pointee.ifa_flags)
        if let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), flags & IFF_LOOPBACK == 0, flags & IFF_UP != 0 {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            result = String(cString: host); break
        }
        cursor = entry.pointee.ifa_next
    }
    return result
}

@MainActor func runProxy() async throws {
    print("\n## (p) Online service only through Pippa's approval")
    let service = "de.pippa.r10-test.model-credentials"
    let testKey = "sk-r10-test-" + PippaMCPServer.newToken().prefix(24)
    var ids: [UUID] = []
    defer {
        for id in ids { try? ModelCredentialStore.delete(id, service: service) }
        let left = ids.filter { (try? ModelCredentialStore.contains($0, service: service)) == true }
        print("  Test keychain entries (\(service)) deleted: \(left.isEmpty ? "yes" : "NO")")
    }
    func credential(_ id: UUID) -> @Sendable () throws -> String? { { try ModelCredentialStore.read(id, service: service) } }

    try writeAgentSettings()
    let stub = try StubServer()
    try await stub.start()
    let compatible = try ModelConnection(provider: .compatible, endpoint: URL(string: "http://127.0.0.1:\(stub.port)/v1")!, modelID: "stub-model").validated()
    ids.append(compatible.id)
    try ModelCredentialStore.save(testKey, for: compatible.id, service: service)

    // The card as in the app (PippaOnlineDesk), answers taken in order from `script` instead of by click.
    let script = Box<[PippaOnlineDesk.Decision]>([])
    let asks = Box<[PippaOnlineAsk]>([])
    let records = Box<[PippaOnlineRecord]>([])
    let desk = PippaOnlineDesk()
    desk.onOpen = { a in if let a { asks.set { $0.append(a) } } }
    let automatic: (PippaOnlineAsk) -> PippaOnlineDesk.Decision = { _ in
        var decision = PippaOnlineDesk.Decision.deny
        script.set { if !$0.isEmpty { decision = $0.removeFirst() } }
        return decision
    }
    desk.answerAutomatically = automatic
    let decide: @Sendable (PippaOnlineOutgoing) async -> PippaOnlineVerdict = { outgoing in await desk.decide(outgoing) }
    let port = PiOnlineProvider.stablePort(support: roots.support)
    // As in the app: a service on 127.0.0.1 would need no card. Here it stands in for an online service.
    let proxy = try PippaOnlineProxy(connection: compatible, port: port, needsApproval: true, credential: credential(compatible.id),
                                     decide: decide, onRecord: { r in records.set { $0.append(r) } })
    try await proxy.start()
    check(Int(proxy.port) == port, "Proxy on fixed port \(port) (settings.json onlinePort)")
    try PiOnlineProvider.sync(compatible, port: port, modelsJSON: roots.modelsJSON)
    let entry = PiOnlineProvider.current(modelsJSON: roots.modelsJSON) ?? [:]
    print("  models.json pippa-online: " + String(decoding: try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]), as: UTF8.self))
    check((entry["baseUrl"] as? String) == "http://127.0.0.1:\(port)/v1" && (entry["apiKey"] as? String)?.hasPrefix("!") == true,
          "models.json: baseUrl 127.0.0.1, apiKey only as !command (no key)")
    check(!PiInstaller.providerModelIDs(modelsJSON: roots.modelsJSON).isEmpty, "pippa-local stays registered alongside, unchanged")

    guard let spec = PiInstaller(roots: roots).launchSpec(modelID: "unused") else { print("Pi missing (run s first)"); exit(2) }
    let client = PiRPCClient(configuration: piConfiguration(spec, piArguments: PiOnlineProvider.launchArguments(compatible),
                                                            extra: [PiOnlineProvider.tokenVariable: proxy.token]))
    try await client.start()
    if let pid = await client.pid {
        let piEnv = shell("/bin/ps", ["-E", "-ww", "-o", "command=", "-p", String(pid)])
        check(!piEnv.contains(testKey) && piEnv.contains(proxy.token), "Pi's environment: access token yes, service key no")
    }

    func turn(_ label: String, _ prompt: String, decisions: [PippaOnlineDesk.Decision], shown: [URL] = [], conversation: String = "c1") async throws -> Turn {
        script.set { $0 = decisions }
        desk.begin(.init(conversation: conversation, shown: shown))
        let before = (asks.get.count, received.get.count)
        let t = try await ask(client, prompt)
        desk.end()
        let newAsks = Array(asks.get.dropFirst(before.0))
        print("  [\(label)] cards \(newAsks.count), at the service \(received.get.count - before.1), end \(t.stop)\(t.error.map { " · error: \(oneLine($0).prefix(160))" } ?? "")")
        for a in newAsks {
            print("     Card: \(PippaOnlineServiceText.title(a)) — \(PippaOnlineServiceText.body(a))")
        }
        if !t.text.isEmpty { print("     Answer: \(oneLine(t.text)) · chunks at ms \(t.deltas.map(\.0))") }
        return t
    }

    // 1. Once only
    var t = try await turn("Once only", "Sag Hallo.", decisions: [.once])
    check(t.stop == "stop" && t.text == words.joined(), "\"Once only\": the service's answer arrives")
    check(t.deltas.count >= 4 && (t.deltas.last!.0 - t.deltas.first!.0) >= 900, "Streaming arrives piecewise (\(t.deltas.count) chunks over \((t.deltas.last?.0 ?? 0) - (t.deltas.first?.0 ?? 0)) ms)")
    check(received.get.last?.authorization == "Bearer " + testKey, "Service got the key from the keychain (Bearer)")
    check(records.get.last?.outcome == .done, "Receipt: \(ActionReceipt(items: PippaOnlineRecord.receiptItems(records.get)).lines(language: "de").map(\.text))")
    records.set { $0 = [] }

    // 2. No
    let beforeDeny = received.get.count
    t = try await turn("No", "Und jetzt noch einmal.", decisions: [.deny])
    check(t.stop == "error" && (t.error ?? "").contains("did not allow") && received.get.count == beforeDeny, "\"No\": nothing at the service, Pi reports the sentence as an error")
    let denyLines = ActionReceipt(items: PippaOnlineRecord.receiptItems(records.get)).lines(language: "de").map(\.text)
    check(denyLines == ["Nicht online gefragt: 127.0.0.1 (du hast abgelehnt)"], "Receipt: \(denyLines)")
    print("     Sentence for the person: \(InferenceError.onlineDeclined("127.0.0.1").localizedDescription)")
    records.set { $0 = [] }

    // 3. For this conversation, then without a new card
    t = try await turn("For this conversation", "Sag Hallo.", decisions: [.conversation])
    check(t.stop == "stop", "\"For this conversation\": answer arrives")
    let asksBefore = asks.get.count
    t = try await turn("same conversation", "Noch einmal bitte.", decisions: [])
    check(t.stop == "stop" && asks.get.count == asksBefore, "same conversation: no new card")

    // 4. Newly shown: new card, names the shown item
    let shown = home.appendingPathComponent("Brief Hausverwaltung.pdf")
    t = try await turn("newly shown", "Gezeigt: \(shown.path)\nWorum geht es?", decisions: [.once], shown: [shown])
    check(asks.get.count == asksBefore + 1 && asks.get.last?.shownIncluded == ["Brief Hausverwaltung.pdf"], "newly shown items need a new approval; card names \"Brief Hausverwaltung.pdf\"")

    // 5. other conversation: approval does not apply
    t = try await turn("other conversation", "Sag Hallo.", decisions: [.deny], conversation: "c2")
    check(asks.get.count == asksBefore + 2, "other conversation: new card")

    // 6. "Once only" applies to the whole message: tool round without a second card
    let note = work.appendingPathComponent("notiz.txt")
    try Data("Einkaufsliste: Brot, Milch.".utf8).write(to: note)
    stubToolPath.set { $0 = note.path }
    let before6 = received.get.count
    t = try await turn("one message, two rounds", "LIES die Notiz.", decisions: [.once], conversation: "c5")
    check(received.get.count - before6 == 2 && asks.get.count == asksBefore + 3 && t.stop == "stop",
          "\"Once only\" covers all model rounds of the message (2 requests, 1 card)")

    // 7. In the same message a shown item is added that wasn't on the card → new card
    let note2 = work.appendingPathComponent("zettel.txt")
    try Data("Termin: Dienstag 10 Uhr.".utf8).write(to: note2)
    stubToolPath.set { $0 = note2.path }
    let before7 = received.get.count
    t = try await turn("newly shown in the same message", "LIES bitte.", decisions: [.once, .once], shown: [note2], conversation: "c6")
    let last2 = Array(asks.get.suffix(2))
    check(received.get.count - before7 == 2 && asks.get.count == asksBefore + 5 && last2.first?.shownIncluded == [] && last2.last?.shownIncluded == ["zettel.txt"],
          "second card only because the shown \"zettel.txt\" (read by the tool) would newly be included")
    stubToolPath.set { $0 = nil }

    // 8. Card stays open, Pi gives up and asks again (timeout, reproduced here with curl): no second card,
    //    one approval, exactly one request at the service.
    desk.answerAutomatically = nil
    desk.begin(.init(conversation: "c7", shown: []))
    let body = #"{"model":"stub-model","stream":true,"messages":[{"role":"user","content":"Hallo"}]}"#
    func post(_ maxTime: String) -> [String] {
        ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", maxTime, "-X", "POST", "-H", "Authorization: Bearer \(proxy.token)",
         "-H", "Content-Type: application/json", "-d", body, "http://127.0.0.1:\(proxy.port)/v1/chat/completions"]
    }
    let cards8 = desk.cardsShown, before8 = received.get.count
    let firstArgs = post("2"), secondArgs = post("20")
    let first = Task.detached { shell("/usr/bin/curl", firstArgs) }
    try await Task.sleep(for: .seconds(3))
    let firstCode = await first.value
    let second = Task.detached { shell("/usr/bin/curl", secondArgs) }
    try await Task.sleep(for: .seconds(1))
    check(desk.cardsShown == cards8 + 1 && desk.open != nil, "after Pi aborts and retries: still exactly one open card (first attempt: curl \(firstCode))")
    desk.answer(.once)
    let secondCode = await second.value
    try await Task.sleep(for: .milliseconds(500))
    check(secondCode == "200" && received.get.count - before8 == 1, "one approval, exactly one request at the service (second attempt: \(secondCode))")
    desk.end()
    desk.answerAutomatically = automatic

    // 9. "On this Mac": Pi switches to pippa-local for this answer (real Qwen-4B answer), nothing goes out.
    let busy = shell("/usr/bin/pgrep", ["-fl", "llama-server"]).split(separator: "\n").filter { !$0.contains("zsh") && !$0.contains("pgrep") }
    if !busy.isEmpty {
        print("  (9) skipped: another llama-server is running (\(busy.count))")
    } else if let local = PiInstaller.providerModelIDs(modelsJSON: roots.modelsJSON).first {
        let plan = try PiLocalServer.plan(roots: roots, modelID: local, legacySupport: home.appendingPathComponent("legacy"))
        let server = PiLocalServer.server(plan, logDirectory: logDir)
        let lease = try await server.acquireAgentLease()
        desk.switchToLocal = { _ in
            (try? await client.command(["type": "set_model", "provider": PiInstaller.providerKey, "modelId": local])) != nil
        }
        records.set { $0 = [] }
        let before9 = received.get.count
        t = try await turn("On this Mac", "Sag nur: Hallo.", decisions: [.local], conversation: "c8")
        let lines9 = ActionReceipt(items: PippaOnlineRecord.receiptItems(records.get)).lines(language: "de").map(\.text)
        check(t.stop == "stop" && !t.text.isEmpty && !t.text.contains("Ersatz") && received.get.count == before9,
              "\"On this Mac\": answer from \(local), nothing at the service")
        check(lines9 == ["Nicht online gefragt: 127.0.0.1 (auf diesem Mac beantwortet)"], "Receipt: \(lines9)")
        _ = try await client.command(["type": "set_model", "provider": PiOnlineProvider.providerKey, "modelId": "stub-model"])
        t = try await turn("online again afterwards", "Sag Hallo.", decisions: [.once], conversation: "c8")
        check(t.text == words.joined(), "next message goes through the proxy again (with card)")
        await server.releaseAgentLease(lease)
        await server.stop()
    }
    await client.shutdown()

    // Origin, access token, paths
    print("  Origin and access:")
    let token = proxy.token
    let json = "-H\u{1F}Content-Type: application/json\u{1F}-d\u{1F}{}"
    let before = received.get.count
    check(rawHTTP(port: proxy.port, json) == "401", "without access token → 401")
    check(rawHTTP(port: proxy.port, "-H\u{1F}Authorization: Bearer falsch\u{1F}" + json) == "401", "wrong access token → 401")
    check(rawHTTP(port: proxy.port, "-H\u{1F}Authorization: Bearer \(token)\u{1F}-H\u{1F}Origin: https://evil.example\u{1F}" + json) == "403", "with Origin (browser) → 403")
    check(rawHTTP(port: proxy.port, "-H\u{1F}Authorization: Bearer \(token)\u{1F}-H\u{1F}Host: evil.example\u{1F}" + json) == "403", "foreign Host (DNS rebinding) → 403")
    check(shell("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "-H", "Authorization: Bearer \(token)", "http://127.0.0.1:\(proxy.port)/v1/models"]) == "405",
          "GET /v1/models → 405")
    check(shell("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "-X", "POST", "-H", "Authorization: Bearer \(token)", "-H", "Content-Type: application/json",
                                  "-d", "{}", "http://127.0.0.1:\(proxy.port)/v1/embeddings"]) == "404", "other path (/v1/embeddings) → 404")
    if let lan = lanAddress() {
        let code = shell("/usr/bin/curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "3", "-H", "Authorization: Bearer \(token)",
                                           "http://\(lan):\(proxy.port)/v1/chat/completions"])
        check(code == "000", "not reachable via the network address \(lan) (curl \(code))")
    }
    check(received.get.count == before, "none of these requests reached the service")

    // Pi in a terminal: without Pippa's environment no key; without Pippa nobody on the port.
    print("  Pi in a terminal:")
    var terminalEnv = PiInstaller.baseEnvironment(roots)
    terminalEnv["PI_CODING_AGENT_DIR"] = roots.agentDirectory.path
    let cli = spec.launcherArguments + ["-p", "Sag Hallo.", "--no-session", "--no-context-files", "--provider", PiOnlineProvider.providerKey, "--model", "stub-model"]
    let beforeTerminal = received.get.count
    var out = shell(spec.executable.path, cli, environment: terminalEnv)
    print("     Pippa running, without access token: \(oneLine(out).prefix(200))")
    check(received.get.count == beforeTerminal, "Terminal Pi without access token does not reach the service")
    proxy.stop()
    try? await Task.sleep(for: .milliseconds(300))
    terminalEnv[PiOnlineProvider.tokenVariable] = "irgendwas"
    out = shell(spec.executable.path, cli, environment: terminalEnv)
    print("     Pippa quit (port closed): \(oneLine(out).prefix(200))")
    check(received.get.count == beforeTerminal, "Terminal Pi without a running Pippa does not reach the service")

    // Anthropic and OpenAI (stand-in via URLProtocol, no network)
    for provider in [ModelProvider.anthropic, .openAI] {
        let connection = try ModelConnection(provider: provider, modelID: provider == .anthropic ? "claude-stub" : "gpt-stub").validated()
        ids.append(connection.id)
        try ModelCredentialStore.save(testKey, for: connection.id, service: service)
        script.set { $0 = [.once] }
        desk.begin(.init(conversation: "c3", shown: []))
        let p = try PippaOnlineProxy(connection: connection, port: PiOnlineProvider.stablePort(support: roots.support, avoid: port),
                                     needsApproval: !connection.isLocal, credential: credential(connection.id), decide: decide,
                                     onRecord: { r in records.set { $0.append(r) } }, upstreamProtocols: [StubProtocol.self])
        try await p.start()
        try PiOnlineProvider.sync(connection, port: Int(p.port), modelsJSON: roots.modelsJSON)
        let c = PiRPCClient(configuration: piConfiguration(spec, piArguments: PiOnlineProvider.launchArguments(connection),
                                                           extra: [PiOnlineProvider.tokenVariable: p.token]))
        try await c.start()
        let beforeAsks = asks.get.count
        let r = try await ask(c, "Sag Hallo.")
        desk.end()
        let last = received.get.last
        print("  [\(provider.displayName)] end \(r.stop) · answer \(oneLine(r.text)) · chunks at ms \(r.deltas.map(\.0)) · path \(last?.path ?? "-")\(r.error.map { " · error \($0)" } ?? "")")
        check(asks.get.count == beforeAsks + 1, "\(provider.displayName): card before the request")
        check(r.stop == "stop" && r.text == words.joined() && r.deltas.count >= 4, "\(provider.displayName): streamed answer arrives")
        if provider == .anthropic {
            check(last?.apiKey == testKey && last?.authorization == nil && last?.version != nil && last?.path.hasPrefix("/v1/messages") == true,
                  "Anthropic: x-api-key from the keychain, anthropic-version passed through, /v1/messages")
        } else {
            check(last?.authorization == "Bearer " + testKey && last?.path == "/v1/chat/completions", "OpenAI: Bearer from the keychain, /v1/chat/completions")
        }
        await c.shutdown()
        p.stop()
    }
    try PiOnlineProvider.sync(nil, port: 0, modelsJSON: roots.modelsJSON)
    check(PiOnlineProvider.current(modelsJSON: roots.modelsJSON) == nil && !PiInstaller.providerModelIDs(modelsJSON: roots.modelsJSON).isEmpty,
          "Connection removed: pippa-online gone from models.json, pippa-local stays")

    // Key never on disk or in the log
    let found = shell("/usr/bin/grep", ["-rl", "--", testKey, home.path, logDir.path, repo.appendingPathComponent(".build/spike-logs").path])
    check(found.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || found.contains("No such file"), "Key appears in no file under the test HOME and the logs")
    let tokenFound = shell("/usr/bin/grep", ["-rl", "--", token, home.path])
    check(tokenFound.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "the access token appears in no file either (only in Pi's environment)")
}

/// Card texts without the app bundle (like OnlineAskCard; English development texts suffice for the log).
enum PippaOnlineServiceText {
    static func title(_ a: PippaOnlineAsk) -> String { "May I ask \(a.service) for this?" }
    static func body(_ a: PippaOnlineAsk) -> String {
        "\(a.messages) messages, \(a.toolResults) tool results, \(a.images) images, \(a.bytes) bytes, model \(a.model) at \(a.host)"
            + (a.shownIncluded.isEmpty ? "" : ", including: \(a.shownIncluded.joined(separator: ", "))")
    }
}

do {
    if which == "all" || which.contains("p") { try await runProxy() }
} catch {
    print("ERROR: \(error)")
    failures += 1
}
print("\n\(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")")
exit(failures == 0 ? 0 : 1)
