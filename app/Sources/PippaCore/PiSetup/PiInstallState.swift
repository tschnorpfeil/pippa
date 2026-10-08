import Foundation

/// Where Pippa puts the pinned Pi.
public enum PiLayout: String, Codable, Sendable, Equatable {
    /// No Pi found: official layout with marker, current-version, launcher and ~/.local/bin/pi.
    case official
    /// Managed Pi present: only add `releases/<pin>`, current-version and launcher stay untouched.
    case addedRelease
    /// Foreign-installed `pi` (npm global, Nix …): own root folder in the support folder.
    case pippaRoot
}

/// What `detect` found.
public enum PiDetection: Codable, Sendable, Equatable {
    case none
    /// Valid marker in ~/.pi/agent/install; `currentVersion` from current-version (if readable).
    case managed(currentVersion: String?)
    /// A `pi` outside the managed installation, or an install folder without a valid marker.
    case unmanaged(path: String)

    public var layout: PiLayout {
        switch self { case .none: .official; case .managed: .addedRelease; case .unmanaged: .pippaRoot }
    }
}

public enum PiInstallStep: String, Codable, Sendable, CaseIterable {
    case detect, pi, modelsFolder, model, provider, ready
}

public enum PiAdoptionMethod: String, Codable, Sendable { case clone, hardlink, copy }

/// Typed errors. The texts for the person are in `PiStepResult.message`.
public enum PiInstallFailure: Error, Sendable, Equatable {
    /// The install payload is missing or incomplete (app damaged).
    case payloadMissing(String)
    /// `pi --version` reports something other than the pin (or nothing readable).
    case versionMismatch(found: String, expected: String)
    /// `releases/<pin>` already exists, does not run, and does not belong to Pippa.
    case releaseBroken(String)
    case notWritable(path: String, reason: String)
    /// models.json is not readable JSON (e.g. comments); nothing changed.
    case modelsJSONUnreadable(String)
    /// An existing model file does not match the catalog (SHA-256). It stays untouched.
    case checksumMismatch(String)
    case notEnoughSpace(bytes: Int64)
    /// A step needs a previous one (e.g. model without model folder).
    case missingStep(PiInstallStep)
    /// The download broke off (network, server); resumable.
    case downloadFailed(String)
}

/// Result of a step. `message`: plain text for the person (en/de, table "Setup").
public struct PiStepResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case detected(PiDetection)
        case piInstalled(layout: PiLayout, release: URL, reused: Bool)
        case modelsFolder(URL, shared: Bool)
        /// `method == nil`: was already verified in the model folder.
        case modelReady(file: URL, method: PiAdoptionMethod?, source: String?)
        /// Nothing suitable on this Mac: the one question ("Laden" · "Später", i.e. load · later), then the ModelDownloader.
        case needsDownload(bytes: Int64)
        case providerWritten(port: Int, backup: URL?, changed: Bool)
        case ready(version: String)
        case failed(PiInstallFailure)
    }
    public var step: PiInstallStep
    public var outcome: Outcome
    public var message: String

    public var isDone: Bool {
        switch outcome {
        case .needsDownload, .failed: false
        default: true
        }
    }
}

/// install-state.json: what Pippa created and how far the run is. Basis for resuming,
/// repairing a step and an uninstall that removes exactly what was created.
public struct PiInstallState: Codable, Sendable, Equatable {
    public struct StepRecord: Codable, Sendable, Equatable {
        /// "started", "done", "needsInput", "failed"
        public var status: String
        public var at: Date
    }
    public struct Adoption: Codable, Sendable, Equatable {
        public var file: String
        public var source: String
        public var method: PiAdoptionMethod
        public var sha256: String
    }

    public var schemaVersion = 1
    public var pin: String?
    /// The pin of the previous Pippa version (Pi change with a Pippa update). Its release stays during cleanup,
    /// as Pi's own `pi update` keeps the previous release (running terminal sessions, going back).
    public var previousPin: String?
    public var detection: PiDetection?
    public var layout: PiLayout?
    /// Absolute paths Pippa created (folders, files, symlinks), in order of creation.
    public var created: [String] = []
    public var steps: [String: StepRecord] = [:]
    public var modelsFolder: String?
    public var modelsFolderShared: Bool?
    public var adopted: [Adoption] = []
    /// One-time backup of the user's models.json before Pippa's first entry.
    public var modelsJSONBackup: String?
    public var providerPort: Int?
    public init() {}

    public static func load(from url: URL) -> PiInstallState {
        guard let data = try? Data(contentsOf: url) else { return PiInstallState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(PiInstallState.self, from: data)) ?? PiInstallState()
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public func didCreate(_ url: URL) -> Bool { created.contains(url.standardizedFileURL.path) }
    mutating func forget(_ url: URL) {
        let path = url.standardizedFileURL.path
        created.removeAll { $0 == path || $0.hasPrefix(path + "/") }
    }
    mutating func record(_ url: URL) {
        let path = url.standardizedFileURL.path
        if !created.contains(path) { created.append(path) }
    }
}
