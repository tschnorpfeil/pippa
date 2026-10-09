import CryptoKit
import Foundation
import PippaCore

// Installer (PiSetup): everything runs against a fake HOME under <repo>/.build/fake-home-*, never the real one.
// Fast and offline with an invented payload (a shell "node" that reports the version). With PIPPA_PI_PAYLOAD
// (folder from `scripts/bundle-pi-payload.sh <folder> --with-node`) it also runs against the real pinned Pi and real Node.
//
//   PIPPA_SETUP_CHECKS=1 PIPPA_PI_PAYLOAD=$PWD/.build/pi-payload swift run --package-path app PippaChecks

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

/// A fresh, fake HOME. Removed after the check (unless PIPPA_KEEP_FAKE_HOME=1).
private func fakeHome(_ name: String) -> URL {
    let url = repoRoot.appendingPathComponent(".build/fake-home-\(name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private func discard(_ url: URL) {
    if ProcessInfo.processInfo.environment["PIPPA_KEEP_FAKE_HOME"] != "1" { try? fm.removeItem(at: url) } // only our fake HOME
}

/// Invented payload in the releases-v1 layout. "node" is a shell script: `node --version` → v22.23.3,
/// `node <cli.js> --version` → contents of dist/bundle/fake-version next to the CLI (this is how a release gets "broken").
private func fakePayload(in base: URL, version: String = "1.0.4") throws -> PiPayload {
    let dir = base.appendingPathComponent("payload", isDirectory: true)
    let release = dir.appendingPathComponent("release", isDirectory: true)
    let bundle = release.appendingPathComponent("node_modules/@earendil-works/pi-coding-agent/dist/bundle", isDirectory: true)
    try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
    try fm.createDirectory(at: release.appendingPathComponent("node_modules/.bin", isDirectory: true), withIntermediateDirectories: true)
    write("{\n\t\"schemaVersion\": 1,\n\t\"version\": \"\(version)\",\n\t\"packages\": []\n}\n", release.appendingPathComponent("metadata.json"))
    write("{\"name\": \"@earendil-works/pi-coding-agent-install\", \"version\": \"\(version)\"}\n", release.appendingPathComponent("package.json"))
    write("{\"lockfileVersion\": 3}\n", release.appendingPathComponent("package-lock.json"))
    write("#!/usr/bin/env node\n", bundle.appendingPathComponent("cli.js"))
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.appendingPathComponent("cli.js").path)
    write(version + "\n", bundle.appendingPathComponent("fake-version"))
    try fm.createSymbolicLink(atPath: release.appendingPathComponent("node_modules/.bin/pi").path,
                              withDestinationPath: "../@earendil-works/pi-coding-agent/dist/bundle/cli.js")
    let bin = dir.appendingPathComponent("bin", isDirectory: true)
    try fm.createDirectory(at: bin, withIntermediateDirectories: true)
    write("""
    #!/bin/sh
    if [ "$1" = --version ]; then echo v22.23.3; exit 0; fi
    if [ "$2" = --version ]; then cat "$(dirname "$(readlink -f "$1")")/fake-version"; exit 0; fi
    exit 3

    """, bin.appendingPathComponent("node"))
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("node").path)
    let npm = dir.appendingPathComponent("lib/node_modules/npm/bin", isDirectory: true)
    try fm.createDirectory(at: npm, withIntermediateDirectories: true)
    write("// npm\n", npm.appendingPathComponent("npm-cli.js"))
    return try PiPayload.inDirectory(dir)
}

private func roots(_ home: URL, _ payload: PiPayload) -> PiInstallRoots {
    // Only locations inside the fake HOME: a `pi` in /opt/homebrew/bin on this machine must not influence the check.
    PiInstallRoots(home: home, payload: payload, searchPath: [home.appendingPathComponent(".npm-global/bin"), home.appendingPathComponent(".local/bin")])
}

/// Small model from random bytes plus a catalog entry with its SHA-256 (never the real GGUFs).
private func dummyModel(name: String = "Dummy-1B-Q4_K_M.gguf", bytes: Int = 1_048_576, key: String = "dummy-1b") -> (CatalogModel, Data) {
    let data = Data((0..<bytes).map { _ in UInt8.random(in: 0...255) })
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let json: [String: Any] = ["key": key, "label": "Dummy 1B", "repo": "fixture/dummy", "quant": "Q4_K_M", "memGiB": 1, "ctx": 4096, "rank": 1,
                               "pinned": ["revision": "test", "files": [["path": name, "size": bytes, "sha256": hash]]]]
    let model = try! JSONDecoder().decode(CatalogModel.self, from: JSONSerialization.data(withJSONObject: json))
    return (model, data)
}

