import CryptoKit
import Foundation

/// Entry from models/catalog.json (only the fields Pippa needs).
public struct CatalogModel: Sendable, Codable, Hashable {
    public struct File: Sendable, Codable, Hashable { public var path: String; public var size: Int64; public var sha256: String }
    public struct Pinned: Sendable, Codable, Hashable { public var revision: String; public var files: [File] }

    public var key: String
    public var label: String
    public var description: String?
    public var repo: String
    public var quant: String
    public var approxBytes: Int64?
    public var memGiB: Double
    public var ctx: Int
    public var moe: Bool?
    public var rank: Int
    /// Pippa's default thinking level for this model in Pi (`off`, `low`, `medium`); written to Pi's
    /// `modelThinkingLevels` (PiModelTuning). Pi clamps it to what the model supports.
    public var thinking: String?
    public var pending: String?
    public var pinned: Pinned?
    public var sampling: [String: Double]?
    public var extra: [String: JSONScalar]?
}

/// Number or string from the catalog (`extra`).
public enum JSONScalar: Sendable, Codable, Hashable, CustomStringConvertible {
    case number(Double), string(String), bool(Bool)
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else { self = .string(try c.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .number(let d): try c.encode(d); case .string(let s): try c.encode(s); case .bool(let b): try c.encode(b) }
    }
    public var description: String {
        switch self {
        case .number(let d): d == d.rounded() ? String(Int(d)) : String(d)
        case .string(let s): s
        case .bool(let b): b ? "true" : "false"
        }
    }
}

public struct ModelCatalog: Sendable, Codable {
    public var sampling: [String: Double]
    public var models: [CatalogModel]
    public init(sampling: [String: Double], models: [CatalogModel]) { self.sampling = sampling; self.models = models }

    public static func bundled() -> ModelCatalog {
        guard let url = Bundle.module.url(forResource: "catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(ModelCatalog.self, from: data) else {
            return ModelCatalog(sampling: [:], models: [])
        }
        return catalog
    }

    public func model(_ key: String) -> CatalogModel? { models.first { $0.key == key } }
}

/// The concrete choice: model plus server settings.
public struct ModelChoice: Sendable, Hashable {
    public var model: CatalogModel
    public var ctx: Int
    public var extra: [String: String]       // additional llama-server options (without "--")
    public var sampling: [String: Double]
}

/// The one model setting in Pippa's settings ("Pippas Wissen"), only on Macs with 24 GB or more
/// (`ModelSelector.offersThorough`). Plain words in the UI, never model names or quantizations.
public enum ModelPreference: String, Codable, Sendable, CaseIterable {
    /// The table's default (K2 Horizon 7B from 16 GB on).
    case standard
    /// The larger model (Qwen3.6 35B-A3B IQ3), 24 GB and up.
    case thorough
}

