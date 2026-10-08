import Foundation

/// Shared helpers for Pippa's web lookups (`WebAccessGate`). The former "Check online" host that ran a fixed model flow
/// is gone: that check is a Pi conversation with skill `online-pruefen` now, behind the same web card.
public enum LookupHost {
    /// "de" or "en", by the language Pippa is currently speaking.
    public static var uiLanguage: String {
        let preferred = Bundle.module.preferredLocalizations.first ?? "en"
        return preferred.hasPrefix("de") ? "de" : "en"
    }

    /// At most `limit` UTF-16 units (that is how the core counts in JavaScript), shortened to whole characters.
    static func bounded(_ text: String, utf16 limit: Int) -> String {
        var result = text
        while result.utf16.count > limit { result.removeLast() }
        return result
    }
}
