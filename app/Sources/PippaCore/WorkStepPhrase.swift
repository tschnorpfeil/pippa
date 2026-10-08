import Foundation

// Everyday words for what Pi's tools are doing ("Suche .md-Dateien in deinem Benutzerordner").
//
// Pure functions: (tool name, arguments JSON, home folder) in, a short phrase out. The phrase is built only from
// what is recognized (tool, kind of search, a search word, the last folder or file name). Raw paths, flags,
// pipes and commands are never shown; a command that is not recognized becomes "Working on your Mac".

/// One step of the tool loop as the person sees it.
public struct WorkStep: Codable, Sendable, Equatable {
    public var text: String
    /// What came of it, when cheaply known ("3 matches", "nothing found").
    public var outcome: String?
    public init(text: String, outcome: String? = nil) { self.text = text; self.outcome = outcome }

    /// "Lese Brief.docx · nichts gefunden", for VoiceOver and receipts.
    public var line: String { outcome.map { text + " · " + $0 } ?? text }
}

public enum WorkStepPhrase {
    /// The phrase for a tool that just started; `nil` for bookkeeping tools that should not show up.
    /// `cwd` resolves relative paths (`nil`: they are shown by their last name or as "on your Mac").
    public static func phrase(tool: String, arguments: String, home: String, cwd: String? = nil, language: String? = nil) -> String? {
        Describer(home: home, cwd: cwd, language: language).describe(tool: tool, arguments: arguments)?.text
    }

    /// A short result for a finished tool, when it is cheap and safe to know. Never text of the result itself.
    public static func outcome(tool: String, arguments: String, isError: Bool, result: String, home: String, cwd: String? = nil,
                               language: String? = nil, resultWasCut: Bool = false) -> String? {
        let d = Describer(home: home, cwd: cwd, language: language)
        guard let described = d.describe(tool: tool, arguments: arguments) else { return nil }
        let lowered = result.lowercased()
        let missing = lowered.contains("enoent") || lowered.contains("no such file") || lowered.contains("not found")
        let denied = lowered.contains("permission denied") || lowered.contains("not permitted") || lowered.contains("eacces")
        switch described.result {
        case .file:
            guard isError else { return nil }
            if missing { return d.l("file not found") }
            if denied { return d.l("no access") }
            return d.l("didn’t work")
        case .matches, .entries:
            if isError, missing, tool == "ls" || described.result == .entries { return d.l("folder not found") }
            if isError, denied, d.countLines(result) == 0 { return d.l("no access") }
            if resultWasCut { return described.result == .matches ? d.l("many matches") : nil }
            let lowerHead = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
            if lowerHead.hasPrefix("no files found") || lowerHead.hasPrefix("no matches") { return d.l("nothing found") }
            let n = d.countLines(result)
            if described.result == .matches {
                return n == 0 ? d.l("nothing found") : n == 1 ? d.l("1 match") : d.l("%lld matches", n)
            }
            return n == 0 ? d.l("empty") : n == 1 ? d.l("1 item") : d.l("%lld items", n)
        case .none:
            return isError ? d.l("didn’t work") : nil
        }
    }

    /// Tools whose end is worth a short result (searches, listings, files); the host keeps their arguments until then.
    public static func hasOutcome(tool: String) -> Bool {
        let name = tool.lowercased()
        return ["bash", "find", "grep", "ls", "read", "edit", "write"].contains(name)
    }

    enum ResultKind { case none, file, matches, entries }
    struct Described { var text: String; var result: ResultKind }

    // MARK: - Describer

    struct Describer {
        var home: String
        var cwd: String?
        var language: String?

        func l(_ key: String, _ args: CVarArg...) -> String {
            let bundle = language.flatMap { Bundle.module.path(forResource: $0, ofType: "lproj") }.flatMap(Bundle.init(path:)) ?? Bundle.module
            let format = bundle.localizedString(forKey: key, value: key, table: "Thought")
            if args.isEmpty { return format }
            return String(format: format, locale: language.map(Locale.init(identifier:)) ?? Locale.current, arguments: args)
        }

