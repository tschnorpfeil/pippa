import Foundation

/// "Räum meine Downloads auf", "sortier den
/// Schreibtisch", "tidy up my Documents" go, like calendar questions (CalendarIntent), not to Pi but to Pippa's
/// proven native flow: preview as a card, one run, one undo for the whole job (Executor + journal).
/// Decided in code, without a model: a tidy word plus a folder.
///
/// Folder: a shown folder wins; otherwise Downloads, Documents, Desktop → ~/Downloads, ~/Documents, ~/Desktop;
/// otherwise a path ("~/Documents/Rechnungen") or the exact name of an existing folder directly in the home folder,
/// Documents, Desktop or Downloads ("räum meinen Ordner Rechnungen auf"): only a unique match, never Library, system,
/// media-library or hidden folders and never packages (`FolderLookup`).
/// Deliberately narrow, everything else stays with Pi:
/// - questions ("Was liegt in Downloads?", "Wie räume ich … auf?", "Soll ich …?") and negations;
/// - single files and single steps ("verschieb die Rechnung.pdf in Dokumente", "benenn … um", "lösch …");
/// - things other than folders ("sortier die Tabelle nach Datum", "räum meinen Posteingang auf");
/// - two places or a target ("sortier die Downloads nach Dokumente"): that is moving between folders;
/// - no recognizable folder ("räum auf" with nothing shown), an unknown or ambiguous folder name, a path outside the home folder.
public struct TidyIntent: Sendable, Equatable {
    public enum Place: String, Sendable, CaseIterable { case downloads, documents, desktop }
    /// `found`: a folder the person named by its own name or path (`FolderLookup`).
    public enum Source: Sendable, Equatable { case shownFolder, named(Place), found }
    public var folder: URL
    public var source: Source
    public init(folder: URL, source: Source) { self.folder = folder; self.source = source }

    /// `shownFolder`: the folder the person is currently showing (exactly one), else `nil`. `home`: home folder.
    public static func parse(_ text: String, shownFolder: URL?, home: URL) -> TidyIntent? {
        let folded = fold(text)
        let words = wordsOf(folded)
        guard !words.isEmpty, words.count <= 30 else { return nil }
        guard isTidyRequest(words: words, folded: folded) else { return nil }
        if let first = words.first, questionStarts.contains(first) { return nil }
        if text.contains("?") && !words.contains(where: { requestStarts.contains($0) }) { return nil }
        if words.contains(where: { negations.contains($0) }) { return nil }
        if words.contains(where: isSingleStepWord) || words.contains(where: isOtherObject) { return nil }
        // "ordne die Rechnungen in Dokumente ein", "sortier das ein": filing individual things, not tidying a folder.
        if words.contains("ein") && !Set(words).isDisjoint(with: ["ordne", "ordnen", "sortier", "sortiere", "sortieren"]) { return nil }
        if mentionsFileName(text) { return nil }

        // A path names its folder exactly; an unusable one (outside home, Library, missing) goes to Pi.
        if let path = FolderLookup.pathMention(in: text) {
            if let shownFolder { return TidyIntent(folder: shownFolder, source: .shownFolder) }
            return FolderLookup.resolve(path: path, home: home).map { TidyIntent(folder: $0, source: .found) }
        }

        let places = Place.allCases.filter { place in words.contains { matches($0, place) } }
        guard places.count <= 1 else { return nil }
        // "… nach Dokumente", "into Documents": a target, not a folder to tidy.
        if let place = places.first, words.indices.contains(where: { i in i > 0 && matches(words[i], place) && destinationWords.contains(words[i - 1]) }) {
            return nil
        }
        if let shownFolder { return TidyIntent(folder: shownFolder, source: .shownFolder) }
        // A folder by its own name; with an everyday folder in the sentence only inside that one ("Rechnungen in Dokumente").
        let within = places.first.map { folder(for: $0, home: home) }
        if let found = FolderLookup.named(in: words, home: home, within: within) { return TidyIntent(folder: found, source: .found) }
        guard let place = places.first else { return nil }
        return TidyIntent(folder: folder(for: place, home: home), source: .named(place))
    }

