import Foundation

/// The first minutes: while Pippa's own AI is still being set up or loaded (setup gate `.wait`), a plain question gets a
/// short answer from the system model (Apple Intelligence, on this Mac, `AppleQuickModel`). Everything Pippa needs her
/// tools for (files, Mail, Calendar, the web, changing something) waits for Pi and goes there as soon as it is ready,
/// together with what was answered in between, so the person never has to ask twice.
///
/// Decisions stand here without UI, so PippaChecks can check them; the app's side is `StartupBridgeChat`.
public enum StartupBridge {
    public enum Route: Equatable, Sendable {
        /// Short answer from the system model now.
        case quick
        /// Wait for Pi (shown in the conversation as "I’m almost ready").
        case waitForPi
    }

    /// One quick exchange Pi has not seen yet.
    public struct Turn: Equatable, Sendable {
        public var person: String
        public var pippa: String
        public init(person: String, pippa: String) { self.person = person; self.pippa = pippa }
    }

    /// The system model has 4,096 tokens for instructions, history, question and answer together.
    public static let selectionLimit = 1500
    public static let questionLimit = 1500
    static let historyLimit = 2000
    static let handoverLimit = 1800
    public static let maximumTokens = 500
    /// What the system model answers when the message needs Pippa's full AI.
    public static let waitToken = "[[WAIT]]"

    /// `systemModel`: Apple Intelligence is on and ready on this Mac.
    public static func route(_ text: String, hasFiles: Bool, selectedText: String, skill: Bool, systemModel: Bool) -> Route {
        guard systemModel, !hasFiles, !skill, selectedText.count <= selectionLimit, text.count <= questionLimit,
              !needsTools(text) else { return .waitForPi }
        return .quick
    }

    /// Word beginnings that point to Pippa's tools. Deliberately broad: a false hit only means waiting for the full
    /// answer; a miss means the small model has to notice itself (`waitToken`).
    static let toolStems = [
        // de
        "datei", "ordner", "download", "dokument", "pdf", "rechnung", "postfach", "kalender", "termin", "erinner",
        "such", "find", "öffne", "lösch", "verschieb", "aufräum", "sortier", "umbenenn", "speicher", "internet",
        "online", "webseite", "website", "google", "wetter", "nachricht", "foto", "bild", "screenshot", "bildschirm",
        "excel", "tabelle", "anhang", "festplatte", "schreibtisch", "vertrag", "kündig", "frist", "scan",
        // en
        "file", "folder", "document", "invoice", "inbox", "calendar", "appointment", "meeting", "remind", "search",
        "delete", "rename", "weather", "news", "photo", "picture", "image",
        "spreadsheet", "attach", "desktop", "contract", "deadline",
    ]
    /// Whole words only (as stems they would catch e.g. "briefly", "movie", "opening").
    static let toolWords: Set<String> = ["brief", "briefe", "briefen", "mail", "mails", "email", "emails", "web", "letter", "letters",
                                         "open", "move", "save", "sort", "tidy"]

    public static func needsTools(_ text: String) -> Bool {
        let lower = text.lowercased()
        let words = lower.split { !$0.isLetter }.map(String.init)
        return lower.contains("e-mail") || words.contains { word in toolWords.contains(word) || toolStems.contains { word.hasPrefix($0) } }
    }

    /// The system model's instructions: Pippa's voice, short, honest about what she cannot do yet.
    public static func instructions(language: String, today: Date) -> String {
        let german = language.hasPrefix("de")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: german ? "de_DE" : "en_US")
        formatter.dateFormat = german ? "EEEE, d. MMMM yyyy" : "EEEE, MMMM d, yyyy"
        let date = formatter.string(from: today)
        if german {
            return """
            Du bist Pippa, eine freundliche Helferin auf dem Mac. Pippa lädt gerade noch ihre volle KI; bis dahin \
            beantwortest du einfache Fragen kurz. Antworte auf Deutsch, in einfachen Worten, ohne Fachbegriffe, in \
            höchstens fünf Sätzen. Duze die Person. Heute ist \(date).
            Du kannst keine Dateien, Mails, Kalender, Erinnerungen oder Webseiten öffnen und auf dem Mac nichts ändern. \
            Wenn die Nachricht so etwas braucht, aktuelle Informationen aus dem Internet braucht oder du dir bei einer \
            Tatsache nicht sicher bist, antworte nur mit \(waitToken) und sonst nichts.
            """
        }
        return """
        You are Pippa, a friendly helper on the Mac. Pippa is still loading her full AI; until then you answer simple \
        questions briefly. Answer in English, in plain words, without jargon, in at most five sentences. Today is \(date).
        You cannot open files, mail, calendars, reminders or websites, and you cannot change anything on the Mac. If the \
        message needs any of that, needs current information from the internet, or you are not sure about a fact, answer \
        only with \(waitToken) and nothing else.
        """
    }

    /// The message for the system model, with the quick exchanges of this conversation so far (newest kept).
    public static func prompt(_ text: String, selectedText: String, history: [Turn], language: String) -> String {
        let german = language.hasPrefix("de")
        var parts: [String] = []
        let earlier = transcript(history, language: language, limit: historyLimit)
        if !earlier.isEmpty { parts.append((german ? "Bisher im Gespräch:\n" : "Earlier in this conversation:\n") + earlier) }
        let selected = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty { parts.append((german ? "Markierter Text:\n" : "Selected text:\n") + selected) }
        parts.append(text)
        return parts.joined(separator: "\n\n")
    }

    /// The message for Pi once it is ready: what was answered in between, then the new message.
    public static func handover(_ text: String, history: [Turn], language: String) -> String {
        let earlier = transcript(history, language: language, limit: handoverLimit)
        guard !earlier.isEmpty else { return text }
        let lead = language.hasPrefix("de")
            ? "Zur Einordnung: Während du noch geladen hast, hat Pippa mit einer kleinen Hilfe auf diesem Mac schon so geantwortet:"
            : "For context: while you were still loading, Pippa already answered with a small helper on this Mac:"
        let now = language.hasPrefix("de") ? "Die neue Nachricht:" : "The new message:"
        return lead + "\n\n" + earlier + "\n\n" + now + "\n" + text
    }

    static func transcript(_ history: [Turn], language: String, limit: Int) -> String {
        var lines: [String] = []
        var used = 0
        for turn in history.reversed() {
            let block = "Person: \(turn.person)\nPippa: \(turn.pippa)"
            guard used + block.count <= limit else { break }
            lines.insert(block, at: 0)
            used += block.count + 2
        }
        return lines.joined(separator: "\n\n")
    }

    public enum Opening: Equatable, Sendable {
        /// Too short to tell yet: keep it back.
        case undecided
        /// The system model handed over: wait for Pi.
        case deferred
        /// A real answer: show it.
        case answer
    }

    /// The start of the system model's answer (streamed): handed over, a real answer, or not decidable yet.
    public static func opening(_ text: String) -> Opening {
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.isEmpty { return .undecided }
        // Only the exact token: a real answer may well begin with "Wait …".
        if head.hasPrefix(waitToken) { return .deferred }
        if waitToken.hasPrefix(head) { return .undecided }
        return .answer
    }

    /// The finished answer without a stray hand-over token; `nil` if nothing is left.
    public static func cleaned(_ text: String) -> String? {
        let clean = text.replacingOccurrences(of: waitToken, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