        func describe(tool: String, arguments: String) -> Described? {
            var name = tool.lowercased()
            if name.hasPrefix("mcp__pippa__") { name.removeFirst("mcp__pippa__".count) }
            let args = Arguments(arguments)
            switch name {
            case "bash": return bash(args.string("command") ?? "")
            case "read":
                guard let path = args.string("path") ?? args.string("file_path") else { return Described(text: l("Reading a file"), result: .file) }
                return Described(text: fileTitle("Reading %@", "Reading a file", path), result: .file)
            case "edit":
                return Described(text: fileTitle("Changing %@", "Changing a file", args.string("path") ?? args.string("file_path")), result: .file)
            case "write":
                return Described(text: fileTitle("Writing %@", "Writing a file", args.string("path") ?? args.string("file_path")), result: .file)
            case "ls":
                return Described(text: l("Looking %@", place(args.string("path") ?? ".")), result: .entries)
            case "find":
                let path = args.string("path") ?? "."
                return Described(text: findPhrase(pattern: args.string("pattern") ?? args.string("name"), directoriesOnly: false, in: path), result: .matches)
            case "grep":
                let path = args.string("path") ?? "."
                return Described(text: grepPhrase(pattern: args.string("pattern"), in: path), result: .matches)
            case "calendar_read", "read_calendar": return Described(text: l("Looking in your calendar"), result: .none)
            case "calendar_add": return Described(text: l("Adding a calendar entry"), result: .none)
            case "mail_search": return Described(text: l("Searching your mail"), result: .none)
            case "mail_selected": return Described(text: l("Reading the selected mail"), result: .none)
            case "mail_draft": return Described(text: l("Writing a mail draft"), result: .none)
            case "reminders_read": return Described(text: l("Looking at your reminders"), result: .none)
            case "reminder_add": return Described(text: l("Adding a reminder"), result: .none)
            case "list_context", "list_plan_files": return Described(text: l("Going through your documents"), result: .none)
            case "read_context", "read_document":
                if let file = args.string("name") ?? args.string("path") ?? args.string("file"), let shown = lastName(file) {
                    return Described(text: l("Reading %@", shown), result: .none)
                }
                return Described(text: l("Reading a document"), result: .none)
            case "web_search":
                if let query = args.string("query").flatMap(cleanTerm) { return Described(text: l("Searching online for %@", quote(query)), result: .none) }
                return Described(text: l("Searching online"), result: .none)
            case "read_web_page": return Described(text: l("Reading a web page"), result: .none)
            default:
                // Bookkeeping (proposing actions or lookups, recording quotes) is not a step the person needs.
                if name.hasPrefix("propose_") || name.hasPrefix("record_") { return nil }
                if name.contains("calendar") || name.contains("kalender") { return Described(text: l("Looking in your calendar"), result: .none) }
                return Described(text: l("Working on your Mac"), result: .none)
            }
        }

        // MARK: Paths

        func expand(_ raw: String) -> String {
            var p = raw
            if p == "~" || p.hasPrefix("~/") { p = home + p.dropFirst() }
            for prefix in ["$HOME", "${HOME}"] where p == prefix || p.hasPrefix(prefix + "/") { p = home + p.dropFirst(prefix.count) }
            if !p.hasPrefix("/"), let cwd { p = (cwd as NSString).appendingPathComponent(p) }
            // "." and ".." segments are resolved by name only (no file system access).
            if p.hasPrefix("/"), p.contains("/.") { p = URL(fileURLWithPath: p).standardized.path }
            return p
        }

        /// The last name of a path; a pattern in the last place shows the folder before it. `nil`: nothing sensible.
        func lastName(_ raw: String) -> String? {
            var p = expand(raw)
            while p.count > 1, p.hasSuffix("/") { p.removeLast() }
            let parts = p.split(separator: "/").map(String.init)
            guard var last = parts.last else { return nil }
            if last.contains("*") || last.contains("?") || last.contains("[") {
                guard parts.count > 1 else { return nil }
                last = parts[parts.count - 2]
            }
            if last == "." || last == ".." { return nil }
            return tidy(last, limit: 48)
        }

        func fileTitle(_ key: String, _ fallback: String, _ raw: String?) -> String {
            guard let raw, let name = lastName(raw) else { return l(fallback) }
            return l(key, name)
        }

