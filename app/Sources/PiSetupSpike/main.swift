import Foundation
import PiRPC
import PippaCore

// Installer end-to-end probe: install into a fake HOME under .build/fake-home-e2e-*,
// start llama-server with a fixed port and key, ask Pi via PiLaunchSpec + PiRPCClient.
// The model comes as an APFS clone from ~/Library/Caches/pippa-live/models (read only, the source stays unchanged).
//
//   PIPPA_PI_PAYLOAD=<folder from bundle-pi-payload.sh --with-node> .build/debug/PiSetupSpike [model key]
//
// Terminates only the processes it started itself (by PID).

setvbuf(stdout, nil, _IOLBF, 0)
let env = ProcessInfo.processInfo.environment
let fm = FileManager.default
let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
let cache = ExistingModels.realHome.appendingPathComponent("Library/Caches/pippa-live", isDirectory: true)
let key = CommandLine.arguments.dropFirst().first ?? "qwen3.5-4b-q4"

func log(_ text: String) { print(text) }
func seconds(since start: Date) -> String { String(format: "%.2f s", Date().timeIntervalSince(start)) }
func available() -> Int64 { ModelDownloader.availableSpace(at: repo) ?? 0 }
func allocated(_ url: URL) -> String {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/du"); p.arguments = ["-sh", url.path]; p.standardOutput = out
    try? p.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\t").first.map(String.init) ?? "?"
}

guard let payloadPath = env["PIPPA_PI_PAYLOAD"], let payload = try? PiPayload.inDirectory(URL(fileURLWithPath: payloadPath)) else {
    log("PIPPA_PI_PAYLOAD missing (scripts/bundle-pi-payload.sh .build/pi-payload --with-node)"); exit(2)
}
// Set up only (scripts/pi-rpc-spike.sh setup): fake HOME <folder> with pinned Pi, models.json (pippa-local
// with fixed port and key file), without model and without server. Prints port and key file.
//   PiSetupSpike --install-only <folder> [model id …]
if CommandLine.arguments.dropFirst().first == "--install-only", CommandLine.arguments.count >= 3 {
    let home = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    let roots = PiInstallRoots(home: home, payload: payload, searchPath: [home.appendingPathComponent(".local/bin")])
    let ids = CommandLine.arguments.count > 3 ? Array(CommandLine.arguments.dropFirst(3)) : ["gemma-4-12b", "qwen3.5-4b"]
    let port = PiInstaller.stablePort(support: roots.support)
    let installer = PiInstaller(roots: roots)
    let options = PiInstallOptions(model: nil,
                                   providerModels: ids.map { PiProviderModel(id: $0, name: $0, contextWindow: 16384) }, port: port)
    for step in [PiInstallStep.detect, .pi, .provider] {
        let result = installer.perform(step, options)
        guard result.isDone else { log("\(step.rawValue): \(result.message)"); exit(1) }
    }
    print("port=\(port)")
    print("keyfile=\(roots.llamaKeyFile.path)")
    exit(0)
}

guard let model = ModelCatalog.bundled().model(key), let file = model.pinned?.files.first else { log("Model \(key) not in catalog"); exit(2) }
let source = cache.appendingPathComponent("models/\((file.path as NSString).lastPathComponent)")
let sourceBefore = try fm.attributesOfItem(atPath: source.path)

let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
let home = repo.appendingPathComponent(".build/fake-home-e2e-\(stamp)", isDirectory: true)
try fm.createDirectory(at: home, withIntermediateDirectories: true)
let roots = PiInstallRoots(home: home, payload: payload, searchPath: [home.appendingPathComponent(".local/bin")])
log("HOME (fake): \(home.path)")
log("Free space before: \(ModelDownloadSize.gigabytes(available()))")

// 1. Installer
let freeBefore = available()
let installer = PiInstaller(roots: roots)
let port = PiInstaller.stablePort(support: roots.support)
let options = PiInstallOptions(model: model,
                               modelSearchRoots: [ModelLocation(url: cache.appendingPathComponent("models", isDirectory: true), source: "pippa-live")],
                               providerModels: [PiProviderModel(id: model.key, name: model.label, contextWindow: 16384)], port: port)