private func shell(_ executable: String, _ arguments: [String], environment: [String: String]) -> String? {
    let process = Process(), out = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    process.standardOutput = out; process.standardError = out
    guard (try? process.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : nil
}

private func options(_ model: CatalogModel?, roots search: [ModelLocation]? = nil, port: Int = 18_471) -> PiInstallOptions {
    PiInstallOptions(model: model, modelSearchRoots: search,
                     providerModels: [PiProviderModel(id: model?.key ?? "dummy-1b", name: "Dummy 1B", contextWindow: 4096)], port: port)
}

private func inode(_ url: URL) -> Int? { (try? fm.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.intValue }
private func linkCount(_ url: URL) -> Int? { (try? fm.attributesOfItem(atPath: url.path)[.referenceCount] as? NSNumber)?.intValue }

func runSetupChecks() async {
    await runPiPivotChecks()
    check("Installer: fresh HOME gets the official layout (marker, current-version, launcher, ~/.local/bin/pi, Node)") {
        let home = fakeHome("fresh"); defer { discard(home) }
        let payload = try fakePayload(in: home.appendingPathComponent("src"))
        let (model, data) = dummyModel()
        let lmstudio = home.appendingPathComponent(".lmstudio/models/fixture/dummy", isDirectory: true)
        try fm.createDirectory(at: lmstudio, withIntermediateDirectories: true)
        try data.write(to: lmstudio.appendingPathComponent("Dummy-1B-Q4_K_M.gguf"))
        let r = roots(home, payload)
        let installer = PiInstaller(roots: r)
        let results = installer.run(options(model, roots: ExistingModels.defaultRoots(home: home)))
        let install = r.managedRoot
        let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: install.appendingPathComponent("managed-install.json"))) as? [String: Any]
        let entry = marker?["entrypoint"] as? [String: Any]
        let launcher = try String(contentsOf: r.launcher, encoding: .utf8)
        let version = shell(r.entrypoint.path, ["--version"], environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        // Against this machine's real launcher, if present (read only): same content.
        let realLauncher = try? String(contentsOf: ExistingModels.realHome.appendingPathComponent(".pi/agent/bin/pi"), encoding: .utf8)
        let ok = results.map(\.step) == PiInstallStep.allCases && results.allSatisfy(\.isDone)
            && marker?["kind"] as? String == "pi-managed-install" && marker?["layout"] as? String == "releases-v1"
            && entry?["path"] as? String == r.entrypoint.path
            && (try? String(contentsOf: install.appendingPathComponent("current-version"), encoding: .utf8)) == "1.0.4\n"
            && launcher == PiInstaller.launcherScript && fm.isExecutableFile(atPath: r.launcher.path)
            && (realLauncher == nil || realLauncher == launcher)
            && (try? fm.destinationOfSymbolicLink(atPath: r.entrypoint.path)) == "../../.pi/agent/bin/pi"
            && (try? fm.destinationOfSymbolicLink(atPath: r.piNode.appendingPathComponent("current").path)) == "v22.23.3"
            && fm.fileExists(atPath: r.piNode.appendingPathComponent("v22.23.3/lib/node_modules/npm/bin/npm-cli.js").path)
            && version == "1.0.4"
            && installer.state.layout == .official && installer.state.didCreate(r.release(.official))
            && fm.fileExists(atPath: r.stateFile.path)
        if !ok { print("   ", results.map { "\($0.step): \($0.outcome)" }, version ?? "-") }
        return ok
    }

    check("Installer: managed Pi of another version only gets releases/<pin>; current-version and launcher stay") {
        let home = fakeHome("managed"); defer { discard(home) }
        let payload = try fakePayload(in: home.appendingPathComponent("src"))
        let r = roots(home, payload)
        let old = r.managedRoot.appendingPathComponent("releases/1.0.3", isDirectory: true)
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try fm.createDirectory(at: r.launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        write("{\"kind\": \"pi-managed-install\", \"schemaVersion\": 1, \"layout\": \"releases-v1\"}", r.managedRoot.appendingPathComponent("managed-install.json"))
        write("1.0.3\n", r.managedRoot.appendingPathComponent("current-version"))
        write("#!/bin/sh\n# launcher des Nutzers\n", r.launcher)
        let installer = PiInstaller(roots: r)
        let detected = installer.detect()
        let pi = installer.installPi()
        let spec = installer.launchSpec(modelID: "dummy-1b")
        return detected.outcome == .detected(.managed(currentVersion: "1.0.3"))
            && pi.outcome == .piInstalled(layout: .addedRelease, release: r.release(.addedRelease), reused: false)
            && (try? String(contentsOf: r.managedRoot.appendingPathComponent("current-version"), encoding: .utf8)) == "1.0.3\n"
            && (try? String(contentsOf: r.launcher, encoding: .utf8)) == "#!/bin/sh\n# launcher des Nutzers\n"
            && fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: r.entrypoint.path)
            && !fm.fileExists(atPath: r.piNode.path)
            && spec?.environment["PI_MANAGED_INSTALL_ROOT"] == r.managedRoot.path
            && spec?.launcherArguments == [PiPayload.cliEntry(release: r.release(.addedRelease)).path]
            && spec?.piArguments == ["--provider", "pippa-local", "--model", "dummy-1b"]
            && spec?.environment["PI_OFFLINE"] == "1" && spec?.environment["PI_TELEMETRY"] == "0"
            && spec?.environment["PI_SKIP_VERSION_CHECK"] == "1" && spec?.environment["PIPPA_LLAMA_KEY"] == nil
    }

    check("Installer: the user's existing releases/<pin> is verified and reused; if broken it is left untouched") {
        let home = fakeHome("managed-pin"); defer { discard(home) }
        let payload = try fakePayload(in: home.appendingPathComponent("src"))
        let r = roots(home, payload)
        try fm.createDirectory(at: r.managedRoot.appendingPathComponent("releases"), withIntermediateDirectories: true)
        write("{\"kind\": \"pi-managed-install\", \"schemaVersion\": 1, \"layout\": \"releases-v1\"}", r.managedRoot.appendingPathComponent("managed-install.json"))
        write("1.0.4\n", r.managedRoot.appendingPathComponent("current-version"))
        try fm.copyItem(at: payload.release, to: r.release(.addedRelease))
        let installer = PiInstaller(roots: r)
        let reused = installer.installPi()
        let fakeVersion = PiPayload.cliEntry(release: r.release(.addedRelease)).deletingLastPathComponent().appendingPathComponent("fake-version")
        write("kaputt\n", fakeVersion)
        let broken = installer.installPi()
        return reused.outcome == .piInstalled(layout: .addedRelease, release: r.release(.addedRelease), reused: true)
            && !installer.state.didCreate(r.release(.addedRelease))
            && broken.outcome == .failed(.releaseBroken(r.release(.addedRelease).path))
            && (try? String(contentsOf: fakeVersion, encoding: .utf8)) == "kaputt\n"
    }

    check("Installer: foreign pi (npm global) → own root folder; ~/.pi/agent/install and ~/.local/bin/pi stay untouched") {
        let home = fakeHome("unmanaged"); defer { discard(home) }
        let payload = try fakePayload(in: home.appendingPathComponent("src"))
        let r = roots(home, payload)
        let foreign = home.appendingPathComponent(".npm-global/bin/pi")
        try fm.createDirectory(at: foreign.deletingLastPathComponent(), withIntermediateDirectories: true)
        write("#!/bin/sh\necho 0.9.0\n", foreign)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: foreign.path)
        let installer = PiInstaller(roots: r)
        let detected = installer.detect()
        let pi = installer.installPi()
        let spec = installer.launchSpec(modelID: "dummy-1b")
        return detected.outcome == .detected(.unmanaged(path: foreign.path))
            && pi.outcome == .piInstalled(layout: .pippaRoot, release: r.release(.pippaRoot), reused: false)
            && !fm.fileExists(atPath: r.managedRoot.path) && !fm.fileExists(atPath: r.entrypoint.path)
            && !fm.fileExists(atPath: r.pippaRoot.appendingPathComponent("managed-install.json").path)
            && spec?.environment["PI_MANAGED_INSTALL_ROOT"] == nil
            && spec?.launcherArguments.first?.hasPrefix(r.pippaRoot.path) == true
    }

    check("Installer: models.json merge keeps foreign providers, backs up once, leaves unreadable files alone") {
        let home = fakeHome("models-json"); defer { discard(home) }
        let payload = try fakePayload(in: home.appendingPathComponent("src"))
        let r = roots(home, payload)
        try fm.createDirectory(at: r.agentDirectory, withIntermediateDirectories: true)
        let original = """
        {"providers": {"ollama": {"baseUrl": "http://localhost:11434/v1", "api": "openai-completions", "apiKey": "ollama", "models": [{"id": "qwen2.5-coder:7b"}]},
                       "pippa-local": {"baseUrl": "http://127.0.0.1:1/v1", "models": []}},
         "custom": {"keep": true}}
        """
        write(original, r.modelsJSON)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: r.modelsJSON.path)
        let installer = PiInstaller(roots: r)
        let models = [PiProviderModel(id: "qwen3.5-9b-q4", name: "Qwen3.5 9B", contextWindow: 16384)]
        let first = installer.writeProvider(models: models, port: 18_471)
        let again = installer.writeProvider(models: models, port: 18_471)
        let moved = installer.writeProvider(models: models, port: 18_472)
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: r.modelsJSON)) as? [String: Any]
        let providers = doc?["providers"] as? [String: Any]
        let ours = providers?["pippa-local"] as? [String: Any]
        let ollama = providers?["ollama"] as? [String: Any]
        let backups = try fm.contentsOfDirectory(atPath: r.agentDirectory.path).filter { $0.hasSuffix(".bak") }
        let backupText = try backups.first.map { try String(contentsOf: r.agentDirectory.appendingPathComponent($0), encoding: .utf8) }
        let mode = (try? fm.attributesOfItem(atPath: r.modelsJSON.path)[.posixPermissions] as? NSNumber)?.intValue
        let leftovers = try fm.contentsOfDirectory(atPath: r.agentDirectory.path).filter { $0.contains("pippa-") && !$0.hasSuffix(".bak") }

        // Unreadable (comment, as Pi allows): change nothing, no backup.
        let other = fakeHome("models-json-bad"); defer { discard(other) }
        let r2 = roots(other, payload)
        try fm.createDirectory(at: r2.agentDirectory, withIntermediateDirectories: true)
        let commented = "{\n  // eigener Kommentar\n  \"providers\": {}\n}\n"
        write(commented, r2.modelsJSON)
        let refused = PiInstaller(roots: r2).writeProvider(models: models, port: 18_471)
        return first.outcome == .providerWritten(port: 18_471, backup: installer.state.modelsJSONBackup.map(URL.init(fileURLWithPath:)), changed: true)
            && again.outcome == .providerWritten(port: 18_471, backup: installer.state.modelsJSONBackup.map(URL.init(fileURLWithPath:)), changed: false)
            && moved.isDone && ours?["baseUrl"] as? String == "http://127.0.0.1:18472/v1"
            && ours?["apiKey"] as? String == "!/bin/cat '\(r.llamaKeyFile.path)'" && ours?["api"] as? String == "openai-completions"
            && ((ours?["models"] as? [[String: Any]])?.first?["id"] as? String) == "qwen3.5-9b-q4"
            && ollama?["apiKey"] as? String == "ollama" && (doc?["custom"] as? [String: Any])?["keep"] as? Bool == true
            && backups.count == 1 && backupText == original && mode == 0o600 && leftovers.isEmpty
            && refused.outcome == .failed(.modelsJSONUnreadable(r2.modelsJSON.path))
            && (try? String(contentsOf: r2.modelsJSON, encoding: .utf8)) == commented
            && (try? fm.contentsOfDirectory(atPath: r2.agentDirectory.path)) == ["models.json"]
    }

    check("Installer: Pi settings get compaction and thinking per pippa-local model; the person's own values stay") {
        let home = fakeHome("pi-settings"); defer { discard(home) }
        let payload = try fakePayload(in: home.appendingPathComponent("src"))
        let r = roots(home, payload)
        try fm.createDirectory(at: r.agentDirectory, withIntermediateDirectories: true)
        write(#"{"theme": "dark", "modelThinkingLevels": {"pippa-local/qwen3.5-4b-q4": "medium"}}"#, r.piSettingsJSON)
        let models = [PiProviderModel(id: "k2-horizon-7b", name: "K2", contextWindow: 16384),
                      PiProviderModel(id: "qwen3.5-4b-q4", name: "Qwen", contextWindow: 32768)]
        let wrote = PiInstaller(roots: r).writeModelTuning(models: models)
        let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: r.piSettingsJSON)) as? [String: Any]
        let overrides = (doc?["compaction"] as? [String: Any])?["modelOverrides"] as? [String: [String: Int]]
        let levels = doc?["modelThinkingLevels"] as? [String: String]
        let k2 = overrides?["pippa-local/k2-horizon-7b"], qwen = overrides?["pippa-local/qwen3.5-4b-q4"]
        // Pippa's old default "high" moves to the new default; a level the person chose stays.
        let k2Only = [PiProviderModel(id: "k2-horizon-7b", name: "K2", contextWindow: 32768)]
        let migrated = PiModelTuning.merge(into: ["modelThinkingLevels": ["pippa-local/k2-horizon-7b": "high"]], models: k2Only)["modelThinkingLevels"] as? [String: String]
        let kept = PiModelTuning.merge(into: ["modelThinkingLevels": ["pippa-local/k2-horizon-7b": "low"]], models: k2Only)["modelThinkingLevels"] as? [String: String]
        // Provider entry: K2 thinks via reasoning_effort (medium as asked, the rest "high", see PiReasoningStyle), Qwen via enable_thinking.
        let entry = PiInstaller.providerEntry(models: models, port: 1, keyFile: r.llamaKeyFile)
        let listed = entry["models"] as? [[String: Any]] ?? []
        let k2Compat = listed.first?["compat"] as? [String: Any]
        let k2Kwargs = k2Compat?["chatTemplateKwargs"] as? [String: Any]
        let qwenCompat = listed.last?["compat"] as? [String: Any]
        let unknown = PiInstaller.providerEntry(models: [PiProviderModel(id: "other", name: "O", contextWindow: 8192)], port: 1, keyFile: r.llamaKeyFile)
        return wrote && doc?["theme"] as? String == "dark"
            && k2?["reserveTokens"] == 4096 && k2?["keepRecentTokens"] == 6144
            && qwen?["reserveTokens"] == 4096 && qwen?["keepRecentTokens"] == 12288
            && levels?["pippa-local/k2-horizon-7b"] == "medium" && levels?["pippa-local/qwen3.5-4b-q4"] == "medium"
            && migrated?["pippa-local/k2-horizon-7b"] == "medium" && kept?["pippa-local/k2-horizon-7b"] == "low"
            && (listed.first?["thinkingLevelMap"] as? [String: Any])?["medium"] as? String == "medium"
            && listed.first?["reasoning"] as? Bool == true && k2Compat?["thinkingFormat"] as? String == "chat-template"
            && (k2Kwargs?["reasoning_effort"] as? [String: String])?["$var"] == "thinking.effort"
            && (listed.first?["thinkingLevelMap"] as? [String: Any])?["off"] as? String == "high"
            && qwenCompat?["thinkingFormat"] as? String == "qwen-chat-template"
            && (unknown["models"] as? [[String: Any]])?.first?["reasoning"] == nil
            && LlamaServer.arguments(choice: ModelSelector.named("qwen3.5-9b-q4", physicalMemory: 16 << 30)!, model: URL(fileURLWithPath: "/m.gguf"),
                                     port: 1, supported: nil, alias: "qwen3.5-9b-q4").contains("--reasoning") == false
    }

    check("Installer: model adopted without asking via clone, hardlink or copy; existing ~/models reused; originals stay") {
        let home = fakeHome("adopt"); defer { discard(home) }
        let payload = try fakePayload(in: home.appendingPathComponent("src"))
        let r = roots(home, payload)
        let (model, data) = dummyModel()
        let file = "Dummy-1B-Q4_K_M.gguf"
        let lmstudio = home.appendingPathComponent(".lmstudio/models/fixture/dummy/\(file)")
        try fm.createDirectory(at: lmstudio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: lmstudio)
        let search = ExistingModels.defaultRoots(home: home)

        // Clone (APFS): separate file, same content, original unchanged. ~/models already exists: Pippa shares it.
        try fm.createDirectory(at: r.sharedModels, withIntermediateDirectories: true)
        let clone = PiInstaller(roots: r)
        _ = clone.prepareModelsFolder()
        let cloned = clone.provideModel(model, searchRoots: search)
        let dest = r.sharedModels.appendingPathComponent(file)
        let cloneOK = cloned.outcome == .modelReady(file: dest, method: .clone, source: "LM Studio")
            && (try? Data(contentsOf: dest)) == data && (try? Data(contentsOf: lmstudio)) == data && inode(dest) != inode(lmstudio)

        // Hardlink (when cloning is impossible): original stays, two names for the same content.
        let homeB = fakeHome("adopt-link"); defer { discard(homeB) }
        let rB = roots(homeB, payload)
        let sourceB = homeB.appendingPathComponent(".cache/huggingface/hub/models--fixture--dummy/blobs/\(file)")
        try fm.createDirectory(at: sourceB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: sourceB)
        let link = PiInstaller(roots: rB)
        link.adoptionMethods = [.hardlink, .copy]
        _ = link.prepareModelsFolder()   // no ~/models: Pippa's support folder is used, ~/models is not created
        let linked = link.provideModel(model, searchRoots: ExistingModels.defaultRoots(home: homeB))
        let destB = rB.pippaModels.appendingPathComponent(file)
        let linkOK = linked.outcome == .modelReady(file: destB, method: .hardlink, source: "Hugging Face")
            && fm.fileExists(atPath: sourceB.path) && linkCount(sourceB) == 2 && inode(destB) == inode(sourceB)
            && link.state.adopted.first?.method == .hardlink && link.state.modelsFolderShared == false
            && !fm.fileExists(atPath: rB.sharedModels.path)

        // Only copy possible: copied without asking (enough space). Old sandbox container as source.
        let homeC = fakeHome("adopt-copy"); defer { discard(homeC) }
        let rC = roots(homeC, payload)
        let container = rC.containerModels.appendingPathComponent(file)
        try fm.createDirectory(at: container.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: container)
        let copy = PiInstaller(roots: rC)
        copy.adoptionMethods = [.copy]
        _ = copy.prepareModelsFolder()
        let copied = copy.provideModel(model, searchRoots: [])
        let copyOK = !fm.fileExists(atPath: rC.pippaModels.appendingPathComponent(file).path + ".import")
            && copied.outcome == .modelReady(file: rC.pippaModels.appendingPathComponent(file), method: .copy, source: "Pippa")
            && (try? Data(contentsOf: container)) == data

        // Wrong content (same size): nothing adopted, source untouched. Nothing found: download needed.
        let homeD = fakeHome("adopt-bad"); defer { discard(homeD) }
        let rD = roots(homeD, payload)
        var wrong = data; wrong[0] ^= 0xFF
        let bad = homeD.appendingPathComponent(".lmstudio/models/fixture/dummy/\(file)")
        try fm.createDirectory(at: bad.deletingLastPathComponent(), withIntermediateDirectories: true)
        try wrong.write(to: bad)
        let mismatch = PiInstaller(roots: rD)
        _ = mismatch.prepareModelsFolder()
        let refused = mismatch.provideModel(model, searchRoots: ExistingModels.defaultRoots(home: homeD))
        try fm.removeItem(at: bad) // our test file in the fake HOME
        let missing = mismatch.provideModel(model, searchRoots: ExistingModels.defaultRoots(home: homeD))
        let badOK = refused.outcome == .failed(.checksumMismatch(bad.path))
            && !fm.fileExists(atPath: rD.pippaModels.appendingPathComponent(file).path)
            && missing.outcome == .needsDownload(bytes: Int64(data.count))
        if !(cloneOK && linkOK && copyOK && badOK) { print("   ", cloneOK, linkOK, copyOK, badOK, cloned.outcome, linked.outcome, copied.outcome, refused.outcome) }
        return cloneOK && linkOK && copyOK && badOK
    }

    check("Installer: second run changes nothing (idempotent); repair only replaces Pippa's own release") {
        let home = fakeHome("rerun"); defer { discard(home) }
        let payload = try fakePayload(in: home.appendingPathComponent("src"))
        let r = roots(home, payload)
        let (model, data) = dummyModel()
        let source = home.appendingPathComponent(".lmstudio/models/fixture/dummy/Dummy-1B-Q4_K_M.gguf")
        try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: source)
        let search = ExistingModels.defaultRoots(home: home)
        let first = PiInstaller(roots: r).run(options(model, roots: search))
        let models = try Data(contentsOf: r.modelsJSON)
        let createdBefore = PiInstallState.load(from: r.stateFile).created
        let second = PiInstaller(roots: r)
        let rerun = second.run(options(model, roots: search)) // models folder is remembered
        let unchanged = first.allSatisfy(\.isDone) && rerun.allSatisfy(\.isDone) && rerun.count == PiInstallStep.allCases.count
            && rerun[1].outcome == .piInstalled(layout: .official, release: r.release(.official), reused: true)
            && rerun[3].outcome == .modelReady(file: r.pippaModels.appendingPathComponent("Dummy-1B-Q4_K_M.gguf"), method: nil, source: nil)
            && rerun[4].outcome == .providerWritten(port: 18_471, backup: nil, changed: false)
            && second.state.created == createdBefore && (try? Data(contentsOf: r.modelsJSON)) == models
        // Own release damaged: the ready check reports it, repair replaces it.
        write("kaputt\n", PiPayload.cliEntry(release: r.release(.official)).deletingLastPathComponent().appendingPathComponent("fake-version"))
        let broken = second.checkReady(modelIDs: ["dummy-1b"], model: model)
        let repaired = second.repair(.pi, options(model, roots: search))
        let ready = second.checkReady(modelIDs: ["dummy-1b"], model: model)
        return unchanged && broken.outcome == .failed(.versionMismatch(found: "kaputt", expected: "1.0.4"))
            && repaired.outcome == .piInstalled(layout: .official, release: r.release(.official), reused: false)
            && ready.outcome == .ready(version: "1.0.4")
    }

    check("Installer: interrupted run is resumed (layout from install-state.json, leftovers cleaned up)") {
        let home = fakeHome("resume"); defer { discard(home) }
        let payload = try fakePayload(in: home.appendingPathComponent("src"))
        let r = roots(home, payload)
        let (model, data) = dummyModel()
        // Aborted after the release: marker, current-version, launcher are missing, a half-finished staging folder is lying around.
        let first = PiInstaller(roots: r)
        _ = first.detect()
        _ = first.installPi()
        for name in ["managed-install.json", "current-version"] { try fm.removeItem(at: r.managedRoot.appendingPathComponent(name)) }
        try fm.removeItem(at: r.launcher)
        try fm.removeItem(at: r.entrypoint)
        let junk = r.managedRoot.appendingPathComponent("staging/pippa-1.0.4-abgebrochen/node_modules", isDirectory: true)
        try fm.createDirectory(at: junk, withIntermediateDirectories: true)
        // Without the marker a fresh detection would see "foreign"; the remembered state applies.
        let fresh = PiInstaller.detect(r)
        // A half-finished model adoption sits as .import in the models folder.
        let source = home.appendingPathComponent(".lmstudio/models/fixture/dummy/Dummy-1B-Q4_K_M.gguf")
        try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: source)
        try fm.createDirectory(at: r.pippaModels, withIntermediateDirectories: true)
        try data.prefix(1000).write(to: r.pippaModels.appendingPathComponent("Dummy-1B-Q4_K_M.gguf.import"))
        let resumed = PiInstaller(roots: r)
        let results = resumed.run(options(model, roots: ExistingModels.defaultRoots(home: home)))
        return fresh == .unmanaged(path: r.managedRoot.path)
            && results.allSatisfy(\.isDone) && resumed.state.layout == .official
            && PiInstaller.detect(r) == .managed(currentVersion: "1.0.4")
            && fm.isExecutableFile(atPath: r.launcher.path)
            && !fm.fileExists(atPath: junk.deletingLastPathComponent().path)
            && !fm.fileExists(atPath: r.pippaModels.appendingPathComponent("Dummy-1B-Q4_K_M.gguf.import").path)
            && (try? Data(contentsOf: r.pippaModels.appendingPathComponent("Dummy-1B-Q4_K_M.gguf"))) == data
    }

    check("Installer: models folder without asking (support folder, excluded from Time Machine); port stays stable") {
        let home = fakeHome("folder"); defer { discard(home) }
        let payload = try fakePayload(in: home.appendingPathComponent("src"))
        let r = roots(home, payload)
        let results = PiInstaller(roots: r).run(options(nil))
        let port = PiInstaller.stablePort(support: r.support)
        let excluded = (try? r.pippaModels.resourceValues(forKeys: [.isExcludedFromBackupKey]))?.isExcludedFromBackup == true
        return results.allSatisfy(\.isDone) && results.contains { $0.outcome == .modelsFolder(r.pippaModels, shared: false) }
            && !fm.fileExists(atPath: r.sharedModels.path) && excluded
            && port > 0 && PiInstaller.stablePort(support: r.support) == port
            && PippaSettings.load(from: r.support).llamaPort == port
    }

    await runSetupFlowChecks()
    runPiUpgradeChecks()

    // With the real payload: the pinned Pi (version from the payload, scripts/bump-pi.sh) with Pippa's Node, launcher via the terminal path.
    guard let path = ProcessInfo.processInfo.environment["PIPPA_PI_PAYLOAD"], let real = try? PiPayload.inDirectory(URL(fileURLWithPath: path)) else {
        print("– Installer mit echter Ladung übersprungen (PIPPA_PI_PAYLOAD fehlt)")
        return
    }
    check("Installer (real payload): fresh HOME, launcher `pi --version` = \(real.version) with copied Node, start via PiLaunchSpec") {
        let home = fakeHome("real"); defer { discard(home) }
        let r = roots(home, real)
        let installer = PiInstaller(roots: r)
        let started = Date()
        let pi = installer.installPi()
        let seconds = Date().timeIntervalSince(started)
        let viaLauncher = shell(r.entrypoint.path, ["--version"], environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        let spec = installer.launchSpec(modelID: "dummy-1b")
        let viaSpec = spec.flatMap { shell($0.executable.path, $0.launcherArguments + ["--version"], environment: $0.environment) }
        let npm = shell(r.piNode.appendingPathComponent("current/bin/npm").path, ["--version"],
                        environment: ["HOME": home.path, "PATH": r.piNode.appendingPathComponent("current/bin").path + ":/usr/bin:/bin"])
        print(String(format: "    Pi step %.1f s, launcher: %@, spec: %@, npm: %@", seconds, viaLauncher ?? "-", viaSpec ?? "-", npm ?? "-"))
        return pi.isDone && viaLauncher == real.version && viaSpec == real.version && npm != nil
    }
    check("Installer (real payload): own root folder starts without PI_MANAGED_INSTALL_ROOT") {
        let home = fakeHome("real-own"); defer { discard(home) }
        let r = roots(home, real)
        let foreign = home.appendingPathComponent(".npm-global/bin/pi")
        try fm.createDirectory(at: foreign.deletingLastPathComponent(), withIntermediateDirectories: true)
        write("#!/bin/sh\necho 0.9.0\n", foreign)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: foreign.path)
        let installer = PiInstaller(roots: r)
        let pi = installer.installPi()
        let spec = installer.launchSpec(modelID: "dummy-1b")
        let viaSpec = spec.flatMap { shell($0.executable.path, $0.launcherArguments + ["--version"], environment: $0.environment) }
        return pi.isDone && installer.state.layout == .pippaRoot && viaSpec == real.version && spec?.environment["PI_MANAGED_INSTALL_ROOT"] == nil
    }
    // Pi switch with real payloads (scripts/bump-pi.sh sets PIPPA_PI_PAYLOAD_PREVIOUS to the payload of the old pin).
    if let previousPath = ProcessInfo.processInfo.environment["PIPPA_PI_PAYLOAD_PREVIOUS"],
       let previous = try? PiPayload.inDirectory(URL(fileURLWithPath: previousPath)), previous.version != real.version {
        check("Pi-Wechsel (echte Ladungen): \(previous.version) → \(real.version), terminal launcher follows, old release stays") {
            let home = fakeHome("real-upgrade"); defer { discard(home) }
            let old = roots(home, previous)
            guard PiInstaller(roots: old).installPi().isDone else { return false }
            let new = roots(home, real)
            let installer = PiInstaller(roots: new)
            let pi = installer.installPi()
            let viaLauncher = shell(new.entrypoint.path, ["--version"], environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
            let viaSpec = installer.launchSpec(modelID: "dummy-1b").flatMap { shell($0.executable.path, $0.launcherArguments + ["--version"], environment: $0.environment) }
            print("    launcher: \(viaLauncher ?? "-"), spec: \(viaSpec ?? "-")")
            return pi.isDone && viaLauncher == real.version && viaSpec == real.version && fm.fileExists(atPath: old.release(.official).path)
        }
    }
}

