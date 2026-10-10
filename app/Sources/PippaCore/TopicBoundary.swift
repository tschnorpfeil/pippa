import Foundation

/// When a message starts a new topic inside the open conversation, so the earlier part can step back in the window and
/// Pi can start a fresh, small session (with a short handover from the old one, runtime/pippa-tools/pippa-context.ts).
///
/// Fixed rules, no model call: a classifier would hold up every answer on the local model. Rather too seldom than too
/// often: a message that refers back ("und das Foto?", "Danke", "noch kürzer") never starts a topic.
/// - a greeting after a short pause ("Hey Pippa, was geht ab?"),
/// - any message of at least three words after a long pause.
/// New things handed over and three hours of quiet already start a whole new conversation (AppModel, ConversationReopenPolicy).
public enum TopicBoundary {
    public static let greetingAfter: TimeInterval = 2 * 60
    public static let quietAfter: TimeInterval = 30 * 60

    /// `messages`: the conversation so far, without `text`. Only once the current topic has a question and an answer.
    public static func startsNewTopic(_ text: String, messages: [ConversationMessage], now: Date) -> Bool {
        let topic = currentTopic(messages)
        guard topic.contains(where: { $0.role == .user }), topic.contains(where: { $0.role == .assistant }),
              let last = topic.last(where: { $0.role != .system })?.timestamp else { return false }
        let quiet = now.timeIntervalSince(last)
        let all = words(text)
        guard !all.isEmpty else { return false }
        let greeting = greetingLength(all)
        var rest = Array(all.dropFirst(greeting))
        if rest.first == "pippa" { rest.removeFirst() }
        if refersBack(rest) { return false }
        if greeting > 0 { return quiet >= greetingAfter }
        return quiet >= quietAfter && all.count >= 3
    }

    /// Messages since the last topic start; the whole conversation if it has none.
    public static func currentTopic(_ messages: [ConversationMessage]) -> ArraySlice<ConversationMessage> {
        guard let start = messages.lastIndex(where: { $0.topicStart == true }) else { return messages[...] }
        return messages[start...]
    }

    /// Index of the message that starts the latest topic, if the conversation has one.
    public static func latestStart(_ messages: [ConversationMessage]) -> Int? {
        messages.lastIndex { $0.topicStart == true }
    }

    // MARK: Words

    static func words(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
            .replacingOccurrences(of: "ß", with: "ss").replacingOccurrences(of: "’", with: "'")
        return folded.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
    }

    static let greetings: Set<String> = ["hey", "hi", "hallo", "hello", "moin", "servus", "huhu", "hej", "gruss", "gruezi", "tach", "yo"]
    static let dayGreetings: Set<String> = ["guten", "good", "schonen"]
    static let times: Set<String> = ["morgen", "tag", "abend", "morning", "afternoon", "evening", "nachmittag"]

    /// How many leading words are a greeting: "hey" 1, "guten morgen" 2, none 0.
    static func greetingLength(_ words: [String]) -> Int {
        guard let first = words.first else { return 0 }
        if greetings.contains(first) { return 1 }
        if dayGreetings.contains(first), words.count > 1, times.contains(words[1]) { return 2 }
        return 0
    }

    /// Opening words that continue or answer what came before.
    static let continuing: Set<String> = [
        "und", "aber", "oder", "noch", "auch", "dann", "dazu", "das", "dies", "diese", "dieser", "dieses", "es",
        "danke", "dankeschon", "super", "toll", "cool", "ok", "okay", "ja", "nein", "genau", "gut", "prima", "perfekt", "stimmt",
        "and", "but", "or", "also", "then", "that", "this", "these", "those", "it", "thanks", "thank", "great", "yes", "no", "nice",
    ]
    /// Words anywhere that point back to something already said.
    static let pointing: Set<String> = [
        "vorhin", "eben", "oben", "davon", "darin", "damit", "daraus", "daruber", "dafur", "dazu", "nochmal", "weiter", "stattdessen",
        "genauer", "kurzer", "langer", "ausfuhrlicher", "einfacher", "erste", "ersten", "zweite", "letzte", "letzten",
        "earlier", "above", "again", "instead", "shorter", "longer", "simpler", "previous", "first", "second", "last",
    ]

    static func refersBack(_ words: [String]) -> Bool {
        guard let first = words.first else { return false }
        if continuing.contains(first) { return true }
        if words.contains(where: { pointing.contains($0) }) { return true }
        // "noch mal", "what about", "wie war das"
        let text = words.joined(separator: " ")
        return text.contains("noch mal") || text.hasPrefix("what about") || text.hasPrefix("how about")
    }
}
