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
/// - `auth.json`: only that provider's credential, prepared by Pi itself (`prepare`) and pinned: an OAuth sign-in keeps
///   its access token but no refresh token and no expiry Pi would act on, so this Pi never renews it;
/// - `models-store.json`: only that provider's cached catalog, so its models stay known offline;
/// - `settings.json`: Pi's settings as they are (no credentials).
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
    /// the pinned credential here; the folder's identity is then read from what Pi will use.
    public static func prepare(model: PiModelSelection, from agent: URL, in parent: URL, pi: PiProviderClient) async throws -> PiRecipientSnapshot {
        let snapshot = try copy(model: model, from: agent, in: parent)
        do {
            let prepared: PiProviderEvent
            do { prepared = try await pi.run(["prepare", model.providerID, model.modelID, snapshot.directory.path]) }
            catch PiProviderClient.Failure.signedOut { throw Failure.signedOut }
            catch { throw Failure.unavailable }
            if prepared.endpoint != nil, !PiRecipient.credentialRoutedProviders.contains(model.providerID) { throw Failure.unboundEndpoint }
            // `nil`: a recipient Pippa cannot name (typed words only, never an approval; see `ShareDestination.isVerified`).
            let identity = PiRecipient(agentDirectory: snapshot.directory).identity(model)
            return PiRecipientSnapshot(directory: snapshot.directory, providerID: model.providerID, identity: identity)
        } catch {
            snapshot.remove()
            throw error
        }
    }

    /// The provider's configuration and catalog from `agent`; the credential comes from Pi (`prepare`).
    static func copy(model: PiModelSelection, from agent: URL, in parent: URL) throws -> PiRecipientSnapshot {
        let modelsJSON = agent.appendingPathComponent("models.json")
        var models: [String: Any]?
        if FileManager.default.fileExists(atPath: modelsJSON.path) {
            guard let document = JSONFile.readObject(modelsJSON) else { throw PiInstallFailure.modelsJSONUnreadable(modelsJSON.path) }
            if let entry = (document["providers"] as? [String: Any])?[model.providerID] { models = [model.providerID: entry] }
        }
        let store = JSONFile.readObject(agent.appendingPathComponent("models-store.json"))?[model.providerID]
        return try write(provider: model.providerID, agent: agent, parent: parent, models: models, store: store)
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
            if let settings = try? Data(contentsOf: agent.appendingPathComponent("settings.json")) {
                try secureWrite(settings, to: directory.appendingPathComponent("settings.json"))
            }
        } catch {
            snapshot.remove()
            throw error
        }
        return snapshot
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