/// Chosen by memory size; the only decision is "Standard" or "Gründlicher" on 24 GB and up.
public enum ModelSelector {
    public static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // Under Rosetta, hw.optional.arm64 still reports 1.
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
        #endif
    }

    /// Memory class in GB (8, 16, 24, 32 …), from the physical bytes.
    public static func tierGB(physicalMemory: UInt64) -> Int {
        let gib = Double(physicalMemory) / 1_073_741_824
        switch gib {
        case ..<12: return 8
        case ..<20: return 16
        case ..<28: return 24
        default: return 32
        }
    }

    /// The one table of which model a Mac gets (docs/settings-simplification.md). A change is one line here.
    /// - 8 GB → Qwen3.5 4B (the 9B needs 7 GiB, the 8 GB budget is 4.8 GiB).
    /// - 16 GB and up → Qwen3.5 9B (5.7 GB download): the default for every Mac that fits it. It replaced K2 Horizon 7B
    ///   after a side-by-side test with Pi (docs/rebuild/measurements/model-compare): as reliable, fewer invented facts, ~40 % faster.
    /// - 24 GB and up, "Gründlicher" in settings → Qwen3.6 35B-A3B IQ3 (13.7 GB download, 14.5 GiB of an 18 GiB budget).
    ///   Not the default: the download is too large for first launch.
    /// `preference` counts only where `offersThorough` holds; below, `.thorough` falls back to the standard row.
    /// Keys between the `table` markers are read by scripts/build-app.sh: each must be pinned in catalog.json.
    public static func table(tier: Int, preference: ModelPreference = .standard) -> (key: String, ctx: Int, extra: [String: String]) {
        // table:begin
        switch (tier, preference) {
        case (8, _): ("qwen3.5-4b-q4", 16384, [:])
        case (16, _): ("qwen3.5-9b-q4", 16384, ["ctx-checkpoints": "4", "cache-ram": "0"])
        case (_, .thorough): ("qwen3.6-35b-a3b-iq3", 32768, [:])
        default: ("qwen3.5-9b-q4", 32768, [:])
        }
        // table:end
    }

    /// Memory classes the table distinguishes (`tierGB`).
    public static let tiers = [8, 16, 24, 32]

    /// Settings show "Standard" / "Gründlicher" only on Macs with 24 GB or more.
    public static func offersThorough(physicalMemory: UInt64) -> Bool { tierGB(physicalMemory: physicalMemory) >= 24 }

    /// Every catalog key the table can hand out. A release must have all of them pinned (PippaChecks, build-app.sh).
    public static var tableKeys: [String] {
        var keys: [String] = []
        for tier in tiers {
            for preference in ModelPreference.allCases {
                let key = table(tier: tier, preference: preference).key
                if !keys.contains(key) { keys.append(key) }
            }
        }
        return keys
    }

    public static func choose(physicalMemory: UInt64, preference: ModelPreference = .standard, appleSilicon: Bool = isAppleSilicon,
                              catalog: ModelCatalog = .bundled()) -> Result<ModelChoice, PippaError> {
        guard appleSilicon else {
            return .failure(.unsupportedHardware(L("Pippa needs a Mac with Apple silicon (M1 or later).", table: "Core")))
        }
        let row = table(tier: tierGB(physicalMemory: physicalMemory), preference: preference)
        // An unpinned table model makes the whole setup fail on purpose: a release must never ship one
        // (scripts/pin-model.sh pins it, PippaChecks "default model is pinned" and build-app.sh refuse otherwise).
        guard let model = catalog.model(row.key), model.pending == nil, model.pinned != nil else {
            return .failure(.modelUnavailable)
        }
        return .success(choice(model, ctx: row.ctx, overrides: row.extra, catalog: catalog))
    }

    static func choice(_ model: CatalogModel, ctx: Int, overrides: [String: String], catalog: ModelCatalog) -> ModelChoice {
        var extra = (model.extra ?? [:]).mapValues(\.description)
        for (k, v) in overrides { extra[k] = v }
        let sampling = catalog.sampling.merging(model.sampling ?? [:]) { $1 }
        return ModelChoice(model: model, ctx: min(ctx, model.ctx), extra: extra, sampling: sampling)
    }

    /// Memory budget for Apple Silicon (rule from the former pi-local installer, whose `catalog.mjs` is not in this repo).
    public static func budgetGiB(physicalMemory: UInt64) -> Double {
        let ram = Double(physicalMemory) / 1_073_741_824
        return ram <= 12 ? ram * 0.6 : min(ram * 0.75, ram - 6)
    }

    /// A specific catalog model instead of the table above, only for developers and measurements (`PIPPA_PI_MODEL`,
    /// PippaLive, spikes) and for the model already in Pi's models.json (`PiLocalServer.plan`). The app offers
    /// no choice. If `key` is one of the table's models for this Mac, exactly its entry applies; otherwise context by memory size.
    public static func named(_ key: String, physicalMemory: UInt64, catalog: ModelCatalog = .bundled()) -> ModelChoice? {
        for preference in ModelPreference.allCases {
            if case .success(let row) = choose(physicalMemory: physicalMemory, preference: preference, catalog: catalog), row.model.key == key { return row }
        }
        guard let model = catalog.model(key), model.pinned != nil else { return nil }
        let small = physicalMemory < 20 * 1_073_741_824
        return choice(model, ctx: small ? 16384 : 32768, overrides: small ? ["cache-ram": "0"] : [:], catalog: catalog)
    }
}