// Installer without technical questions (PiSetupFlow): the only question is the download; adoption, models folder,
// Pi and models.json run silently. Download is a stub only (writes the test file), never touches the network.
private final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []
    func add(_ value: Value) { lock.withLock { values.append(value) } }
    var all: [Value] { lock.withLock { values } }
}

private func stubDownload(_ data: Data, fail: (any Error & Sendable)? = nil, calls: Recorder<String>? = nil) -> PiInstaller.Download {
    { model, folder, progress in
        calls?.add(model.key)
        if let fail { progress(0.3, 60); throw fail }
        for step in 1...4 { progress(Double(step) / 4, Double(4 - step) * 10) }
        let name = ((model.pinned?.files.first?.path ?? "") as NSString).lastPathComponent
        try data.write(to: folder.appendingPathComponent(name))
        try (model.pinned?.files.first?.sha256 ?? "").write(to: folder.appendingPathComponent(name + ".ok"), atomically: true, encoding: .utf8)
    }
}

func runSetupFlowChecks() async {
    check("Setup: existing model adopted without asking, no download, models folder in the support folder") {
        let home = fakeHome("flow-adopt"); defer { discard(home) }
        let payload = try fakePayload(in: home.appendingPathComponent("src"))
        let r = roots(home, payload)
        let (model, data) = dummyModel()
        let source = home.appendingPathComponent(".lmstudio/models/fixture/dummy/Dummy-1B-Q4_K_M.gguf")
        try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: source)
        let calls = Recorder<String>()
        let search = ExistingModels.defaultRoots(home: home)
        let flow = PiSetupFlow(roots: r, model: model, contextWindow: 4096, searchRoots: search, port: 18_471, download: stubDownload(data, calls: calls))
        let before = flow.adoptionSource()
        let state = flow.prepare()
        let again = PiSetupFlow(roots: r, model: model, contextWindow: 4096, searchRoots: search, port: 18_471).prepare()
        let ok = before == "LM Studio" && state == .ready(adoptedFrom: "LM Studio") && calls.all.isEmpty
            && flow.installer.state.modelsFolder == r.pippaModels.path && !fm.fileExists(atPath: r.sharedModels.path)
            && PiInstaller.providerModelIDs(modelsJSON: r.modelsJSON) == ["dummy-1b"]
            && (try? Data(contentsOf: source)) == data && again == .ready(adoptedFrom: nil)
        if !ok { print("   ", before ?? "-", state, again) }
        return ok
    }

    await checkAsync("Setup: the only question is the download (size), everything else is done beforehand; download → ready") {
        let home = fakeHome("flow-download"); defer { discard(home) }
        let payload = try fakePayload(in: home.appendingPathComponent("src"))
        let r = roots(home, payload)
        let (model, data) = dummyModel()
        let flow = PiSetupFlow(roots: r, model: model, contextWindow: 4096, searchRoots: [], port: 18_471, download: stubDownload(data))
        let question = flow.prepare()
        let configuredBefore = PiInstaller.providerModelIDs(modelsJSON: r.modelsJSON) == ["dummy-1b"] && fm.fileExists(atPath: r.release(.official).path)
        let seen = Recorder<Double>()
        let done = await flow.download { value, _ in seen.add(value) }
        let text = PiInstaller.downloadQuestion(bytes: 6_716_356_800)
        let ok = question == .askDownload(bytes: Int64(data.count)) && configuredBefore
            && seen.all == [0.25, 0.5, 0.75, 1] && done == .ready(adoptedFrom: nil)
            && ModelDownloader(directory: r.pippaModels).isInstalled(model)
            && text.contains("10") && text.contains("GB") && !text.contains("Pi ")
        if !ok { print("   ", question, done, seen.all, text) }
        return ok
    }

    await checkAsync("Setup: error as one sentence without a path, technical part in details; \"Try again\" resumes") {
        let home = fakeHome("flow-error"); defer { discard(home) }
        let payload = try fakePayload(in: home.appendingPathComponent("src"))
        let r = roots(home, payload)
        let (model, data) = dummyModel()
        // models.json with a comment (Pi allows that; Pippa does not modify such a file).
        try fm.createDirectory(at: r.agentDirectory, withIntermediateDirectories: true)
        write("// meine Notiz\n{}\n", r.modelsJSON)
        let flow = PiSetupFlow(roots: r, model: model, contextWindow: 4096, searchRoots: [], port: 18_471,
                               download: stubDownload(data, fail: URLError(.networkConnectionLost)))
        let failed = flow.prepare()
        write("{}\n", r.modelsJSON)   // the person cleans up, then "Try again"
        let question = flow.prepare()
        let dropped = await flow.download { _, _ in }
        let retry = PiSetupFlow(roots: r, model: model, contextWindow: 4096, searchRoots: [], port: 18_471, download: stubDownload(data))
        let done = await retry.download { _, _ in }
        guard case .failed(let problem) = failed, case .failed(let offline) = dropped else { print("   ", failed, dropped); return false }
        let offlineKind = { if case .downloadFailed = offline.failure { return true }; return false }()
        let ok = !problem.message.contains("/") && problem.message.range(of: #"\bPi\b"#, options: .regularExpression) == nil
            && problem.details.contains(r.modelsJSON.path) && offline.details.contains("NSURLErrorDomain")
            && problem.canRetry && question == .askDownload(bytes: Int64(data.count))
            && offlineKind && offline.canRetry && !offline.message.contains("NSURL") && done == .ready(adoptedFrom: nil)
        if !ok { print("   ", problem, question, offline, done) }
        return ok
    }

    await checkAsync("Setup: new table model while the old one works (update, \"More thorough\"): ready with the old one, download offered; afterwards the new one, old file kept; switching back is instant") {
        let home = fakeHome("flow-fallback"); defer { discard(home) }
        let payload = try fakePayload(in: home.appendingPathComponent("src"))
        let r = roots(home, payload)
        let (old, oldData) = dummyModel(name: "Old-Q4.gguf", key: "old-model")
        let (new, newData) = dummyModel(name: "New-Q4.gguf", bytes: 524_288, key: "new-model")
        let catalog = ModelCatalog(sampling: [:], models: [old, new])
        // Before the update: the old table model is set up and listed in models.json.
        let before = PiSetupFlow(roots: r, model: old, contextWindow: 4096, searchRoots: [], port: 18_471, catalog: catalog, download: stubDownload(oldData))
        guard case .askDownload = before.prepare(), await before.download(progress: { _, _ in }) == .ready(adoptedFrom: nil) else { return false }
        // After the update the table names `new`: no question, the old one keeps answering, the download is offered.
        let after = PiSetupFlow(roots: r, model: new, contextWindow: 8192, searchRoots: [], port: 18_471, catalog: catalog, download: stubDownload(newData))
        let waiting = after.prepare()
        let keptOld = PiInstaller.providerModelIDs(modelsJSON: r.modelsJSON) == ["old-model"]
            && PiInstaller.providerContextWindow(modelsJSON: r.modelsJSON, id: "old-model") == 4096
        let offered = after.pendingDownload == Int64(newData.count) && after.activeModelKey == "old-model"
        let done = await after.download { _, _ in }
        let switched = PiInstaller.providerModelIDs(modelsJSON: r.modelsJSON) == ["new-model"] && after.pendingDownload == nil
            && after.activeModelKey == "new-model" && ModelDownloader(directory: r.pippaModels).isInstalled(old)
        // Back (e.g. "Standard" again): already there, so instant and without a download.
        let back = PiSetupFlow(roots: r, model: old, contextWindow: 4096, searchRoots: [], port: 18_471, catalog: catalog, download: stubDownload(Data()))
        let backState = back.prepare()
        let backOK = backState == .ready(adoptedFrom: nil) && back.pendingDownload == nil
            && PiInstaller.providerModelIDs(modelsJSON: r.modelsJSON) == ["old-model"]
        // Without a usable previous model (file gone) it is the normal question again.
        try fm.removeItem(at: r.pippaModels.appendingPathComponent("New-Q4.gguf"))
        try fm.removeItem(at: r.pippaModels.appendingPathComponent("Old-Q4.gguf"))
        let none = PiSetupFlow(roots: r, model: new, contextWindow: 8192, searchRoots: [], port: 18_471, catalog: catalog).prepare()
        let ok = waiting == .ready(adoptedFrom: nil) && keptOld && offered && done == .ready(adoptedFrom: nil) && switched && backOK
            && none == .askDownload(bytes: Int64(newData.count))
        if !ok { print("   ", waiting, keptOld, offered, done, switched, backState, none) }
        return ok
    }

    check("Setup: texts without \"Pi\", \"Terminal\" and paths (en and de)") {
        var bad: [String] = []
        for language in ["en", "de"] {
            let url = repoRoot.appendingPathComponent("app/Sources/PippaCore/Resources/\(language).lproj/Setup.strings")
            guard let table = NSDictionary(contentsOf: url) as? [String: String], !table.isEmpty else { return false }
            for value in table.values where value.range(of: #"\bPi\b|Terminal|~/|/Users|models\.json"#, options: .regularExpression) != nil {
                bad.append("\(language): \(value)")
            }
        }
        if !bad.isEmpty { print("   ", bad) }
        return bad.isEmpty
    }
}

