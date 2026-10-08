import Foundation

/// "Räum meine Downloads auf", "sortier den
/// Schreibtisch", "tidy up my Documents" go, like calendar questions (CalendarIntent), not to Pi but to Pippa's
/// proven native flow: preview as a card, one run, one undo for the whole job (Executor + journal).
/// Decided in code, without a model: a tidy word plus a folder.
///
/// Folder: a shown folder wins; otherwise Downloads, Documents, Desktop → ~/Downloads, ~/Documents, ~/Desktop.
/// Deliberately narrow, everything else stays with Pi:
/// - questions ("Was liegt in Downloads?", "Wie räume ich … auf?", "Soll ich …?") and negations;
/// - single files and single steps ("verschieb die Rechnung.pdf in Dokumente", "benenn … um", "lösch …");
/// - things other than folders ("sortier die Tabelle nach Datum", "räum meinen Posteingang auf");
/// - two places or a target ("sortier die Downloads nach Dokumente"): that is moving between folders;
/// - no recognizable folder ("räum auf" with nothing shown).
public struct TidyIntent: Sendable, Equatable {
    public enum Place: String, Sendable, CaseIterable { case downloads, documents, desktop }
    public enum Source: Sendable, Equatable { case shownFolder, named(Place) }
    public var folder: URL
    public var source: Source
    public init(folder: URL, source: Source) { self.folder = folder; self.source = source }

    /// `shownFolder`: the folder the person is currently showing (exactly one), else `nil`. `home`: home folder.
    public static func parse(_ text: String, shownFolder: URL?, home: URL) -> TidyIntent? {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
            .replacingOccurrences(of: "ß", with: "ss").replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "ae", with: "a", options: [], range: nil)   // "aufraeumen" like "aufräumen"
        let words = folded.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
        guard !words.isEmpty, words.count <= 30 else { return nil }
        guard isTidyRequest(words: words, folded: folded) else { return nil }
        if let first = words.first, questionStarts.contains(first) { return nil }
        if text.contains("?") && !words.contains(where: { requestStarts.contains($0) }) { return nil }
        if words.contains(where: { negations.contains($0) }) { return nil }
        if words.contains(where: isSingleStepWord) || words.contains(where: isOtherObject) { return nil }
        // "ordne die Rechnungen in Dokumente ein", "sortier das ein": filing individual things, not tidying a folder.
        if words.contains("ein") && !Set(words).isDisjoint(with: ["ordne", "ordnen", "sortier", "sortiere", "sortieren"]) { return nil }
        if mentionsFileName(text) { return nil }

        let places = Place.allCases.filter { place in words.contains { matches($0, place) } }
        guard places.count <= 1 else { return nil }
        // "… nach Dokumente", "into Documents": a target, not a folder to tidy.
        if let place = places.first, words.indices.contains(where: { i in i > 0 && matches(words[i], place) && destinationWords.contains(words[i - 1]) }) {
            return nil
        }
        if let shownFolder { return TidyIntent(folder: shownFolder, source: .shownFolder) }
        guard let place = places.first else { return nil }
        return TidyIntent(folder: folder(for: place, home: home), source: .named(place))
    }

    public static func folder(for place: Place, home: URL) -> URL {
        switch place {
        case .downloads: home.appendingPathComponent("Downloads", isDirectory: true)
        case .documents: home.appendingPathComponent("Documents", isDirectory: true)
        case .desktop: home.appendingPathComponent("Desktop", isDirectory: true)
        }
    }

    // MARK: Words (folded: lower case, no umlauts, ß → ss)

    static func isTidyRequest(words: [String], folded: String) -> Bool {
        let set = Set(words)
        // "räum … auf" needs the "auf"; "aufräumen", "sortier(e/en)", "ordne(n)" stand alone.
        let clear = !set.isDisjoint(with: ["raum", "raume", "raumst", "raumt"]) && set.contains("auf")
        let infinitive = words.contains { $0 == "aufraumen" || $0 == "aufzuraumen" }
        let sort = !set.isDisjoint(with: ["sortier", "sortiere", "sortieren", "ordne", "ordnen"])
        let order = folded.contains("ordnung") && !set.isDisjoint(with: ["mach", "mache", "machen", "schaff", "schaffe", "schaffen", "bring", "bringe", "bringen", "rein", "in"])
        let english = !set.isDisjoint(with: ["tidy", "sort", "organize", "organise", "declutter", "cleanup"])
            || folded.contains("clean up") || folded.contains("clear up")
        return clear || infinitive || sort || order || english
    }

    /// Questions and requests for information: Pi answers (reads, explains), nothing is planned.
    static let questionStarts: Set<String> = [
        "was", "wie", "warum", "wieso", "weshalb", "wann", "wo", "welche", "welcher", "welches", "wer", "wieviel", "wieviele",
        "soll", "sollte", "sollen", "muss", "musste", "ist", "sind", "hast", "hat", "habe", "gibt", "lohnt",
        "what", "how", "why", "when", "where", "which", "who", "should", "is", "are", "does", "do", "did", "have", "has", "were",
    ]
    /// Polite requests with a question mark are still tasks ("Kannst du meine Downloads aufräumen?").
    static let requestStarts: Set<String> = ["kannst", "konntest", "wurdest", "magst", "bitte", "can", "could", "would", "will", "please"]
    static let negations: Set<String> = ["nicht", "nichts", "kein", "keine", "keinen", "nie", "niemals", "not", "don't", "dont", "never", "no"]
    static let destinationWords: Set<String> = ["nach", "ins", "into", "to", "zu", "zum", "zur"]

    /// A single step on one file stays with Pi (rename, move with undo per line).
    static func isSingleStepWord(_ word: String) -> Bool {
        let prefixes = ["verschieb", "umbenenn", "benenn", "losch", "wegwerf", "papierkorb", "kopier", "einordn", "einsortier",
                        "rename", "delete", "trash", "copy", "remove"]
        if prefixes.contains(where: word.hasPrefix) { return true }
        return ["datei", "file", "move"].contains(word)
    }

    /// Things that are not folders: "sortier die Tabelle", "räum den Text auf", "räum meinen Posteingang auf".
    static func isOtherObject(_ word: String) -> Bool {
        let exact: Set<String> = ["tabelle", "tabellen", "liste", "listen", "spalte", "spalten", "zeile", "zeilen", "text", "texte", "satz", "satze",
                                  "absatz", "absatze", "mail", "mails", "email", "emails", "posteingang", "postfach", "kalender", "termine", "termin",
                                  "brief", "briefe", "code", "notizen", "gedanken", "zimmer", "wohnung", "kuche", "keller",
                                  "table", "tables", "list", "lists", "column", "columns", "row", "rows", "sentence", "sentences", "paragraph",
                                  "inbox", "calendar", "notes", "thoughts", "room", "kitchen", "spreadsheet", "sheet", "cells"]
        return exact.contains(word)
    }

    /// "Rechnung.pdf", "scan_3.jpg": a specific file.
    static func mentionsFileName(_ text: String) -> Bool {
        text.range(of: #"[\p{L}\p{N}_\-)]\.[A-Za-z][A-Za-z0-9]{1,4}\b"#, options: .regularExpression) != nil
    }

    static func matches(_ word: String, _ place: Place) -> Bool {
        switch place {
        case .downloads: word.hasPrefix("download")
        case .documents: word.hasPrefix("dokumente") || word == "documents" || word.hasPrefix("documentsordner")
        case .desktop: word.hasPrefix("schreibtisch") || word == "desktop" || word.hasPrefix("desktopordner")
        }
    }
}