/// Download size of the matching model, for the question before the first download.
public struct ModelDownloadSize: Sendable, Equatable {
    public var total: Int64
    /// What is still missing (an interrupted download counts with what was already fetched).
    public var remaining: Int64
    /// What already lies with another program on this Mac and is only adopted (no download).
    public var existing: Int64
    /// Where the existing one comes from, e.g. "LM Studio".
    public var existingSource: String?
    public init(total: Int64, remaining: Int64, existing: Int64 = 0, existingSource: String? = nil) {
        self.total = total; self.remaining = remaining; self.existing = existing; self.existingSource = existingSource
    }

    /// "16,8 GB" (decimal GB as in Finder).
    public static func gigabytes(_ bytes: Int64) -> String {
        L("%.1f GB", table: "Core", Double(max(bytes, 0)) / 1e9)
    }

    /// Approximate duration with fast internet (100 Mbit/s), rounded to 5 minutes: "etwa 25 Minuten".
    public static func durationText(_ bytes: Int64, bitsPerSecond: Double = 100e6) -> String {
        let minutes = Double(max(bytes, 0)) * 8 / bitsPerSecond / 60
        if minutes < 5 { return L("a few minutes", table: "Core") }
        if minutes < 90 { return L("about %lld minutes", table: "Core", Int((minutes / 5).rounded()) * 5) }
        let hours = Int((minutes / 60).rounded())
        return hours == 1 ? L("about an hour", table: "Core") : L("about %lld hours", table: "Core", hours)
    }
}

/// Detects whether a running download is stuck: no progress for as long as `limit` allows.
public struct DownloadStallWatch: Sendable {
    public var limit: TimeInterval
    private var last: Double?
    private var since: Date?
    public init(limit: TimeInterval = 30) { self.limit = limit }

    /// `progress`: current state, `nil` = no download running. Returns whether it is stuck right now.
    public mutating func update(progress: Double?, now: Date = Date()) -> Bool {
        guard let progress else { last = nil; since = nil; return false }
        if progress != last || since == nil { last = progress; since = now; return false }
        return now.timeIntervalSince(since ?? now) >= limit
    }
}

/// Small settings file (settings.json) in the support folder.
public struct PippaSettings: Codable, Sendable, Equatable {
    // Formerly `modelOverride`, `automaticChosen` (old path) and `piModel`: the free model choice no longer exists. Old
    // settings.json files with these keys still load (unknown keys ignored); the table's model applies.
    /// Fixed llama-server port for Pi's models.json (installer, `PiInstaller.stablePort`); chosen once.
    public var llamaPort: Int?
    /// Minutes without a request until Pippa unloads the `pippa-local` model; `nil` = 10
    /// (`PiLocalServer.defaultIdleMinutes`). The next request loads it again.
    public var llamaIdleMinutes: Int?
    /// Port of the former online proxy; unused since Pi talks to the service itself (kept so old settings round-trip).
    public var onlinePort: Int?
    /// On by default: short shown text documents go straight into Pi's
    /// message instead of via a `read_document` round (`PiShownContext.inlineShortLimit`). `nil` = on (also old
    /// settings.json without the key); only an explicit `false` turns it off. Read via `inlinesShortText`.
    public var piInlineShortText: Bool?
    /// Effective value: stored value, else the default (on).
    public var inlinesShortText: Bool { piInlineShortText ?? Self.inlineShortTextDefault }
    public static let inlineShortTextDefault = true
    /// "Pippas Wissen" in settings (24 GB and up), raw value of `ModelPreference`; `nil` or unknown = standard. A string,
    /// so that an unknown value never makes the whole file unreadable (it holds the port). Read via `preference`.
    public var modelPreference: String?
    /// Effective value; counts only where `ModelSelector.offersThorough` holds.
    public var preference: ModelPreference {
        get { modelPreference.flatMap(ModelPreference.init(rawValue:)) ?? .standard }
        set { modelPreference = newValue == .standard ? nil : newValue.rawValue }
    }
    public init(llamaPort: Int? = nil, llamaIdleMinutes: Int? = nil, onlinePort: Int? = nil, piInlineShortText: Bool? = nil,
                modelPreference: String? = nil) {
        self.llamaPort = llamaPort; self.llamaIdleMinutes = llamaIdleMinutes; self.onlinePort = onlinePort
        self.piInlineShortText = piInlineShortText; self.modelPreference = modelPreference
    }