var timings: [(String, String)] = []
for step in PiInstallStep.allCases {
    let start = Date()
    let result = installer.perform(step, options)
    timings.append((step.rawValue, seconds(since: start)))
    log("  \(step.rawValue): \(seconds(since: start)) – \(result.message)")
    guard result.isDone else { log("Aborted: \(result.outcome)"); exit(1) }
}
let rerunStart = Date()
let rerun = PiInstaller(roots: roots).run(options)
log("  second run (idempotent): \(seconds(since: rerunStart)), all done: \(rerun.allSatisfy(\.isDone))")
let freeAfter = available()
log("Space: fake HOME uses \(allocated(home)) per du, free disk space before/after \(ModelDownloadSize.gigabytes(freeBefore)) / \(ModelDownloadSize.gigabytes(freeAfter)) (Δ \(ModelDownloadSize.gigabytes(freeBefore - freeAfter)), noise from other processes possible)")
let modelsFolder = URL(fileURLWithPath: installer.state.modelsFolder ?? roots.pippaModels.path, isDirectory: true)
log("  release: \(allocated(roots.release(.official))), pi-node: \(allocated(roots.piNode)), models: \(allocated(modelsFolder))")
let sourceAfter = try fm.attributesOfItem(atPath: source.path)
let untouched = sourceBefore[.size] as? NSNumber == sourceAfter[.size] as? NSNumber
    && sourceBefore[.modificationDate] as? Date == sourceAfter[.modificationDate] as? Date
    && sourceBefore[.systemFileNumber] as? NSNumber == sourceAfter[.systemFileNumber] as? NSNumber
log("Source in cache unchanged (size, modification date, inode): \(untouched)")

// 2. llama-server with fixed port and key (as LlamaServer: key via LLAMA_API_KEY, not in the arguments)
// The same key Pi reads from models.json via `apiKey: "!/bin/cat <Support>/llama-key"`.
let apiKey = try PiInstaller.stableKey(support: roots.support)
let modelFile = modelsFolder.appendingPathComponent((file.path as NSString).lastPathComponent)
let server = Process()
server.executableURL = cache.appendingPathComponent("llama-b11503/llama-server")
server.arguments = ["-m", modelFile.path, "--host", "127.0.0.1", "--port", String(port), "--jinja", "-ngl", "999", "-c", "16384",
                    "--parallel", "1", "--no-webui", "--reasoning", "off", "--cache-type-k", "q8_0", "--cache-type-v", "q8_0", "--alias", model.key]
server.environment = LlamaServer.environment(apiKey: apiKey)
let serverLog = home.appendingPathComponent("llama-server.log")
fm.createFile(atPath: serverLog.path, contents: nil)
server.standardOutput = try FileHandle(forWritingTo: serverLog); server.standardError = server.standardOutput
let serverStart = Date()
try server.run()
log("llama-server PID \(server.processIdentifier), port \(port)")
func stopServer() { if server.isRunning { kill(server.processIdentifier, SIGTERM) } }
var healthy = false
for _ in 0..<600 where !healthy {
    try await Task.sleep(for: .milliseconds(250))
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
    request.timeoutInterval = 2
    if let (_, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200 { healthy = true }
    if !server.isRunning { break }
}
log("llama-server ready: \(healthy) after \(seconds(since: serverStart))")
guard healthy else { stopServer(); exit(1) }

// 3. Pi via the installer's launch spec
guard let spec = installer.launchSpec(modelID: model.key) else { stopServer(); log("no launch spec"); exit(1) }
let work = home.appendingPathComponent("work", isDirectory: true)
try fm.createDirectory(at: work, withIntermediateDirectories: true)
var configuration = PiRPCConfiguration(executable: spec.executable, workingDirectory: work, environment: spec.environment,
                                       arguments: ["--no-session", "--no-context-files"] + spec.piArguments)
configuration.launcherArguments = spec.launcherArguments
let client = PiRPCClient(configuration: configuration)
var exitCode: Int32 = 0
do {
    let piStart = Date()
    try await client.start()
    let version = await client.version ?? "?", pid = await client.pid ?? 0
    log("Pi \(version) started in \(seconds(since: piStart)) (PID \(pid))")
    let ask = Date()
    var first: String?
    var text = ""
    for try await event in try await client.prompt("Antworte in einem kurzen Satz auf Deutsch: Wie heißt die Hauptstadt von Frankreich?") {
        switch event {
        case .textDelta(let delta):
            if first == nil { first = seconds(since: ask) }
            text += delta
        case .assistantEnded(_, let stop, let error):
            log("Answer ended: \(stop)\(error.map { " – \($0)" } ?? "")")
        default: break
        }
    }
    log("First word after \(first ?? "-"), done after \(seconds(since: ask))")
    log("Answer: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
    if text.isEmpty { exitCode = 1 }
} catch {
    log("Error: \(error)")
    exitCode = 1
}
await client.shutdown()
stopServer()
server.waitUntilExit()
log("Stopped: Pi and llama-server (PID \(server.processIdentifier)).")
log("Created according to install-state.json: \(installer.state.created.count) paths")
exit(exitCode)
