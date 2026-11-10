import Foundation

extension PiInstaller {
    // MARK: 2. Pi

    public func installPi() -> PiStepResult {
        do { return try exclusive(installPiExclusively) }
        catch { return finish(.pi, .failed(failure(error, path: roots.support))) }
    }

    private func installPiExclusively() -> PiStepResult {
        if state.layout == nil || state.pin != roots.pin { _ = detect() }
        guard let layout = state.layout else { return finish(.pi, .failed(.missingStep(.detect))) }
        begin(.pi)
        do {
            guard fm.fileExists(atPath: PiPayload.cliEntry(release: roots.payload.release).path),
                  fm.isExecutableFile(atPath: roots.payload.node.path) else { throw PiInstallFailure.payloadMissing(roots.payload.release.path) }
            let (release, reused) = try ensureRelease(root: roots.installRoot(layout))
            if layout == .official {
                try ensureOfficialLayout()
                advanceTerminalPi()
            }
            pruneReleases(root: roots.installRoot(layout))
            return finish(.pi, .piInstalled(layout: layout, release: release, reused: reused))
        } catch {
            return finish(.pi, .failed(failure(error, path: roots.installRoot(layout))))
        }
    }

    /// Create `releases/<pin>`: APFS clone of the payload to `staging/pippa-*`, check `--version` there, then rename
    /// (atomic). An existing release is only checked; it is replaced only if Pippa created it.
    func ensureRelease(root: URL) throws -> (URL, reused: Bool) {
        let pin = roots.pin
        let release = root.appendingPathComponent("releases/\(pin)", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        // Leftovers of an aborted run; Pi's own folders are named "update-*" and stay.
        for leftover in (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        where leftover.lastPathComponent.hasPrefix("pippa-") {
            try fm.removeItem(at: leftover)
        }
        if fm.fileExists(atPath: release.path) {
            if (try? version(release: release)) == pin { return (release, true) }
            guard state.didCreate(release) else { throw PiInstallFailure.releaseBroken(release.path) }
            try fm.removeItem(at: release) // Pippa's own, damaged release
        }
        try makeDirectory(staging)
        let temporary = staging.appendingPathComponent("pippa-\(pin)-\(UUID().uuidString)", isDirectory: true)
        try fm.copyItem(at: roots.payload.release, to: temporary) // APFS: clonefile, no extra space
        let found: String
        do { found = try version(release: temporary) } catch { try? fm.removeItem(at: temporary); throw error }
        guard found == pin else {
            try? fm.removeItem(at: temporary)
            throw PiInstallFailure.versionMismatch(found: found, expected: pin)
        }
        try makeDirectory(release.deletingLastPathComponent())
        try fm.moveItem(at: temporary, to: release)
        try markManagedRelease(release)
        state.record(release)
        save()
        return (release, false)
    }


    /// Removes releases that Pippa created itself and nobody needs anymore. Kept: the pin, the previous pin
    /// (running terminal sessions, going back) and whatever `current-version` names. Foreign releases (Pi's
    /// installer, `pi update`) always stay. A kept release Pippa recorded before the marker existed gains it here,
    /// so a later state rewrite cannot turn it into a permanent stranger.
    func pruneReleases(root: URL) {
        let releases = root.appendingPathComponent("releases", isDirectory: true)
        let active = (try? String(contentsOf: root.appendingPathComponent("current-version"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let keep = Set([roots.pin, state.previousPin, active].compactMap { $0 })
        var changed = false
        for entry in (try? fm.contentsOfDirectory(at: releases, includingPropertiesForKeys: nil)) ?? [] {
            if keep.contains(entry.lastPathComponent) {
                if state.didCreate(entry), !Self.hasManagedReleaseMarker(entry) { try? markManagedRelease(entry) }
                continue
            }
            guard isPippaRelease(entry) else { continue }
            guard (try? fm.removeItem(at: entry)) != nil else { continue }
            state.forget(entry)
            changed = true
        }
        if changed { save() }
    }

    /// Marker file Pippa writes into a release it installed itself. `install-state.json` records that release too,
    /// but a rewritten state or a layout change can lose the record; the marker inside the release survives it, so
    /// cleanup still knows the release is Pippa's and may be removed (#139).
    public static let managedReleaseMarker = ".pippa-installed.json"

    static func hasManagedReleaseMarker(_ release: URL) -> Bool {
        FileManager.default.fileExists(atPath: release.appendingPathComponent(managedReleaseMarker).path)
    }

    /// A release Pippa installed: recorded in the state, or carrying the marker that outlives a lost record.
    func isPippaRelease(_ release: URL) -> Bool {
        state.didCreate(release) || Self.hasManagedReleaseMarker(release)
    }

    /// Writes the marker into a release Pippa created. The folder name is the version, so the file states which
    /// release it belongs to even after it is moved out of the state.
    func markManagedRelease(_ release: URL) throws {
        let marker: [String: Any] = [
            "schemaVersion": 1,
            "installedBy": "Pippa",
            "version": release.lastPathComponent,
            "installedAt": Timestamp.iso8601(),
        ]
        let data = try JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: release.appendingPathComponent(Self.managedReleaseMarker), options: .atomic)
    }

    /// `a` < `b` for versions of the form x.y.z; anything else (prereleases, unreadable) does not count as older.
    static func isOlder(_ a: String, than b: String) -> Bool {
        let parse = { (s: String) -> [Int]? in
            let parts = s.split(separator: ".").map { Int($0) }
            return parts.count == 3 && parts.allSatisfy { $0 != nil } ? parts.map { $0! } : nil
        }
        guard let x = parse(a), let y = parse(b) else { return false }
        return x.lexicographicallyPrecedes(y)
    }

    /// `pi --version` of a release with Pippa's Node (like Pi's own check `verifyManagedRelease`: stdout, trimmed).
    func version(release: URL) throws -> String {
        let cli = PiPayload.cliEntry(release: release)
        guard fm.fileExists(atPath: cli.path) else { throw PiInstallFailure.versionMismatch(found: "", expected: roots.pin) }
        guard let result = Self.run(roots.payload.node, [cli.path, "--version"], environment: Self.baseEnvironment(roots)),
              result.status == 0 else { throw PiInstallFailure.versionMismatch(found: "", expected: roots.pin) }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
