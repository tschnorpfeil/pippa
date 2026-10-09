import Foundation
import PippaCore

// One-time migration from the old sandbox container. Everything runs in a fake
// HOME under the check folder, never against the real one.
func runLegacyMigrationChecks() {
    func fixture(_ name: String) -> (LegacyContainerMigration, URL) {
        let home = dir("legacy-\(name)")
        let migration = LegacyContainerMigration(home: home, destination: home.appendingPathComponent("Library/Application Support/Pippa"))
        try? fm.createDirectory(at: migration.source.appendingPathComponent("Conversations"), withIntermediateDirectories: true)
        write("{\"history\":1}", migration.source.appendingPathComponent("Conversations/history.json"))
        write("journal", migration.source.appendingPathComponent("journal.sqlite"))
        write("{}", migration.source.appendingPathComponent("settings.json"))
        try? fm.createDirectory(at: migration.source.appendingPathComponent("models"), withIntermediateDirectories: true)
        write("gguf", migration.source.appendingPathComponent("models/model.gguf"))
        try? fm.createDirectory(at: migration.legacyPreferences.deletingLastPathComponent(), withIntermediateDirectories: true)
        let prefs = try? PropertyListSerialization.data(fromPropertyList: ["onboarded": true, "hotkey": "alt-space", "pill.visible": false],
                                                        format: .binary, options: 0)
        try? prefs?.write(to: migration.legacyPreferences)
        return (migration, home)
    }
    func suite() -> (UserDefaults, String) {
        let name = "pippa-checks-legacy-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    check("Migration: no old container → nothing") {
        let home = dir("legacy-none")
        let migration = LegacyContainerMigration(home: home, destination: home.appendingPathComponent("Library/Application Support/Pippa"))
        return migration.access() == .absent && migration.evaluate() == .nothing
    }
    check("Migration: offered without models, copied, container unchanged, settings only added to") {
        let (migration, _) = fixture("offer")
        guard case .offer(let items) = migration.evaluate(), items == ["Conversations", "journal.sqlite", "settings.json"] else { return false }
        let (defaults, name) = suite()
        defer { dropDefaultsSuite(defaults, name) }
        defaults.set("cmd-space", forKey: "hotkey") // already set: stays
        let outcome = try migration.run(items: items, defaults: defaults, domain: name)
        let copied = try String(contentsOf: migration.destination.appendingPathComponent("Conversations/history.json"), encoding: .utf8)
        let leftovers = try fm.contentsOfDirectory(atPath: migration.destination.path).filter { $0.hasPrefix(".pippa-migration") }
        return outcome.copied == items && copied == "{\"history\":1}"
            && !fm.fileExists(atPath: migration.destination.appendingPathComponent("models").path)
            && fm.fileExists(atPath: migration.source.appendingPathComponent("Conversations/history.json").path)
            && fm.fileExists(atPath: migration.source.appendingPathComponent("models/model.gguf").path)
            && leftovers.isEmpty
            && outcome.importedDefaults == ["onboarded", "pill.visible"]
            && defaults.string(forKey: "hotkey") == "cmd-space" && defaults.bool(forKey: "onboarded")
    }
    check("Migration: copy is independent of the original (clone, not a link)") {
        let (migration, _) = fixture("independent")
        guard case .offer(let items) = migration.evaluate() else { return false }
        try migration.run(items: items, defaults: nil)
        write("changed", migration.destination.appendingPathComponent("settings.json"))
        return try String(contentsOf: migration.source.appendingPathComponent("settings.json"), encoding: .utf8) == "{}"
    }
    check("Migration: new folder in use → nothing, never merge") {
        let (migration, _) = fixture("busy")
        try fm.createDirectory(at: migration.destination.appendingPathComponent("Conversations"), withIntermediateDirectories: true)
        guard migration.evaluate() == .nothing else { return false }
        do { try migration.run(items: ["settings.json"], defaults: nil); return false }
        catch { return (error as? LegacyContainerMigration.Failure) == .notEmpty
                    && !fm.fileExists(atPath: migration.destination.appendingPathComponent("settings.json").path) }
    }
    check("Migration: installer items in the new folder do not count as \"in use\"") {
        let (migration, _) = fixture("installer")
        try fm.createDirectory(at: migration.destination.appendingPathComponent("models"), withIntermediateDirectories: true)
        write("{}", migration.destination.appendingPathComponent("install-state.json"))
        guard case .offer(let items) = migration.evaluate() else { return false }
        return try migration.run(items: items, defaults: nil).copied.count == 3
    }
    check("Migration: unreadable old folder → refused, without crashing") {
        let (migration, _) = fixture("denied")
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: migration.source.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: migration.source.path) }
        return migration.access() == .denied && migration.evaluate() == .denied
    }
    check("Migration: if copying fails, the new folder stays empty") {
        let (migration, _) = fixture("fail")
        do { try migration.run(items: ["settings.json", "missing.json"], defaults: nil); return false }
        catch { return (error as? LegacyContainerMigration.Failure) == .copy("missing.json") && migration.destinationIsEmpty }
    }
}
