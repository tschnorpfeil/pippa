import Foundation

// Translation of the UI in the Pippa module (docs/development.md "Localization").
//
// Like `L(_:table:_:)` in PippaCore, but with the Bundle.module of this module.
// Tabellen: "App", "Views", "Settings" in Localization/{en,de}.lproj/<Tabelle>.strings.
// SwiftUI: `Text(T("Open", table: "Views"))` – a String, so no second lookup through LocalizedStringKey in Bundle.main.
// Generic type parameters are not named `T` here, otherwise they shadow this function.

/// Translates `key` from the Pippa table `table`; if missing, the English key appears.
func T(_ key: String, table: String, _ args: CVarArg...) -> String {
    let format = Bundle.module.localizedString(forKey: key, value: key, table: table)
    if args.isEmpty { return format }
    return String(format: format, locale: Locale.current, arguments: args)
}