    /// Lower case, no accents or umlauts, ß → ss, "ae" → "a" ("aufraeumen" like "aufräumen"). Shared with folder names.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
            .replacingOccurrences(of: "ß", with: "ss").replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "ae", with: "a", options: [], range: nil)
    }

    static func wordsOf(_ folded: String) -> [String] {
        folded.split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
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

/// Folders named by the person: "räum meinen Ordner Rechnungen auf", "tidy my Invoices folder", "~/Documents/Steuer".
/// Only existing, ordinary folders the person keeps things in: directly in the home folder, Documents, Desktop or Downloads.
/// Never Library, system or app folders, media libraries (Pictures, Music, Movies hold Photos/Music libraries), hidden
/// folders or packages. A name must match a folder name exactly (ignoring case and accents) and only one folder.
public enum FolderLookup {
    /// Direct children of the home folder that are never tidied by name.
    static let excludedInHome: Set<String> = ["library", "applications", "public", "pictures", "music", "movies",
                                              "applications (parallels)", "sites", "icloud drive (archive)"]
    /// Words that alone never name a folder (a folder called "Ordner" or "Auf" must not catch every request).
    static let fillerWords: Set<String> = ["ordner", "folder", "mein", "meine", "meinen", "meinem", "den", "die", "das", "der", "dem",
                                           "my", "the", "auf", "up", "bitte", "please", "mal", "hier", "im", "in", "von", "of"]

    /// Folders that can be meant by name, with their folded name words.
    static func candidates(home: URL) -> [(url: URL, words: [String])] {
        let fm = FileManager.default
        let roots = [home] + TidyIntent.Place.allCases.map { TidyIntent.folder(for: $0, home: home) }
        var out: [(URL, [String])] = []
        for root in roots {
            let isHome = root.standardizedFileURL == home.standardizedFileURL
            let children = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey],
                                                       options: [.skipsHiddenFiles])) ?? []
            for url in children where isOrdinaryFolder(url) {
                let name = url.lastPathComponent
                if isHome && (excludedInHome.contains(name.lowercased()) || TidyIntent.Place.allCases.contains { TidyIntent.folder(for: $0, home: home).lastPathComponent == name }) { continue }
                let words = TidyIntent.wordsOf(TidyIntent.fold(name))
                guard !words.isEmpty, !words.allSatisfy(fillerWords.contains) else { continue }
                out.append((url, words))
            }
        }
        return out
    }

    /// A real folder: not hidden, no package (.app, .photoslibrary), no link.
    static func isOrdinaryFolder(_ url: URL) -> Bool {
        guard !url.lastPathComponent.hasPrefix("."),
              let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]) else { return false }
        return v.isDirectory == true && v.isPackage != true && v.isSymbolicLink != true
    }

    /// The one folder whose full name appears in the request. Longer names win over names inside them
    /// ("Projekt Garten" over "Garten"); two different folders, or one name in two places, → `nil`.
    /// `within`: only folders directly in this one (an everyday folder named in the same sentence).
    public static func named(in words: [String], home: URL, within: URL? = nil) -> URL? {
        var hits: [(url: URL, range: Range<Int>)] = []
        for (url, name) in candidates(home: home) {
            if let within, url.deletingLastPathComponent().standardizedFileURL != within.standardizedFileURL { continue }
            guard name.count <= words.count else { continue }
            for start in 0...(words.count - name.count) where Array(words[start..<start + name.count]) == name {
                hits.append((url, start..<start + name.count))
            }
        }
        // Drop matches lying inside a longer match.
        let longest = hits.filter { hit in
            !hits.contains { other in other.range != hit.range && other.range.count > hit.range.count
                && other.range.lowerBound <= hit.range.lowerBound && other.range.upperBound >= hit.range.upperBound }
        }
        let folders = Set(longest.map { $0.url.standardizedFileURL })
        return folders.count == 1 ? folders.first : nil
    }

    /// A path in the request: "~/…" or "/…" (quoted paths may contain spaces).
    public static func pathMention(in text: String) -> String? {
        let patterns = [#"[\"“„'‚‘»«]((?:~|/)[^\"“”„'‚‘’»«\n]+)[\"”“'’‘»«]"#, #"(?:^|\s)((?:~/|/)[^\s,;!?]*)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range(at: 1), in: text) else { continue }
            var path = String(text[r])
            while path.count > 1, let last = path.last, ".:".contains(last) { path.removeLast() }
            if path.count > 1 { return path }
        }
        return nil
    }

    /// The folder for a path: inside the home folder, existing, ordinary, not in Library or a media library, not hidden.
    public static func resolve(path: String, home: URL) -> URL? {
        let expanded = path.hasPrefix("~") ? home.path + path.dropFirst() : path
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        let homeParts = home.standardizedFileURL.pathComponents
        let parts = url.pathComponents
        guard parts.count > homeParts.count, Array(parts.prefix(homeParts.count)) == homeParts else { return nil }
        let inside = parts.dropFirst(homeParts.count)
        if let top = inside.first, excludedInHome.contains(top.lowercased()) { return nil }
        if inside.contains(where: { $0.hasPrefix(".") }) { return nil }
        return isOrdinaryFolder(url) ? url : nil
    }
}
