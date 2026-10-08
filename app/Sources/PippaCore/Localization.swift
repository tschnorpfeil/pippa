import Foundation

// Translation of the UI (docs/development.md "Localization").
//
// The key is the English text itself; if it is missing from the table, it appears unchanged (English as fallback).
// PippaCore tables: "Core", "Analysis", "Skills" in Resources/{en,de}.lproj/<table>.strings.
// The Pippa module has `T(_:table:_:)` for this, with its own Bundle.module.
//
// Only for text a person sees. Document analysis (German patterns, keywords, date and
// amount formats in letters, CSV for German Excel) stays untranslated.
//
// Placeholders: %@ (text), %lld (Int), %d (Int32); with a different order in the translation %1$@ / %2$@.
// Without arguments nothing is formatted, so a "%" in the key stays literal.

/// Translates `key` from the PippaCore table `table` into the system language.
///
///     L("Nothing was changed.", table: "Core")
///     L("%lld files sorted", table: "Core", count)
public func L(_ key: String, table: String, _ args: CVarArg...) -> String {
    let format = Bundle.module.localizedString(forKey: key, value: key, table: table)
    if args.isEmpty { return format }
    return String(format: format, locale: Locale.current, arguments: args)
}

/// Like `L`, but in `language` („de“, „en“) when PippaCore has that translation. Text that code adds to a model answer
/// follows the language of the conversation, not the Mac's; `nil` is the language of the system.
public func L(_ key: String, table: String, language: String?, _ args: CVarArg...) -> String {
    let bundle = language.flatMap { Bundle.module.path(forResource: $0, ofType: "lproj") }.flatMap(Bundle.init(path:)) ?? Bundle.module
    let format = bundle.localizedString(forKey: key, value: key, table: table)
    if args.isEmpty { return format }
    return String(format: format, locale: language.map(Locale.init(identifier:)) ?? Locale.current, arguments: args)
}
