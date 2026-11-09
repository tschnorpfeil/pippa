import Foundation

extension PiInstaller {
    // MARK: 5. models.json

    /// Write only `providers["pippa-local"]` (merge), atomically via a temporary file, with one backup first.
    /// If the file is not readable JSON (also: comments, which Pi allows), it stays unchanged.
    public func writeProvider(models: [PiProviderModel], port: Int) -> PiStepResult {
        begin(.provider)
        let url = roots.modelsJSON
        let loaded: (document: [String: Any], existed: Bool)
        do { loaded = try Self.loadModelsJSON(url) }
        catch { return finish(.provider, .failed(failure(error, path: url))) }
        var document = loaded.document
        let existed = loaded.existed
        var providers = document["providers"] as? [String: Any] ?? [:]
        let keyFile = Self.keyFile(support: roots.support)
        do {
            let had = fm.fileExists(atPath: keyFile.path)
            _ = try Self.stableKey(support: roots.support)
            if !had { state.record(keyFile); save() }
        } catch { return finish(.provider, .failed(failure(error, path: keyFile))) }
        let entry = Self.providerEntry(models: models, port: port, keyFile: keyFile)
        if let current = providers[Self.providerKey], JSONFile.canonical(current) == JSONFile.canonical(entry) {
            state.providerPort = port
            return finish(.provider, .providerWritten(port: port, backup: state.modelsJSONBackup.map(URL.init(fileURLWithPath:)), changed: false))
        }
        providers[Self.providerKey] = entry
        document["providers"] = providers
        do {
            try makeDirectory(url.deletingLastPathComponent())
            if existed, state.modelsJSONBackup == nil {
                let stamp = Self.stampFormatter.string(from: Date())
                let backup = url.deletingLastPathComponent().appendingPathComponent("models.json.pippa-\(stamp).bak")
                try fm.copyItem(at: url, to: backup)
                state.modelsJSONBackup = backup.path
                state.record(backup)
            }
            try JSONFile.writeAtomically(JSONFile.encode(document), to: url)
            if !existed { state.record(url) }
        } catch { return finish(.provider, .failed(failure(error, path: url))) }
        state.providerPort = port
        return finish(.provider, .providerWritten(port: port, backup: state.modelsJSONBackup.map(URL.init(fileURLWithPath:)), changed: true))
    }

    /// Merges `PiModelTuning` into Pi's settings.json (atomically, keeps everything else). A file that is not
    /// readable JSON stays unchanged (`false`).
    @discardableResult
    public func writeModelTuning(models: [PiProviderModel]) -> Bool {
        let url = roots.piSettingsJSON
        let existed = fm.fileExists(atPath: url.path)
        var document: [String: Any] = [:]
        if existed {
            guard let object = JSONFile.readObject(url) else { return false }
            document = object
        }
        let merged = PiModelTuning.merge(into: document, models: models)
        if existed, JSONFile.canonical(merged) == JSONFile.canonical(document) { return true }
        do {
            try makeDirectory(url.deletingLastPathComponent())
            try JSONFile.writeAtomically(JSONFile.encode(merged), to: url)
            if !existed { state.record(url); save() }
            return true
        } catch { return false }
    }

    /// The document for a merge into models.json: empty when the file does not exist yet. A file that is not JSON (also:
    /// comments, which Pi allows) or has no object under `providers` is `modelsJSONUnreadable` and stays unchanged.
    static func loadModelsJSON(_ url: URL) throws -> (document: [String: Any], existed: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([:], false) }
        guard let object = JSONFile.readObject(url), object["providers"] == nil || object["providers"] is [String: Any] else {
            throw PiInstallFailure.modelsJSONUnreadable(url.path)
        }
        return (object, true)
    }

    /// `providers` of a models.json (`nil` if unreadable or not listed).
    static func providers(modelsJSON: URL) -> [String: Any]? {
        JSONFile.readObject(modelsJSON)?["providers"] as? [String: Any]
    }

    /// Model ids of `pippa-local` in a models.json (empty if unreadable or not listed).
    public static func providerModelIDs(modelsJSON: URL) -> [String] {
        (provider(modelsJSON: modelsJSON)?["models"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    /// Port from `baseUrl` of `pippa-local` (the app starts its server exactly there). `nil`: not listed.
    public static func providerPort(modelsJSON: URL) -> Int? {
        (provider(modelsJSON: modelsJSON)?["baseUrl"] as? String).flatMap(URL.init(string:))?.port
    }

    /// `contextWindow` of a model of `pippa-local`.
    public static func providerContextWindow(modelsJSON: URL, id: String) -> Int? {
        (provider(modelsJSON: modelsJSON)?["models"] as? [[String: Any]])?.first { $0["id"] as? String == id }?["contextWindow"] as? Int
    }

    static func provider(modelsJSON: URL) -> [String: Any]? {
        providers(modelsJSON: modelsJSON)?[providerKey] as? [String: Any]
    }

    /// Compatible endpoint (Pi docs models.md): fixed port, key via `!command` from the key file.
    /// Pi 1.0.4 (`resolveConfigValueOrThrow`): a value with a leading `!` runs via `/bin/sh -c` (execSync, 10 s
    /// timeout), trimmed stdout is the key; for models.json **fresh on every request, no cache**. The path
    /// is in single quotes (`Application Support` has a space), `cat` with absolute path so that
    /// a foreign `cat` in the terminal's PATH changes nothing.
    public static func providerEntry(models: [PiProviderModel], port: Int, keyFile: URL) -> [String: Any] {
        ["baseUrl": "http://127.0.0.1:\(port)/v1", "api": "openai-completions", "apiKey": "!/bin/cat " + shellQuoted(keyFile.path),
         "models": models.map { model -> [String: Any] in
             var entry: [String: Any] = ["id": model.id, "name": model.name, "contextWindow": model.contextWindow, "maxTokens": model.maxTokens]
             // How Pi switches the model's thinking (PiModelTuning); without it Pi never asks for any.
             if let style = PiReasoningStyle.of(modelKey: model.id) { entry.merge(style.modelFields) { $1 } }
             return entry
         }]
    }

    /// For `/bin/sh`: in single quotes, a `'` inside as `'\\''`.
    public static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}
