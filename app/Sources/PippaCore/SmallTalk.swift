import Foundation

/// Pure small talk ("Hey Pippa, wie geht's?", "Danke!", "Gute Nacht"): Pippa's Qwen models answer it without thinking.
/// With the catalog's "medium" Qwen thought first and showed "Überlege …" for a greeting (about 11 s, Qwen 3.5 9B).
/// Every word must come from the list below, so anything with a task in it ("Danke, mach weiter", "Wie geht das?")
/// keeps thinking. Not on the list: "ok", "ja", "nein", "gerne", which often answer Pippa's own question and start an action.
public enum SmallTalk {
    static let words: Set<String> = [
        // German
        "hey", "hi", "hallo", "huhu", "moin", "servus", "na", "pippa", "guten", "gute", "morgen", "tag", "abend", "nacht",
        "wie", "gehts", "geht", "es", "s", "dir", "du", "und", "bei", "wer", "bist", "danke", "dankeschön", "vielen", "dank",
        "lieben", "super", "prima", "toll", "klasse", "cool", "schön", "gut", "mir", "auch", "tschüss", "tschüs", "ciao",
        "bis", "später", "bald", "dann", "liebe", "grüße",
        // English
        "hello", "good", "morning", "afternoon", "evening", "night", "how", "are", "you", "doing", "what", "up", "who",
        "thanks", "thank", "much", "so", "great", "nice", "fine", "too", "and", "bye", "see", "later", "soon", "cheers",
    ]

    public static func matches(_ message: String) -> Bool {
        let tokens = message.lowercased().split { !$0.isLetter }.map(String.init)
        return !tokens.isEmpty && tokens.count <= 8 && tokens.allSatisfy(words.contains)
    }

    /// The thinking level for this turn when it differs from the session's: "off" for small talk on a Qwen model
    /// (`enable_thinking`). K2 stays as it is: "off" maps to "high" there, and its "medium" is already the fast think.
    public static func turnThinkingLevel(message: String, modelKey: String?, current: String?) -> String? {
        guard let modelKey, PiReasoningStyle.of(modelKey: modelKey) == .enableThinking, let current, current != "off",
              matches(message) else { return nil }
        return "off"
    }
}
