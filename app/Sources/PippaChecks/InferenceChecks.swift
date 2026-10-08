import Foundation
import PippaCore

func runInferenceChecks() async {
    check("Shortcuts: taken-check reads the macOS list in Carbon format") {
        // ⌃⌥ = 6144, ⌘ = 256; key 49 = space, 35 = P. Other bits (e.g. Fn) do not count.
        let ctrlOpt = UInt32(6144)
        return SystemHotkeys.matches(entryCode: 49, entryModifiers: 6144, code: 49, carbonModifiers: ctrlOpt)
            && SystemHotkeys.matches(entryCode: 49, entryModifiers: 6144 | 0x80_0000, code: 49, carbonModifiers: ctrlOpt)
            && !SystemHotkeys.matches(entryCode: 49, entryModifiers: 256, code: 49, carbonModifiers: ctrlOpt)
            && !SystemHotkeys.matches(entryCode: 49, entryModifiers: 6144, code: 35, carbonModifiers: ctrlOpt)
            && SystemHotkeys.matches(entryCode: 49, entryModifiers: 256, code: 49, carbonModifiers: 256)
    }
    check("'Busy' message without jargon") {
        let text = InferenceError.busy.localizedDescription
        let jargon = ["Modell", "Model", "model", "Pi "]
        return !jargon.contains { text.contains($0) }
            && text == L("I’m still busy with something else. Please try again in a moment.", table: "Core")
    }
    check("Custom models: only loopback counts as local") {
        let local = ["http://localhost:8080/v1", "http://127.0.0.1:8080/v1", "http://[::1]:8080/v1"]
        let remote = ["https://localhost.example/v1", "https://192.168.1.20/v1", "https://127.0.0.1.example/v1"]
        return local.allSatisfy { ModelConnection(provider: .compatible, endpoint: URL(string: $0)!, modelID: "fixture").isLocal }
            && remote.allSatisfy { !ModelConnection(provider: .compatible, endpoint: URL(string: $0)!, modelID: "fixture").isLocal }
    }
    check("Custom models: insecure endpoints are rejected") {
        let endpoints = ["http://api.example/v1", "https://key@api.example/v1", "https://api.example/v1?key=secret", "https://api.example/v1#fragment", "file:///tmp/model"]
        return endpoints.allSatisfy {
            (try? ModelConnection(provider: .compatible, endpoint: URL(string: $0)!, modelID: "fixture").validated()) == nil
        }
    }
    check("Custom models: model and actual context size are validated") {
        (try? ModelConnection(modelID: " ").validated()) == nil
            && (try? ModelConnection(modelID: "fixture", contextWindow: 1024).validated()) == nil
            && (try? ModelConnection(modelID: "fixture", contextWindow: 8192).validated()) != nil
    }
    check("Custom models: default stays local, metadata without key") {
        let directory = root.appendingPathComponent("inference-settings")
        let fresh = InferenceSettings.load(from: directory)
        guard fresh.policy == .localOnly, fresh.connection == nil else { return false }
        let connection = ModelConnection(modelID: "fixture")
        // Merely saving a connection must never opt a new user into external inference.
        try InferenceSettings(connection: connection).save(to: directory)
        guard InferenceSettings.load(from: directory).policy == .localOnly else { return false }
        let settings = InferenceSettings(policy: .ask, connection: connection)
        try settings.save(to: directory)
        let data = try Data(contentsOf: directory.appendingPathComponent("inference-settings.json"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return InferenceSettings.load(from: directory) == settings
            && object?["apiKey"] == nil && object?["credential"] == nil
    }
    check("Custom models: corrupted settings do not enable the cloud") {
        let directory = root.appendingPathComponent("invalid-inference-settings")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"policy\":\"customAlways\",\"connection\":\"broken\"}".utf8).write(to: directory.appendingPathComponent("inference-settings.json"))
        return InferenceSettings.load(from: directory).policy == .localOnly
    }
    check("Custom models: cloud routing without a connection is not loaded") {
        let directory = root.appendingPathComponent("missing-inference-connection")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"policy\":\"customAlways\"}".utf8).write(to: directory.appendingPathComponent("inference-settings.json"))
        return InferenceSettings.load(from: directory).policy == .localOnly
    }
}
