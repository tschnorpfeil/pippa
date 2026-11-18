import CryptoKit
import Darwin
import Foundation

/// The private Pi agent folder of one online Pi process: Pi reads its provider's configuration and credential only here,
/// never from the shared `~/.pi/agent`, so the recipient PiSession checked is the one every request of that process reaches.
///
/// Pi 1.5 rereads `auth.json` for each provider request (`AuthStorage.readLatestData`) and `models.json` on every model
/// refresh. With the shared folder a sign-in or key change between PiSession's last check and the request would send an
/// approved message, or history kept for one account, to another. Here Pi gets `PI_CODING_AGENT_DIR` = this folder with:
///
/// - `models.json`: only the active provider's entry (or Pippa's `pippa-online` entry built from the connection);
/// - `auth.json`: only that provider's stored credential, nothing else from the person's file;
/// - `models-store.json`: only that provider's cached catalog, so its models stay known offline;
/// - `settings.json`: Pi's settings as they are (no credentials).
///
/// The folder and its files are 0700/0600 like Pi's own. A token Pi refreshes in here is written back to the shared
/// `auth.json` (`writeBack`), only while that entry is still the one copied, under Pi's lock; nothing else is ever
/// written there. Only digests are kept beside the copy; no credential is logged.
public struct PiRecipientSnapshot: Sendable {
    public let directory: URL
    public let providerID: String

    static let sourceFile = "pippa-source.json"

    /// Snapshot for a Pi provider (built in or registered in models.json) from `agent`, Pi's shared folder.
    public static func create(model: PiModelSelection, from agent: URL, in parent: URL) throws -> PiRecipientSnapshot {
        let modelsJSON = agent.appendingPathComponent("models.json")
        var models: [String: Any]?
        if FileManager.default.fileExists(atPath: modelsJSON.path) {
            guard let document = JSONFile.readObject(modelsJSON) else { throw PiInstallFailure.modelsJSONUnreadable(modelsJSON.path) }
            if let entry = (document["providers"] as? [String: Any])?[model.providerID] { models = [model.providerID: entry] }
        }
        let authJSON = agent.appendingPathComponent("auth.json")
        var credential: Any?
        if FileManager.default.fileExists(atPath: authJSON.path) {
            guard let document = JSONFile.readObject(authJSON) else { throw PiInstallFailure.notWritable(path: authJSON.path, reason: "unreadable") }
            credential = document[model.providerID]
        }
        let store = JSONFile.readObject(agent.appendingPathComponent("models-store.json"))?[model.providerID]
        return try write(provider: model.providerID, agent: agent, parent: parent, models: models, credential: credential, store: store)
    }

    /// Snapshot for an older Keychain connection: `pippa-online` exactly as PiSession describes it; the key stays in
    /// Pi's environment (`PIPPA_ONLINE_KEY`), never in a file.
    public static func create(connection: ModelConnection, from agent: URL, in parent: URL) throws -> PiRecipientSnapshot {
        try write(provider: PiOnlineProvider.providerKey, agent: agent, parent: parent,
                  models: [PiOnlineProvider.providerKey: PiOnlineProvider.entry(connection)], credential: nil, store: nil)
    }

    private static func write(provider: String, agent: URL, parent: URL, models: [String: Any]?, credential: Any?,
                              store: Any?) throws -> PiRecipientSnapshot {
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = parent.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let snapshot = PiRecipientSnapshot(directory: directory, providerID: provider)
        do {
            if let models { try secureWrite(JSONFile.encode(["providers": models]), to: directory.appendingPathComponent("models.json")) }
            if let credential { try secureWrite(JSONFile.encode([provider: credential]), to: directory.appendingPathComponent("auth.json")) }
            if let store { try secureWrite(JSONFile.encode([provider: store]), to: directory.appendingPathComponent("models-store.json")) }
            if let settings = try? Data(contentsOf: agent.appendingPathComponent("settings.json")) {
                try secureWrite(settings, to: directory.appendingPathComponent("settings.json"))
            }
            try snapshot.record(agent: agent, credential: credential.flatMap(digest))
        } catch {
            snapshot.remove()
            throw error
        }
        return snapshot
    }

    /// The shared folder and the copied credential's digest, so a refresh can be written back after a crash too.
    private func record(agent: URL, credential: String?) throws {
        var source: [String: Any] = ["agent": agent.path, "provider": providerID]
        if let credential { source["credential"] = credential }
        try Self.secureWrite(JSONFile.encode(source), to: directory.appendingPathComponent(Self.sourceFile), replace: true)
    }