        /// "in your Documents", "on your Desktop", "in the folder Rechnungen"; relative or unknown: "on your Mac".
        func place(_ raw: String?) -> String {
            guard let raw, !raw.isEmpty else { return l("on your Mac") }
            var p = expand(raw)
            while p.count > 1, p.hasSuffix("/") { p.removeLast() }
            // A pattern in the last place (`~/Documents/*.pdf`) means the folder before it.
            if let last = p.split(separator: "/").last, last.contains(where: { "*?[".contains($0) }) {
                p = (p as NSString).deletingLastPathComponent
            }
            if !p.hasPrefix("/") || p == "/" { return l("on your Mac") }
            let homeClean = home.hasSuffix("/") && home.count > 1 ? String(home.dropLast()) : home
            if p == homeClean { return l("in your home folder") }
            if p == homeClean + "/Desktop" { return l("on your Desktop") }
            if p == homeClean + "/Documents" { return l("in your Documents") }
            if p == homeClean + "/Downloads" { return l("in Downloads") }
            if p == homeClean + "/Pictures" { return l("in your Pictures") }
            if p.hasPrefix("/Volumes/"), p.split(separator: "/").count == 2 { return l("on an external drive") }
            guard let name = lastName(p) else { return l("on your Mac") }
            let ext = (name as NSString).pathExtension
            if !ext.isEmpty, ext.count <= 5, ext.allSatisfy({ $0.isLetter || $0.isNumber }) { return l("in the file %@", name) }
            return l("in the folder %@", name)
        }

        // MARK: Text

        func quote(_ term: String) -> String { l("“%@”", term) }

        /// A search word as shown: single line, short, no control characters; `nil` when nothing remains.
        func cleanTerm(_ raw: String) -> String? {
            let t = tidy(raw, limit: 40)
            return t.isEmpty ? nil : t
        }

