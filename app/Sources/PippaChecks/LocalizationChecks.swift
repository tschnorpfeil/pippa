import Foundation
import PippaCore

/// Localization: missing keys fall back to the English text, placeholders are filled,
/// and the PippaCore resource bundle carries en.lproj and de.lproj with all tables.
func runLocalizationChecks() {
    check("Localization: a missing key yields the key itself") {
        let key = "Pippa check: this key is never translated"
        return L(key, table: "Core") == key && L(key, table: "NoSuchTable") == key
    }
    check("Localization: placeholders filled in the fallback") {
        let count = 3
        let text = L("Pippa check: %lld items in %@", table: "Core", count, "Inbox")
        return text == "Pippa check: 3 items in Inbox"
    }
    check("Localization: PippaCore bundle has en.lproj and de.lproj with all tables") {
        // `swift run` puts Pippa_PippaCore.bundle next to the executable; in the app it lives in Contents/Resources.
        let places = [Bundle.main.bundleURL, Bundle.main.resourceURL].compactMap { $0 }
        let candidates = places.compactMap { Bundle(url: $0.appendingPathComponent("Pippa_PippaCore.bundle")) }
        guard let bundle = candidates.first else {
            print("  Pippa_PippaCore.bundle not found in \(places.map(\.path))")
            return false
        }
        let tables = ["Core", "Analysis", "Skills"]
        var missing: [String] = []
        for language in ["en", "de"] {
            for table in tables where bundle.url(forResource: table, withExtension: "strings", subdirectory: nil, localization: language) == nil {
                missing.append("\(language).lproj/\(table).strings")
            }
        }
        if !missing.isEmpty { print("  missing: \(missing.joined(separator: ", "))") }
        return missing.isEmpty
    }
    check("Localization: the German Core table delivers the German texts, numbers with a German comma") {
        // Independent of the system language: read de.lproj directly from the bundle.
        let places = [Bundle.main.bundleURL, Bundle.main.resourceURL].compactMap { $0 }
        guard let core = places.compactMap({ Bundle(url: $0.appendingPathComponent("Pippa_PippaCore.bundle")) }).first,
              let path = core.path(forResource: "de", ofType: "lproj"), let german = Bundle(path: path) else {
            print("  de.lproj of PippaCore not found")
            return false
        }
        let locale = Locale(identifier: "de_DE")
        func de(_ key: String) -> String { german.localizedString(forKey: key, value: "?", table: "Core") }
        let tidied = String(format: de("%lld files tidied"), locale: locale, 3)
        let size = String(format: de("%.1f GB"), locale: locale, 16.845511648)
        let minutes = String(format: de("about %lld minutes"), locale: locale, 10)
        let failed = String(format: de("Stopped partway through: %@ %@, and that can be undone."), locale: locale, "Kein Platz mehr frei.", "3 Dateien geordnet")
        return de("1 file tidied") == "1 Datei geordnet" && tidied == "3 Dateien geordnet" && size == "16,8 GB"
            && minutes == "etwa 10 Minuten" && de("Answer stopped.") == "Antwort angehalten."
            && failed == "Mittendrin abgebrochen: Kein Platz mehr frei. 3 Dateien geordnet, das lässt sich rückgängig machen."
    }
}