// Pi switch with a Pippa update (docs/updating-pi.md "Existing installs"): new pin next to the old one, the
// terminal Pi only follows in the layout Pippa created, self-test with rollback, cleanup only of Pippa's
// own releases, a newer version chosen by the person stays.
private func upgradePayload(_ home: URL, _ version: String, node: String? = nil) throws -> PiPayload {
    let payload = try fakePayload(in: home.appendingPathComponent("src-\(version)"), version: version)
    if let node {
        write("#!/bin/sh\nif [ \"$1\" = --version ]; then echo \(node); exit 0; fi\n"
              + "if [ \"$2\" = --version ]; then cat \"$(dirname \"$(readlink -f \"$1\")\")/fake-version\"; exit 0; fi\nexit 3\n", payload.node)
    }
    return payload
}

private func currentVersion(_ r: PiInstallRoots) -> String? {
    (try? String(contentsOf: r.managedRoot.appendingPathComponent("current-version"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
}

func runPiUpgradeChecks() {
    check("Pi switch: new Pippa (pin 1.1.0) brings the terminal Pi along, old release stays, Node alongside; then 1.2.0 removes 1.0.4") {
        let home = fakeHome("upgrade"); defer { discard(home) }
        let first = roots(home, try upgradePayload(home, "1.0.4"))
        guard PiInstaller(roots: first).installPi().isDone else { return false }
        let second = roots(home, try upgradePayload(home, "1.1.0", node: "v22.99.0"))
        let installer = PiInstaller(roots: second)
        let pi = installer.installPi()
        let viaTerminal = shell(second.entrypoint.path, ["--version"], environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        let spec = installer.launchSpec(modelID: "dummy-1b")
        let nodeLink = try? fm.destinationOfSymbolicLink(atPath: second.piNode.appendingPathComponent("current").path)
        let ok1 = pi.outcome == .piInstalled(layout: .official, release: second.release(.official), reused: false)
            && currentVersion(second) == "1.1.0" && viaTerminal == "1.1.0"
            && fm.fileExists(atPath: first.release(.official).path) && installer.state.previousPin == "1.0.4"
            && spec?.launcherArguments == [PiPayload.cliEntry(release: second.release(.official)).path]
            && nodeLink == "v22.99.0" && fm.fileExists(atPath: second.piNode.appendingPathComponent("v22.23.3/bin/node").path)
        let third = roots(home, try upgradePayload(home, "1.2.0"))
        let next = PiInstaller(roots: third)
        let pi3 = next.installPi()
        let ok2 = pi3.isDone && currentVersion(third) == "1.2.0"
            && !fm.fileExists(atPath: first.release(.official).path) && !next.state.didCreate(first.release(.official))
            && fm.fileExists(atPath: second.release(.official).path) && fm.fileExists(atPath: third.release(.official).path)
        if !(ok1 && ok2) { print("   ", pi.outcome, currentVersion(second) ?? "-", viaTerminal ?? "-", nodeLink ?? "-", pi3.outcome) }
        return ok1 && ok2
    }

    check("Pi switch: if the person moved to a newer version themselves (pi update), it stays; Pippa uses its pin alongside") {
        let home = fakeHome("upgrade-newer"); defer { discard(home) }
        let first = roots(home, try upgradePayload(home, "1.0.4"))
        guard PiInstaller(roots: first).installPi().isDone else { return false }
        let theirs = first.managedRoot.appendingPathComponent("releases/1.3.0", isDirectory: true)
        try fm.copyItem(at: try upgradePayload(home, "1.3.0").release, to: theirs)
        write("1.3.0\n", first.managedRoot.appendingPathComponent("current-version"))   // like Pi's activateManagedRelease
        let second = roots(home, try upgradePayload(home, "1.1.0"))
        let installer = PiInstaller(roots: second)
        let pi = installer.installPi()
        let viaTerminal = shell(second.entrypoint.path, ["--version"], environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        let viaSpec = installer.launchSpec(modelID: "dummy-1b").flatMap { shell($0.executable.path, $0.launcherArguments + ["--version"], environment: $0.environment) }
        return pi.isDone && currentVersion(second) == "1.3.0" && viaTerminal == "1.3.0" && viaSpec == "1.1.0"
            && fm.fileExists(atPath: theirs.path) && !installer.state.didCreate(theirs)
    }

    check("Pi switch: if the self-test via the launcher fails, the old version applies again; Pippa's own start still works") {
        let home = fakeHome("upgrade-rollback"); defer { discard(home) }
        let first = roots(home, try upgradePayload(home, "1.0.4"))
        guard PiInstaller(roots: first).installPi().isDone else { return false }
        // The terminal's Node cannot start the new version (e.g. too old): `node <cli> --version` fails.
        let terminalNode = first.piNode.appendingPathComponent("v22.23.3/bin/node")
        write("#!/bin/sh\nif [ \"$1\" = --version ]; then echo v22.23.3; exit 0; fi\n"
              + "case \"$1\" in *1.1.0*) exit 1;; esac\ncat \"$(dirname \"$(readlink -f \"$1\")\")/fake-version\"\n", terminalNode)
        let second = roots(home, try upgradePayload(home, "1.1.0"))
        let installer = PiInstaller(roots: second)
        let pi = installer.installPi()
        let viaTerminal = shell(second.entrypoint.path, ["--version"], environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        let viaSpec = installer.launchSpec(modelID: "dummy-1b").flatMap { shell($0.executable.path, $0.launcherArguments + ["--version"], environment: $0.environment) }
        let leftovers = (try? fm.contentsOfDirectory(atPath: second.managedRoot.path))?.filter { $0.hasPrefix("current-version.") } ?? []
        return pi.isDone && currentVersion(second) == "1.0.4" && viaTerminal == "1.0.4" && viaSpec == "1.1.0" && leftovers.isEmpty
    }

    check("Pi switch: the person's managed Pi (not Pippa's): current-version stays, only Pippa's old release is cleaned up") {
        let home = fakeHome("upgrade-theirs"); defer { discard(home) }
        let payload104 = try upgradePayload(home, "1.0.4")
        let first = roots(home, payload104)
        try fm.createDirectory(at: first.managedRoot.appendingPathComponent("releases"), withIntermediateDirectories: true)
        write("{\"kind\": \"pi-managed-install\", \"schemaVersion\": 1, \"layout\": \"releases-v1\"}", first.managedRoot.appendingPathComponent("managed-install.json"))
        write("1.0.3\n", first.managedRoot.appendingPathComponent("current-version"))
        let userRelease = first.managedRoot.appendingPathComponent("releases/1.0.3", isDirectory: true)
        try fm.copyItem(at: try upgradePayload(home, "1.0.3").release, to: userRelease)
        guard PiInstaller(roots: first).installPi().isDone else { return false }
        let second = roots(home, try upgradePayload(home, "1.1.0"))
        let installer = PiInstaller(roots: second)
        let pi = installer.installPi()
        let third = roots(home, try upgradePayload(home, "1.2.0"))
        let pi3 = PiInstaller(roots: third).installPi()
        return pi.outcome == .piInstalled(layout: .addedRelease, release: second.release(.addedRelease), reused: false) && pi3.isDone
            && currentVersion(third) == "1.0.3" && fm.fileExists(atPath: userRelease.path)
            && !fm.fileExists(atPath: first.release(.addedRelease).path)      // Pippa's 1.0.4: neither pin nor previous pin
            && fm.fileExists(atPath: second.release(.addedRelease).path) && fm.fileExists(atPath: third.release(.addedRelease).path)
            && !fm.fileExists(atPath: third.launcher.path)
    }

    check("Pi switch: if `pi update` removed Pippa's release (Pi ≥ 1.1.0 keeps only two), the next start recreates it") {
        let home = fakeHome("upgrade-pruned"); defer { discard(home) }
        let r = roots(home, try upgradePayload(home, "1.1.0"))
        guard PiInstaller(roots: r).installPi().isDone else { return false }
        try fm.removeItem(at: r.release(.official))
        let installer = PiInstaller(roots: r)
        let before = installer.launchSpec(modelID: "dummy-1b")
        let pi = installer.installPi()
        return before == nil && pi.outcome == .piInstalled(layout: .official, release: r.release(.official), reused: false)
            && installer.launchSpec(modelID: "dummy-1b") != nil
    }
}