    /// Change only the model preference (load, change, save), so other values written meanwhile stay.
    public static func savePreference(_ preference: ModelPreference, to base: URL) throws {
        var settings = load(from: base)
        settings.preference = preference
        try settings.save(to: base)
    }

    public static func load(from base: URL) -> PippaSettings {
        guard let data = try? Data(contentsOf: base.appendingPathComponent("settings.json")) else { return PippaSettings() }
        return (try? JSONDecoder().decode(PippaSettings.self, from: data)) ?? PippaSettings()
    }

    public func save(to base: URL) throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: base.appendingPathComponent("settings.json"), options: .atomic)
    }
}

/// Downloads model files from Hugging Face: resumable (.part + Range), SHA256 verified before renaming.
public final class ModelDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public static let endpoint = ProcessInfo.processInfo.environment["PIPPA_HF_ENDPOINT"] ?? "https://huggingface.co"

    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public static func url(repo: String, revision: String, path: String) -> URL {
        let encoded = path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        return URL(string: "\(endpoint)/\(repo)/resolve/\(revision)/\(encoded)")!
    }

    public func localURL(_ file: CatalogModel.File) -> URL {
        directory.appendingPathComponent((file.path as NSString).lastPathComponent)
    }

    /// Fully downloaded and verified? (Size plus `.ok` marker with the hash.)
    public func isInstalled(_ model: CatalogModel) -> Bool {
        guard let files = model.pinned?.files, !files.isEmpty else { return false }
        return files.allSatisfy(isInstalled)
    }

    /// Current file size, -1 if the file does not exist. Not via `URL.resourceValues`: it caches the first
    /// value per URL, and resuming then kept restarting from the same spot (the .part file grew endlessly).
    public static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1
    }

    func isInstalled(_ f: CatalogModel.File) -> Bool {
        let url = localURL(f)
        let size = Self.fileSize(url)
        let mark = try? String(contentsOf: url.appendingPathExtension("ok"), encoding: .utf8)
        return size == f.size && mark?.trimmingCharacters(in: .whitespacesAndNewlines) == f.sha256
    }

    public func primaryFile(_ model: CatalogModel) -> URL? { model.pinned?.files.first.map(localURL) }

    /// Total size and what is still missing (finished files don't count, partial ones only with the remainder).
    /// What is in `existing` (with another program) is not missing: it is adopted instead of downloaded.
    public func downloadSize(_ model: CatalogModel, existing: [String: ModelLocation] = [:]) -> ModelDownloadSize? {
        guard let files = model.pinned?.files, !files.isEmpty else { return nil }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        var remaining: Int64 = 0, found: Int64 = 0
        var source: String?
        for f in files where !isInstalled(f) {
            if let e = existing[f.sha256] { found += f.size; source = source ?? e.source; continue }
            remaining += max(0, f.size - max(0, Self.fileSize(localURL(f).appendingPathExtension("part"))))
        }
        return ModelDownloadSize(total: total, remaining: remaining, existing: found, existingSource: source)
    }

    /// Finished or adoptable without download?
    public func isAvailable(_ model: CatalogModel, existing: [String: ModelLocation]) -> Bool {
        guard let files = model.pinned?.files, !files.isEmpty else { return false }
        return files.allSatisfy { isInstalled($0) || existing[$0.sha256] != nil }
    }

    // MARK: Adopting

    /// Adopts a file that already lies on this Mac: copy into Pippa's folder, on APFS as a clone (instant, no
    /// extra space, the source stays untouched). As with downloads, the copy itself is verified (SHA256), once;
    /// the hash decides which of the equally sized `candidates` it is. `nil`: none matches, nothing is left behind.
    /// `onBytes`: verified bytes.
    public func adopt(from source: URL, candidates: [CatalogModel.File], onBytes: ((Int64) -> Void)? = nil) throws -> CatalogModel.File? {
        let size = Self.fileSize(source)
        let matching = candidates.filter { $0.size == size }
        guard let first = matching.first else { return nil }
        let fm = FileManager.default
        do { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw writeFailure(error, remaining: size) }
        excludeFromBackup()
        let copy = localURL(first).appendingPathExtension("import")
        try? fm.removeItem(at: copy) // leftover of an aborted adoption
        // Other volume: no clone possible, the copy needs real space.
        if !Self.sameVolume(source, directory),
           let shortfall = Self.spaceShortfall(available: Self.availableSpace(at: directory), remaining: size) {
            throw PippaError.notEnoughSpace(bytes: shortfall)
        }
        do { try fm.copyItem(at: source, to: copy) } // APFS: clonefile
        catch { try? fm.removeItem(at: copy); throw writeFailure(error, remaining: size) }
        let hash: String
        do { hash = try Self.sha256(of: copy, onBytes: onBytes) }
        catch {
            try? fm.removeItem(at: copy)
            if error is CancellationError { throw error }
            throw writeFailure(error, remaining: 0)
        }
        guard let file = matching.first(where: { $0.sha256 == hash }), Self.fileSize(copy) == file.size else {
            try? fm.removeItem(at: copy) // our own copy
            return nil
        }
        let dest = localURL(file)
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.moveItem(at: copy, to: dest)
            try file.sha256.write(to: dest.appendingPathExtension("ok"), atomically: true, encoding: .utf8)
        } catch { try? fm.removeItem(at: copy); throw writeFailure(error, remaining: 0) }
        try? fm.removeItem(at: dest.appendingPathExtension("part")) // a started download is no longer needed
        return file
    }

    public func adopt(_ file: CatalogModel.File, from source: URL, onBytes: ((Int64) -> Void)? = nil) throws -> Bool {
        try adopt(from: source, candidates: [file], onBytes: onBytes) != nil
    }

    /// Without consent to download: a found file didn't match (content, read error). Nothing is downloaded.
    public struct AdoptionFailed: Error, Sendable { public var sha256: String }

    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        var probe = b
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        let left = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let right = try? probe.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        guard let left, let right else { return false }
        return left.isEqual(right)
    }

    // MARK: Disk space

    /// Buffer beyond the download: the Mac needs room itself, and Pippa writes logs and histories.
    public static let spaceBuffer: Int64 = 2_000_000_000
    /// Below this free amount a running download aborts rather than filling the disk completely.
    public static let spaceFloor: Int64 = 1_000_000_000

    /// How much more would have to be free; `nil` = enough space (or unknown).
    public static func spaceShortfall(available: Int64?, remaining: Int64, buffer: Int64 = spaceBuffer) -> Int64? {
        guard let available, remaining > 0 else { return nil }
        let needed = remaining + buffer
        return available < needed ? needed - available : nil
    }

    /// Free space for "important" data (includes what macOS can free up itself when needed).
    public static func availableSpace(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Disk full or quota exhausted?
    public static func isOutOfSpace(_ error: Error) -> Bool {
        if let p = error as? PippaError, case .notEnoughSpace = p { return true }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(ENOSPC) || ns.code == Int(EDQUOT)) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isOutOfSpace(underlying) }
        return false
    }

    /// Error writing the temporary file: not a network error, so no retry.
    struct WriteFailure: Error { let underlying: Error }

    /// Write error as an understandable message; full disk with the missing space.
    func writeFailure(_ error: Error, remaining: Int64) -> PippaError {
        if Self.isOutOfSpace(error) {
            let shortfall = Self.spaceShortfall(available: Self.availableSpace(at: directory), remaining: remaining) ?? Self.spaceBuffer
            return .notEnoughSpace(bytes: shortfall)
        }
        return .writeFailed(SystemError.reason(error))
    }

    /// Models are large and can be downloaded again any time: keep out of backups (Time Machine, iCloud).
    public func excludeFromBackup() {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    // MARK: Download

    private var handle: FileHandle?
    private var continuation: CheckedContinuation<Int, Error>?
    private var received: Int64 = 0
    private var onData: ((Int64) -> Void)?
    private var activeTask: URLSessionDataTask?
    private var transferCancelled = false
    private var writeError: Error?
    /// Bytes written since the last space check (checked about every 256 MB).
    private var sinceSpaceCheck: Int64 = 0
    private let lock = NSLock()

    /// Downloads all files. `progress(done 0…1, remaining time in s)`. Files from `existing` are adopted instead of downloaded.
    /// If one does not match, `rejected` reports its hash; it is then downloaded only with `allowNetwork`, else `AdoptionFailed`.
    public func download(_ model: CatalogModel, existing: [String: ModelLocation] = [:], allowNetwork: Bool = true,
                         rejected: @Sendable (String) -> Void = { _ in },
                         progress: @escaping @Sendable (Double, TimeInterval?) -> Void) async throws {
        guard let pinned = model.pinned else { throw PippaError.modelUnavailable }
        let total = pinned.files.reduce(Int64(0)) { $0 + $1.size }
        // File errors are not network errors: report as write error or full disk, not as "no internet".
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { throw writeFailure(error, remaining: total) }
        excludeFromBackup()
        // Check beforehand that the rest fits on disk, so it doesn't fail hours in.
        let remainingBytes = downloadSize(model, existing: existing)?.remaining ?? total
        if let shortfall = Self.spaceShortfall(available: Self.availableSpace(at: directory), remaining: remainingBytes) {
            throw PippaError.notEnoughSpace(bytes: shortfall)
        }
        var completed: Int64 = 0
        let started = Date()
        var startBytes: Int64? = nil
        for file in pinned.files {
            try Task.checkCancellation()
            let dest = localURL(file)
            if isInstalled(file) {
                completed += file.size; continue
            }
            if let found = existing[file.sha256] {
                let base = completed
                do {
                    if try adopt(file, from: found.url, onBytes: { progress(Double(base + $0) / Double(total), nil) }) {
                        DiagnosticsLog.shared.event("modell-uebernommen", ["quelle": found.source])
                        completed += file.size
                        progress(Double(completed) / Double(total), nil)
                        continue
                    }
                    DiagnosticsLog.shared.event("modell-uebernahme-passt-nicht", ["quelle": found.source])
                } catch is CancellationError { throw CancellationError() }
                catch let p as PippaError where Self.isOutOfSpace(p) { throw p }
                catch { DiagnosticsLog.shared.event("modell-uebernahme-fehler", ["quelle": found.source]) }
                rejected(file.sha256)
                // Without consent never silently fall back to the network.
                guard allowNetwork else { throw AdoptionFailed(sha256: file.sha256) }
                // Otherwise download as usual (the space checked earlier may not suffice then; the download notices).
            } else if !allowNetwork {
                throw AdoptionFailed(sha256: file.sha256)
            }
            let part = dest.appendingPathExtension("part")
            let base = completed
            var attempts = 0
            while true {
                try Task.checkCancellation()
                let have = max(0, Self.fileSize(part))
                if have >= file.size { break }
                if startBytes == nil { startBytes = base + have }
                do {
                    try await fetch(Self.url(repo: model.repo, revision: pinned.revision, path: file.path), to: part, from: have) { bytes in
                        let done = base + bytes
                        let elapsed = Date().timeIntervalSince(started)
                        let rate = elapsed > 2 ? Double(done - (startBytes ?? 0)) / elapsed : 0
                        progress(Double(done) / Double(total), rate > 0 ? Double(total - done) / rate : nil)
                    }
                    // Response without new bytes (server silently aborts): counts as a failed attempt, else endless loop.
                    if Self.fileSize(part) <= have { throw PippaError.downloadFailed("Keine neuen Daten.") }
                } catch let failure as WriteFailure {
                    // Disk full or write error: retrying doesn't help, and it isn't the network either.
                    throw writeFailure(failure.underlying, remaining: file.size - max(0, Self.fileSize(part)))
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    attempts += 1
                    if attempts > 8 { DiagnosticsLog.shared.event("download-aufgegeben", ["versuche": String(attempts)]); throw PippaError.downloadFailed("Bitte Internetverbindung prüfen. Es geht dort weiter, wo es aufgehört hat.") }
                    try await Task.sleep(for: .seconds(Double(attempts) * 3))
                }
            }
            let size = Self.fileSize(part)
            guard size == file.size else {
                try? FileManager.default.removeItem(at: part) // our own, incomplete temp file
                DiagnosticsLog.shared.event("download-unvollstaendig"); throw PippaError.downloadFailed("Die Datei ist unvollständig.")
            }
            let hash: String
            do { hash = try Self.sha256(of: part) }
            catch { if error is CancellationError { throw error }; throw writeFailure(error, remaining: 0) }
            guard hash == file.sha256 else {
                try? FileManager.default.removeItem(at: part)
                DiagnosticsLog.shared.event("download-pruefsumme"); throw PippaError.checksumMismatch
            }
            do {
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.moveItem(at: part, to: dest)
                try file.sha256.write(to: dest.appendingPathExtension("ok"), atomically: true, encoding: .utf8)
            } catch { throw writeFailure(error, remaining: 0) }
            completed += file.size
            progress(Double(completed) / Double(total), nil)
        }
    }

    public static func sha256(of url: URL, onBytes: ((Int64) -> Void)? = nil) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        var read: Int64 = 0
        while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
            read += Int64(chunk.count)
            onBytes?(read)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func fetch(_ url: URL, to part: URL, from offset: Int64, onBytes: @escaping (Int64) -> Void) async throws {
        if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
        let fh: FileHandle
        do { fh = try FileHandle(forWritingTo: part) } catch { throw WriteFailure(underlying: error) }
        var request = URLRequest(url: url)
        request.setValue("Pippa/\(Pippa.version)", forHTTPHeaderField: "User-Agent")
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        request.timeoutInterval = 60
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        defer {
            try? fh.close()
            lock.withLock { handle = nil; onData = nil; activeTask = nil }
        }
        lock.withLock { handle = fh; received = offset; onData = onBytes; transferCancelled = false; writeError = nil; sinceSpaceCheck = 0 }
        _ = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
                lock.withLock {
                    if transferCancelled { cont.resume(throwing: CancellationError()); return }
                    continuation = cont
                    let task = session.dataTask(with: request)
                    activeTask = task
                    task.resume()
                }
            }
        } onCancel: {
            self.lock.withLock { self.transferCancelled = true; self.activeTask?.cancel() }
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        lock.lock()
        defer { lock.unlock() }
        do {
        if status == 200 {
            // Server ignores Range: start from the beginning.
            do { try handle?.truncate(atOffset: 0); try handle?.seek(toOffset: 0) } catch { throw WriteFailure(underlying: error) }
            received = 0
        } else if status == 206 {
            let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") ?? ""
            guard range.hasPrefix("bytes \(received)-") else { throw PippaError.downloadFailed("Der Download konnte nicht fortgesetzt werden.") }
            do { _ = try handle?.seekToEnd() } catch { throw WriteFailure(underlying: error) }
        } else {
            completionHandler(.cancel)
            continuation?.resume(throwing: PippaError.downloadFailed("Antwort \(status)")); continuation = nil
            return
        }
        completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            continuation?.resume(throwing: error); continuation = nil
        }
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        do { try handle?.write(contentsOf: data) }
        catch { writeError = WriteFailure(underlying: error); activeTask?.cancel(); lock.unlock(); return }
        received += Int64(data.count)
        sinceSpaceCheck += Int64(data.count)
        if sinceSpaceCheck >= 256 << 20 {
            sinceSpaceCheck = 0
            // Other programs may be filling the disk right now: better to stop beforehand than fill the Mac completely.
            if let free = Self.availableSpace(at: directory), free < Self.spaceFloor {
                writeError = WriteFailure(underlying: PippaError.notEnoughSpace(bytes: Self.spaceBuffer))
                activeTask?.cancel(); lock.unlock(); return
            }
        }
        let r = received, cb = onData
        lock.unlock()
        cb?(r)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let cont = continuation; continuation = nil
        let failure = writeError
        lock.unlock()
        if let failure { cont?.resume(throwing: failure) }
        else if let error { cont?.resume(throwing: error) } else { cont?.resume(returning: 0) }
    }
}
