import Darwin
import Foundation

/// The private Pi agent folder of one online Pi process: Pi reads its provider's configuration and credential only here,
/// never from the shared `~/.pi/agent`, so the recipient PiSession checked is the one every request of that process reaches.
///
/// Pi 1.5 rereads `auth.json` for each provider request (`AuthStorage.readLatestData`) and `models.json` on every model
/// refresh. With the shared folder a sign-in or key change between PiSession's last check and the request would send an
/// approved message, or history kept for one account, to another. Here Pi gets `PI_CODING_AGENT_DIR` = this folder with:
///
/// - `models.json`: only the active provider's entry as Pi parsed it (comments and trailing commas as Pi allows them), or
///   Pippa's `pippa-online` entry built from the connection;
/// - `auth.json`: only that provider's credential, prepared by Pi itself (`prepare`) and pinned: an OAuth sign-in keeps
///   its access token but no refresh token and no expiry Pi would act on, so this Pi never renews it;
/// - `models-store.json`: only that provider's cached catalog, so its models stay known offline;
/// - `settings.json`: Pi's settings (no credentials) with Pippa's waits for a provider's rate limit (`retry`).
///
/// Renewal happens only in the shared folder, before each online turn, with Pi's own `ModelRuntime` under Pi's lock: two
/// Pippa processes (or Pi in the terminal) renew a rotating refresh token once, and the endpoint Pi derives from the
/// renewed token is checked before anything is sent. The folder and its files are 0700/0600 like Pi's own. No credential
/// is logged or returned.
public struct PiRecipientSnapshot: Sendable {
    public let directory: URL
    public let providerID: String
    /// The recipient this folder names, as checked when it was prepared (`PiRecipient.Identity`).
    public private(set) var identity: PiRecipient.Identity?

    init(directory: URL, providerID: String, identity: PiRecipient.Identity? = nil) {
        self.directory = directory; self.providerID = providerID; self.identity = identity
    }

    public enum Failure: Error, Equatable {
        /// The folder could not be written or Pi could not resolve the provider from it.
        case unavailable
        /// Pi's renewal of the sign-in was refused: the person signs in again in Settings.
        case signedOut
        /// Pi derives an endpoint from the credential for a provider Pippa cannot bind it for.
        case unboundEndpoint
    }

    /// One online turn's folder for a Pi provider (built in or registered in models.json) from `agent`, Pi's shared folder.
    /// `pi` runs Pi's own resolver there (`pi-providers.mjs prepare`), renewing a sign-in due within the turn and writing
    /// the provider's configuration and pinned credential here, read with Pi's own parser; the folder's identity is then
    /// read from what Pi will use, and the endpoint Pi derives from the credential must be the one that identity names.
    public static func prepare(model: PiModelSelection, from agent: URL, in parent: URL, pi: PiProviderClient) async throws -> PiRecipientSnapshot {
        let snapshot = try copy(model: model, from: agent, in: parent)
        do {
            let prepared: PiProviderEvent
            do { prepared = try await pi.run(["prepare", model.providerID, model.modelID, snapshot.directory.path]) }
            catch PiProviderClient.Failure.signedOut { throw Failure.signedOut }
            catch { throw Failure.unavailable }
            let pinned = PiRecipient(agentDirectory: snapshot.directory)
            // Pi's endpoint for this credential, exactly as the recipient digest names it; none for any other provider.
            guard prepared.endpoint == pinned.endpoint(model) else { throw Failure.unboundEndpoint }
            // `nil`: a recipient Pippa cannot name (typed words only, never an approval; see `ShareDestination.isVerified`).
            let identity = pinned.identity(model)
            return PiRecipientSnapshot(directory: snapshot.directory, providerID: model.providerID, identity: identity)
        } catch {
            snapshot.remove()
            throw error
        }
    }

    /// Pi's settings from `agent`; the provider's configuration, catalog and credential come from Pi (`prepare`).
    static func copy(model: PiModelSelection, from agent: URL, in parent: URL) throws -> PiRecipientSnapshot {
        try write(provider: model.providerID, agent: agent, parent: parent, models: nil, store: nil)
    }