        func tidy(_ raw: String, limit: Int) -> String {
            let flat = String(String.UnicodeScalarView(raw.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
            let t = flat.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            guard t.count > limit else { return t }
            return String(t.prefix(limit - 1)) + "…"
        }

        // MARK: Searches

        func findPhrase(pattern: String?, directoriesOnly: Bool, in path: String) -> String {
            let there = place(path)
            guard let pattern, !pattern.isEmpty else {
                return directoriesOnly ? l("Looking for folders %@", there) : l("Looking for files %@", there)
            }
            // `*.md`, `**/*.md`: a file type. Anything else around a word: "with … in the name".
            let base = pattern.split(separator: "/").last.map(String.init) ?? pattern
            if base.hasPrefix("*."), !base.dropFirst(2).isEmpty, base.dropFirst(2).allSatisfy({ $0.isLetter || $0.isNumber }) {
                return l("Looking for %@ files %@", "." + base.dropFirst(2).lowercased(), there)
            }
            let core = base.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "?", with: "")
            if let word = cleanTerm(core) {
                return directoriesOnly ? l("Looking for folders with %@ in the name %@", quote(word), there)
                    : l("Looking for files with %@ in the name %@", quote(word), there)
            }
            return directoriesOnly ? l("Looking for folders %@", there) : l("Looking for files %@", there)
        }

        func grepPhrase(pattern: String?, in path: String?) -> String {
            let there = path.map { place($0) }
            // Regular expressions are not shown (backslashes, brackets, pipes): only plain words and phrases.
            let plain = pattern.flatMap { p -> String? in
                p.contains { "\\^$[](){}|+*?".contains($0) } ? nil : cleanTerm(p)
            }
            switch (plain, there) {
            case (let word?, let there?): return l("Searching for %@ %@", quote(word), there)
            case (let word?, nil): return l("Searching for %@", quote(word))
            case (nil, let there?): return l("Searching through text %@", there)
            case (nil, nil): return l("Searching through text")
            }
        }

        // MARK: Shell

        func bash(_ command: String) -> Described {
            let generic = Described(text: l("Working on your Mac"), result: .none)
            // Substitution can hide anything: not interpreted.
            if command.contains("`") || command.contains("$(") || command.contains("<(") { return generic }
            var cwdNow = cwd
            for segment in Shell.segments(command) {
                if segment.writesToFile { return generic }
                var words = segment.words
                while let first = words.first, first.isAssignment { words.removeFirst() }
                guard let program = words.first?.text else { continue }
                let rest = Array(words.dropFirst())
                var scoped = self
                scoped.cwd = cwdNow
                if program == "cd" {
                    if let target = rest.first(where: { !$0.text.hasPrefix("-") }) { cwdNow = scoped.expand(target.text) }
                    continue
                }
                if let described = scoped.program(program, rest) { return described }
                return generic
            }
            return generic
        }

        func program(_ name: String, _ args: [Shell.Word]) -> Described? {
            let (flags, positional) = Shell.split(args, valued: Self.valuedFlags[name] ?? [])
            switch name {
            case "ls":
                return Described(text: l("Looking %@", place(positional.first?.text ?? ".")), result: .entries)
            case "find": return findCommand(args)
            case "mdfind":
                var only: String?
                var terms: [String] = []
                var i = 0
                while i < args.count {
                    let t = args[i].text
                    if t == "-onlyin", i + 1 < args.count { only = args[i + 1].text; i += 2; continue }
                    if t == "-name", i + 1 < args.count { terms.append(args[i + 1].text); i += 2; continue }
                    if !t.hasPrefix("-") || args[i].quoted { terms.append(t) }
                    i += 1
                }
                // Spotlight queries ("kMDItemFSName == …") stay out of sight.
                let word = terms.joined(separator: " ")
                let simple = !word.contains("kMDItem") && !word.contains("==") ? cleanTerm(word) : nil
                let text: String
                switch (simple, only) {
                case (let w?, let o?): text = l("Searching Spotlight for %@ %@", quote(w), place(o))
                case (let w?, nil): text = l("Searching Spotlight for %@", quote(w))
                default: text = l("Searching with Spotlight")
                }
                return Described(text: text, result: .matches)
            case "grep", "egrep", "fgrep", "rg", "ag", "ack":
                var pattern: String?
                var paths: [String] = []
                var all = args.makeIterator()
                var explicit = false
                let valued = Self.valuedFlags[name] ?? []
                while let a = all.next() {
                    if !a.quoted, a.text == "-e" || a.text == "--regexp" { pattern = all.next()?.text; explicit = true; continue }
                    if !a.quoted, a.text.hasPrefix("-"), a.text != "-" {
                        if valued.contains(a.text) { _ = all.next() }
                        continue
                    }
                    if pattern == nil, !explicit { pattern = a.text } else { paths.append(a.text) }
                }
                // Without a path grep reads from a pipe or looks in the current folder: no place is claimed.
                return Described(text: grepPhrase(pattern: pattern, in: paths.first), result: .matches)
            case "cat", "head", "tail", "less", "more", "bat", "nl":
                let files = positional.map(\.text)
                if files.count > 1 { return Described(text: l("Reading %lld files", files.count), result: .file) }
                return Described(text: fileTitle("Reading %@", "Reading a file", files.first), result: .file)
            case "stat", "file", "du", "wc", "mdls":
                return Described(text: l("Taking a closer look at files"), result: .none)
            case "mv": return Described(text: l("Moving files"), result: .none)
            case "cp": return Described(text: l("Copying files"), result: .none)
            case "mkdir": return Described(text: l("Creating a folder"), result: .none)
            default: return nil
            }
        }

        func findCommand(_ args: [Shell.Word]) -> Described? {
            // Dangerous or acting options are not described as a search.
            let acting: Set<String> = ["-delete", "-exec", "-execdir", "-ok", "-okdir"]
            if args.contains(where: { !$0.quoted && acting.contains($0.text) }) { return nil }
            var paths: [String] = []
            var index = 0
            while index < args.count {
                let t = args[index].text
                if !args[index].quoted, t.hasPrefix("-") || t == "(" || t == "!" { break }
                paths.append(t); index += 1
            }
            var name: String?
            var dirs = false
            while index < args.count {
                let t = args[index].text
                if ["-name", "-iname"].contains(t), index + 1 < args.count { name = name ?? args[index + 1].text; index += 2; continue }
                if t == "-type", index + 1 < args.count { dirs = args[index + 1].text == "d"; index += 2; continue }
                index += 1
            }
            return Described(text: findPhrase(pattern: name, directoriesOnly: dirs, in: paths.first ?? "."), result: .matches)
        }

        /// Options that take a value in the next word (so the value is not mistaken for a file or a search word).
        static let valuedFlags: [String: Set<String>] = [
            "head": ["-n", "-c"], "tail": ["-n", "-c"],
            "grep": ["-A", "-B", "-C", "-m", "-f", "-d", "--include", "--exclude", "--max-count"],
            "egrep": ["-A", "-B", "-C", "-m"], "fgrep": ["-A", "-B", "-C", "-m"],
            "rg": ["-g", "-t", "-T", "-A", "-B", "-C", "-m", "--glob", "--type", "--max-count"],
            "ag": ["-G", "-A", "-B", "-C", "-m"], "ack": ["-A", "-B", "-C", "-m"]
        ]

        /// Number of result lines that are results (error messages and exit notes of the command do not count).
        func countLines(_ result: String) -> Int {
            result.split(whereSeparator: \.isNewline).filter { raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line == "(no output)" { return false }
                let lowered = line.lowercased()
                if lowered.hasPrefix("command exited") || lowered.hasPrefix("exit code") { return false }
                for program in ["find:", "grep:", "mdfind:", "ls:", "rg:", "fd:", "bash:", "zsh:"] where lowered.hasPrefix(program) { return false }
                if lowered.contains("operation not permitted") || lowered.contains("permission denied") { return false }
                return true
            }.count
        }
    }