    private var source: (agent: URL, credential: String?)? {
        guard let object = JSONFile.readObject(directory.appendingPathComponent(Self.sourceFile)),
              object["provider"] as? String == providerID, let agent = object["agent"] as? String else { return nil }
        return (URL(fileURLWithPath: agent, isDirectory: true), object["credential"] as? String)
    }

    /// The credential Pi holds in this folder now.
    private var current: Any? { JSONFile.readObject(directory.appendingPathComponent("auth.json"))?[providerID] }

    public enum WriteBack: Equatable, Sendable {
        /// Nothing to do: Pi did not change the credential, or the shared file already has it.
        case unchanged
        /// Pi refreshed the credential; the shared `auth.json` has it now.
        case written
        /// The shared entry changed meanwhile (another sign-in or refresh): it stays, and this copy is outdated.
        case superseded
        /// The shared file could not be locked, read or written; the copy is kept for the next attempt.
        case failed
    }

    /// Writes a credential Pi refreshed in this folder back to the shared `auth.json`: only this provider's entry, only
    /// while the shared entry is still the one that was copied, under Pi's own lock (`auth.json.lock`, proper-lockfile).
    @discardableResult
    public func writeBack() -> WriteBack {
        guard let source, let credential = current, let refreshed = Self.digest(credential) else { return .unchanged }
        if refreshed == source.credential { return .unchanged }
        let shared = source.agent.appendingPathComponent("auth.json")
        guard let lock = Self.lock(shared) else { return .failed }
        defer { rmdir(lock.path) }
        guard let document = JSONFile.readObject(shared) else { return .failed }
        let existing = document[providerID].flatMap(Self.digest)
        if existing == refreshed { return (try? record(agent: source.agent, credential: refreshed)) == nil ? .failed : .unchanged }
        guard existing == source.credential else { return .superseded }
        var next = document
        next[providerID] = credential
        do {
            try Self.secureWrite(JSONFile.encode(next), to: shared, replace: true)
            try record(agent: source.agent, credential: refreshed)
        } catch { return .failed }
        return .written
    }

    /// Whether the shared `auth.json` still holds the credential this folder started from or Pi refreshed here. A running
    /// Pi is reused only then; otherwise it restarts with the newer credential (or a new recipient).
    public var isCurrent: Bool {
        guard let source else { return false }
        let shared = JSONFile.readObject(source.agent.appendingPathComponent("auth.json"))?[providerID].flatMap(Self.digest)
        return shared == source.credential || (shared != nil && shared == current.flatMap(Self.digest))
    }

    public func remove() { try? FileManager.default.removeItem(at: directory) }

    /// Folders left by a Pippa that ended without removing them: refreshed credentials are written back first.
    public static func sweep(_ parent: URL, keeping kept: URL? = nil) {
        let fm = FileManager.default
        for folder in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        where folder.standardizedFileURL != kept?.standardizedFileURL {
            let provider = JSONFile.readObject(folder.appendingPathComponent(sourceFile))?["provider"] as? String
            if let provider, PiRecipientSnapshot(directory: folder, providerID: provider).writeBack() == .failed { continue }
            try? fm.removeItem(at: folder)
        }
    }

    // MARK: Files

    static func digest(_ value: Any) -> String? {
        JSONFile.canonical(value).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }

    /// Created with mode 0600 from the first byte (never readable by others, not even briefly), then renamed into place.
    static func secureWrite(_ data: Data, to url: URL, replace: Bool = false) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PiInstallFailure.notWritable(path: url.path, reason: SystemError.reason(errno: errno)) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        let synced = fsync(fd) == 0
        close(fd)
        guard written == data.count, synced, replace || !FileManager.default.fileExists(atPath: url.path),
              rename(temporary.path, url.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw PiInstallFailure.notWritable(path: url.path, reason: SystemError.reason(errno: code))
        }
    }

    /// Use Pi's lock directory. A busy lock belongs to Pi, which manages its own heartbeat and stale-lock recovery.
    static func lock(_ file: URL, attempts: Int = 40) -> URL? {
        let lock = URL(fileURLWithPath: file.path + ".lock")
        for _ in 0..<attempts {
            if mkdir(lock.path, 0o700) == 0 { return lock }
            guard errno == EEXIST else { return nil }
            usleep(50_000)
        }
        return nil
    }
}