    /// Snapshot for an older Keychain connection: `pippa-online` exactly as PiSession describes it; the key stays in
    /// Pi's environment (`PIPPA_ONLINE_KEY`), never in a file. `recipient`: the connection's, as the route checked it.
    public static func create(connection: ModelConnection, recipient: String = "", from agent: URL, in parent: URL) throws -> PiRecipientSnapshot {
        var snapshot = try write(provider: PiOnlineProvider.providerKey, agent: agent, parent: parent,
                                 models: [PiOnlineProvider.providerKey: PiOnlineProvider.entry(connection)], store: nil)
        if !recipient.isEmpty { snapshot.identity = PiRecipient.Identity(recipient: recipient, account: recipient) }
        return snapshot
    }

    private static func write(provider: String, agent: URL, parent: URL, models: [String: Any]?, store: Any?) throws -> PiRecipientSnapshot {
        let fm = FileManager.default
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = parent.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let snapshot = PiRecipientSnapshot(directory: directory, providerID: provider)
        do {
            if let models { try secureWrite(JSONFile.encode(["providers": models]), to: directory.appendingPathComponent("models.json")) }
            if let store { try secureWrite(JSONFile.encode([provider: store]), to: directory.appendingPathComponent("models-store.json")) }
            try secureWrite(settings(from: agent.appendingPathComponent("settings.json")), to: directory.appendingPathComponent("settings.json"))
        } catch {
            snapshot.remove()
            throw error
        }
        return snapshot
    }

    /// How an online Pi waits when the provider says "too many requests": 15, 30, 60 and 60 seconds, so the waits span a
    /// one-minute limit. Only in this private folder; the shared `~/.pi/agent/settings.json` keeps the person's own.
    static let retry: [String: Int] = ["maxRetries": 4, "baseDelayMs": 15_000, "maxAgentDelayMs": 60_000]

    /// The shared settings with `retry` over them. A file Pippa cannot read as Pi does is copied as it is.
    static func settings(from shared: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: shared.path) else { return try JSONFile.encode(["retry": retry]) }
        guard var object = JSONFile.readPiObject(shared) else { return try (try? Data(contentsOf: shared)) ?? JSONFile.encode(["retry": retry]) }
        // Waits on, also where the person switched Pi's retry off for the terminal.
        object["retry"] = (object["retry"] as? [String: Any] ?? [:]).merging(retry.mapValues { $0 as Any }) { $1 }
            .merging(["enabled": true]) { $1 }
        return try JSONFile.encode(object)
    }

    /// A running Pi keeps going with the credential `prepared` for the next turn: only when both name the same recipient
    /// (configuration, account and derived endpoint), then `prepared`'s folder is removed. Pi rereads auth.json for the
    /// next request; the replacement is atomic.
    public func adopt(_ prepared: PiRecipientSnapshot) throws {
        guard let identity, identity == prepared.identity, providerID == prepared.providerID else { throw Failure.unavailable }
        let source = prepared.directory.appendingPathComponent("auth.json"), target = directory.appendingPathComponent("auth.json")
        if FileManager.default.fileExists(atPath: source.path) {
            guard rename(source.path, target.path) == 0 else { throw Failure.unavailable }
        } else if FileManager.default.fileExists(atPath: target.path) {
            throw Failure.unavailable
        }
        prepared.remove()
    }

    public func remove() { try? FileManager.default.removeItem(at: directory) }

    /// Folders left by a Pippa that ended without removing them. They hold no renewable credential, so nothing goes back.
    public static func sweep(_ parent: URL, keeping kept: URL? = nil) {
        let fm = FileManager.default
        for folder in (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
        where folder.standardizedFileURL != kept?.standardizedFileURL {
            try? fm.removeItem(at: folder)
        }
    }

    // MARK: Files

    /// Created with mode 0600 from the first byte (never readable by others, not even briefly), then renamed into place.
    static func secureWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PiInstallFailure.notWritable(path: url.path, reason: SystemError.reason(errno: errno)) }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        let synced = fsync(fd) == 0
        close(fd)
        guard written == data.count, synced, !FileManager.default.fileExists(atPath: url.path),
              rename(temporary.path, url.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw PiInstallFailure.notWritable(path: url.path, reason: SystemError.reason(errno: code))
        }
    }
}