    // MARK: - Arguments and shell words

    /// Tool arguments as Pi sends them. They arrive cut at 400 characters, so broken JSON still yields plain
    /// string values by a tolerant scan.
    struct Arguments {
        var values: [String: String] = [:]
        init(_ json: String) {
            if let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (key, value) in object { if let s = value as? String { values[key] = s } }
                return
            }
            let scanner = try? NSRegularExpression(pattern: #""([A-Za-z_]+)"\s*:\s*"((?:[^"\\]|\\.)*)""#)
            let ns = json as NSString
            for match in scanner?.matches(in: json, range: NSRange(location: 0, length: ns.length)) ?? [] {
                let key = ns.substring(with: match.range(at: 1))
                let raw = ns.substring(with: match.range(at: 2))
                let decoded = (try? JSONSerialization.jsonObject(with: Data(("\"" + raw + "\"").utf8), options: .fragmentsAllowed)) as? String
                if values[key] == nil { values[key] = decoded ?? raw }
            }
        }
        func string(_ key: String) -> String? { values[key].flatMap { $0.isEmpty ? nil : $0 } }
    }

    enum Shell {
        struct Word { var text: String; var quoted: Bool
            var isAssignment: Bool { !quoted && text.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil }
        }
        struct Segment { var words: [Word]; var writesToFile: Bool }

        /// Splits at `| || && ; &` and newlines (outside quotes) into words; redirections other than to /dev/null
        /// or into another stream mark the segment as writing.
        static func segments(_ command: String) -> [Segment] {
            var result: [Segment] = []
            var words: [Word] = []
            var current = ""
            var hasWord = false
            var quoted = false
            var writes = false
            var redirectNext = false
            var quote: Character?
            let chars = Array(command)
            var i = 0
            func endWord() {
                guard hasWord else { return }
                let word = Word(text: current, quoted: quoted)
                current = ""; hasWord = false; quoted = false
                if redirectNext {
                    redirectNext = false
                    if word.text != "/dev/null", !word.text.hasPrefix("&") { writes = true }
                    return
                }
                if !word.quoted, let match = word.text.range(of: #"^[0-9&]*>>?"#, options: .regularExpression) {
                    let target = String(word.text[match.upperBound...])
                    if target.isEmpty { redirectNext = true }
                    else if target != "/dev/null", !target.hasPrefix("&") { writes = true }
                    return
                }
                if !word.quoted, word.text == "<" || word.text.hasPrefix("<") { return }
                words.append(word)
            }
            func endSegment() {
                endWord()
                if !words.isEmpty || writes { result.append(Segment(words: words, writesToFile: writes)) }
                words = []; writes = false; redirectNext = false
            }
            while i < chars.count {
                let c = chars[i]
                if let q = quote {
                    if c == q { quote = nil }
                    else if c == "\\", q == "\"", i + 1 < chars.count { i += 1; current.append(chars[i]) }
                    else { current.append(c) }
                } else {
                    switch c {
                    case "'", "\"": quote = c; hasWord = true; quoted = true
                    case "\\": if i + 1 < chars.count { i += 1; current.append(chars[i]); hasWord = true }
                    case " ", "\t": endWord()
                    case "\n", ";": endSegment()
                    case "|", "&":
                        // `2>&1` keeps its ampersand inside the word.
                        if c == "&", current.hasSuffix(">") { current.append(c); hasWord = true }
                        else { endSegment(); if i + 1 < chars.count, chars[i + 1] == c { i += 1 } }
                    default: current.append(c); hasWord = true
                    }
                }
                i += 1
            }
            endSegment()
            return result
        }

        /// Words that are options (and their values) and the rest. Combined short options like `-ril` are one flag.
        static func split(_ words: [Word], valued: Set<String>) -> (flags: [String], positional: [Word]) {
            var flags: [String] = []
            var positional: [Word] = []
            var skip = false
            for word in words {
                if skip { skip = false; continue }
                if !word.quoted, word.text.hasPrefix("-"), word.text.count > 1 {
                    flags.append(word.text)
                    if valued.contains(word.text) { skip = true }
                } else { positional.append(word) }
            }
            return (flags, positional)
        }
    }
}
