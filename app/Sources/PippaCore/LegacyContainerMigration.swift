import Darwin
import Foundation

/// Since the pivot Pippa runs without App Sandbox. `Pippa.supportDirectory` is thus
/// the real folder `~/Library/Application Support/Pippa`, no longer the one in the container. On first start Pippa offers
/// once to take over conversations, settings and history from the old container.
///
/// - Only if the new folder is empty (or contains only installer items). Never merge, never overwrite.
/// - Copies via APFS clone (`clonefile`), otherwise by copy. First everything into its own staging folder, then rename:
///   if copying fails, the new folder stays as it was.
/// - The container is never changed or deleted.
/// - Models are taken over by the installer (`PiInstallRoots.containerModels`, SHA check), not duplicated here.
/// - UserDefaults of the old app (container `Preferences`) are added only for keys that don't exist yet.
public struct LegacyContainerMigration: Sendable {
    public static let bundleID = "io.github.tschnorpfeil.pippa"
    /// Flag in UserDefaults: decided once, never asked again.
    public static let markerKey = "migration.legacyContainer"

    /// Belongs to the installer or is ballast: neither copied nor counts as "new folder not empty".
    public static let skipped: Set<String> = ["models", "pi", "install-state.json", "llama-key", ".DS_Store"]

    public let home: URL
    public let destination: URL

    public init(home: URL, destination: URL) {
        self.home = home
        self.destination = destination
    }

    public var containerData: URL {
        home.appendingPathComponent("Library/Containers/\(Self.bundleID)/Data", isDirectory: true)
    }
    public var source: URL { containerData.appendingPathComponent("Library/Application Support/Pippa", isDirectory: true) }
    public var legacyPreferences: URL { containerData.appendingPathComponent("Library/Preferences/\(Self.bundleID).plist") }

    public enum Access: String, Sendable { case absent, accessible, denied }

    /// Metadata only: `lstat` and `opendir`, without reading a name or a file. macOS 14+ protects foreign
    /// app containers; if macOS denies access, that means `.denied`.
    public func access() -> Access {
        var info = stat()
        if lstat(source.path, &info) != 0 { return errno == ENOENT || errno == ENOTDIR ? .absent : .denied }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return .absent }
        guard let dir = opendir(source.path) else { return .denied }
        closedir(dir)
        return .accessible
    }

    public enum Decision: Equatable, Sendable {
        /// Nothing to do (no old container, old folder empty, new folder already in use).
        case nothing
        /// macOS doesn't let Pippa read the old folder.
        case denied
        /// These entries (names in the old folder) would be taken over.
        case offer([String])
    }

    public func evaluate() -> Decision {
        switch access() {
        case .absent: return .nothing
        case .denied: return .denied
        case .accessible: break
        }
        guard destinationIsEmpty else { return .nothing }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: source.path) else { return .denied }
        let items = names.filter { !Self.skipped.contains($0) }.sorted()
        return items.isEmpty ? .nothing : .offer(items)
    }

    /// Missing or contains only what the installer creates.
    public var destinationIsEmpty: Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: destination.path) else {
            return !FileManager.default.fileExists(atPath: destination.path)
        }
        return names.allSatisfy { Self.skipped.contains($0) }
    }

    public struct Outcome: Equatable, Sendable {
        public var copied: [String]
        public var importedDefaults: [String]
        public var cloned: Bool
    }

    public enum Failure: Error, Equatable { case notEmpty, unreadable, copy(String) }

    /// Takes over `items` (from `evaluate()`) and, with `defaults`, the old settings.
    @discardableResult
    public func run(items: [String], defaults: UserDefaults?, domain: String = bundleID) throws -> Outcome {
        let fm = FileManager.default
        guard destinationIsEmpty else { throw Failure.notEmpty }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let staging = destination.appendingPathComponent(".pippa-migration-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) } // only Pippa's own staging folder
        var allCloned = true
        for name in items {
            guard !name.contains("/"), !Self.skipped.contains(name) else { continue }
            let from = source.appendingPathComponent(name), to = staging.appendingPathComponent(name)
            if clonefile(from.path, to.path, UInt32(CLONE_NOFOLLOW)) != 0 {
                allCloned = false
                do { try fm.copyItem(at: from, to: to) } catch { throw Failure.copy(name) }
            }
        }
        var copied: [String] = []
        for name in items where fm.fileExists(atPath: staging.appendingPathComponent(name).path) {
            let target = destination.appendingPathComponent(name)
            guard !fm.fileExists(atPath: target.path) else { continue }
            try fm.moveItem(at: staging.appendingPathComponent(name), to: target)
            copied.append(name)
        }
        let imported = defaults.map { importDefaults(into: $0, domain: domain) } ?? []
        return Outcome(copied: copied, importedDefaults: imported, cloned: allCloned)
    }

    /// Old settings (shortcut, pill, "already greeted" …) only for keys that don't exist here yet.
    /// `domain`: the own domain (bundle ID; in checks the suite name), so global values don't count as "already there".
    public func importDefaults(into defaults: UserDefaults, domain: String = bundleID) -> [String] {
        guard let data = try? Data(contentsOf: legacyPreferences),
              let old = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return [] }
        let existing = defaults.persistentDomain(forName: domain) ?? [:]
        var imported: [String] = []
        for (key, value) in old.sorted(by: { $0.key < $1.key }) where key != Self.markerKey && existing[key] == nil {
            defaults.set(value, forKey: key)
            imported.append(key)
        }
        return imported
    }
}
