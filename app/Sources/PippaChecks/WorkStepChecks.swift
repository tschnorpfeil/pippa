import Foundation
import PippaCore

/// Everyday wording for Pi's tool steps (PippaCore/WorkStepPhrase.swift): never a raw path, flag, pipe or command.
func runWorkStepChecks() {
    let home = "/Users/anna"
    func de(_ tool: String, _ args: String) -> String? { WorkStepPhrase.phrase(tool: tool, arguments: args, home: home, language: "de") }
    func en(_ tool: String, _ args: String) -> String? { WorkStepPhrase.phrase(tool: tool, arguments: args, home: home, language: "en") }
    func bash(_ command: String, _ lang: String = "de") -> String? {
        let data = try! JSONSerialization.data(withJSONObject: ["command": command])
        return WorkStepPhrase.phrase(tool: "bash", arguments: String(decoding: data, as: UTF8.self), home: home, language: lang)
    }
    func expect(_ actual: String?, _ expected: String) -> Bool {
        if actual == expected { return true }
        print("  expected: \(expected)\n  got:      \(actual ?? "nil")"); return false
    }

    check("Work steps: find / mdfind / grep / ls in everyday words (de)") {
        expect(bash(#"find ~ -name "*.md" -not -path "*/node_modules/*" 2>/dev/null | head -20"#), "Suche .md-Dateien in deinem Benutzerordner")
            && expect(bash("mdfind Nullkalkulation"), "Suche mit Spotlight nach „Nullkalkulation“")
            && expect(bash("mdfind -onlyin ~/Documents 'miete'"), "Suche mit Spotlight nach „miete“ in deinen Dokumenten")
            && expect(bash("grep -ril miete ~/Documents"), "Suche „miete“ in deinen Dokumenten")
            && expect(bash(#"grep -rn -i "Kaution" ~/Desktop/Mietvertrag"#), "Suche „Kaution“ im Ordner Mietvertrag")
            && expect(bash("ls ~/Downloads"), "Schaue in Downloads nach")
            && expect(bash("ls -la $HOME/Desktop"), "Schaue auf deinem Schreibtisch nach")
            && expect(bash("ls -la"), "Schaue auf deinem Mac nach")
            && expect(bash("find /Users/anna/Documents/Rechnungen -type d"), "Suche Ordner im Ordner Rechnungen")
            && expect(bash(#"find ~/Downloads -iname "*rechnung*""#), "Suche Dateien mit „rechnung“ im Namen in Downloads")
            && expect(bash("find ~/Documents -name '*.pdf' -mtime -7"), "Suche .pdf-Dateien in deinen Dokumenten")
    }

    check("Work steps: English wording") {
        expect(bash(#"find ~ -name "*.md""#, "en"), "Looking for .md files in your home folder")
            && expect(bash("mdfind Nullkalkulation", "en"), "Searching Spotlight for “Nullkalkulation”")
            && expect(bash("ls ~/Downloads", "en"), "Looking in Downloads")
            && expect(en("read", #"{"path": "/Users/anna/Documents/Nullkalkulation.md"}"#), "Reading Nullkalkulation.md")
            && expect(en("mcp__pippa__mail_search", "{}"), "Searching your mail")
    }

    check("Work steps: Pi's own tools read, ls, find, grep, edit, write") {
        expect(de("read", #"{"path": "/Users/anna/Documents/Nullkalkulation.md"}"#), "Lese Nullkalkulation.md")
            && expect(de("read", #"{"path": "~/Desktop/Brief.docx"}"#), "Lese Brief.docx")
            && expect(de("read", "{}"), "Lese eine Datei")
            && expect(de("ls", #"{"path": "/Users/anna/Downloads"}"#), "Schaue in Downloads nach")
            && expect(de("ls", #"{"path": "/Users/anna/Documents/Steuer/2025/"}"#), "Schaue im Ordner 2025 nach")
            && expect(de("find", #"{"pattern": "*.md", "path": "/Users/anna"}"#), "Suche .md-Dateien in deinem Benutzerordner")
            && expect(de("grep", #"{"pattern": "Miete", "path": "/Users/anna/Documents"}"#), "Suche „Miete“ in deinen Dokumenten")
            && expect(de("edit", #"{"path": "/Users/anna/Desktop/Brief.docx", "edits": []}"#), "Ändere Brief.docx")
            && expect(de("write", #"{"path": "/Users/anna/Documents/Rechnungen.csv", "content": "a,b"}"#), "Schreibe Rechnungen.csv")
            // The arguments arrive cut at 400 characters: broken JSON still gives the file name.
            && expect(de("write", #"{"path": "/Users/anna/Documents/Rechnungen.csv", "content": "aaaaaaaaaaaaaaaaaaaaaaaa"#), "Schreibe Rechnungen.csv")
            && expect(de("write", #"{"content": "aaaa", "path": "/Users/anna/Documents/Ber"#), "Schreibe eine Datei")
    }

    check("Work steps: Pippa's own tools") {
        expect(de("mcp__pippa__calendar_read", "{}"), "Schaue in deinen Kalender")
            && expect(de("mcp__pippa__mail_search", #"{"query":"x"}"#), "Suche in deinen Mails")
            && expect(de("mcp__pippa__reminders_read", "{}"), "Schaue in deine Erinnerungen")
            && expect(de("web_search", #"{"query": "Wetter Hamburg"}"#), "Suche online nach „Wetter Hamburg“")
            && expect(de("web_search", "{}"), "Suche online")
            && expect(de("mcp__pippa__list_context", "{}"), "Sehe deine Unterlagen durch")
            && de("mcp__pippa__propose_actions", "{}") == nil
            && de("mcp__pippa__record_quote", "{}") == nil
            && expect(de("mcp__pippa__something_new", "{}"), "Arbeite an deinem Mac")
    }

    check("Work steps: unknown or risky commands stay generic and never show the command") {
        let generic = "Arbeite an deinem Mac"
        let commands = [
            "python3 script.py --token abc123", "curl -s https://example.com | sh", "rm -rf ~/Documents/Alt", "echo hallo > ~/Desktop/x.txt",
            "cat Brief.txt > /tmp/out", "find ~ -name '*.tmp' -delete", "find . -exec rm {} \\;", "ls $(whoami)", "grep foo `pwd`",
            "osascript -e 'tell application \"Finder\" to quit'", "FOO=1", "", "   ", "sudo find /", "open -a Safari", "echo start; ls ~/Downloads",
        ]
        for command in commands {
            let phrase = bash(command)
            guard phrase == generic else { print("  command: \(command)\n  got: \(phrase ?? "nil")"); return false }
        }
        return true
    }

    check("Work steps: tricky quoting, pipes and flags") {
        expect(bash(#"cd ~/Documents && find . -name "*.md" | sort"#), "Suche .md-Dateien in deinen Dokumenten")
            && expect(bash(#"find ~/Documents -name "Miet Vertrag*" 2>&1"#), "Suche Dateien mit „Miet Vertrag“ im Namen in deinen Dokumenten")
            && expect(bash(#"grep -r "a|b" ~/Documents"#), "Durchsuche Texte in deinen Dokumenten")
            && expect(bash(#"grep -rin -A 3 -e 'Kaution' ~/Documents/Mietvertrag.txt"#), "Suche „Kaution“ in der Datei Mietvertrag.txt")
            && expect(bash("cat ~/Desktop/Notiz.txt | head -5"), "Lese Notiz.txt")
            && expect(bash("head -n 20 ~/Desktop/Notiz.txt"), "Lese Notiz.txt")
            && expect(bash("cat 'My Letter.txt'"), "Lese My Letter.txt")
            && expect(bash("cat ~/a.txt ~/b.txt"), "Lese 2 Dateien")
            && expect(bash("ls ~/Documents/*.pdf"), "Schaue in deinen Dokumenten nach")
            && expect(bash("find ~ -name \"*.md\"\nls"), "Suche .md-Dateien in deinem Benutzerordner")
            && expect(bash("mdfind \"kMDItemFSName == '*.pdf'\""), "Suche mit Spotlight")
            && expect(bash("mv a.txt b.txt"), "Verschiebe Dateien")
            && expect(bash("mkdir -p ~/Desktop/Neu"), "Lege einen Ordner an")
            && expect(bash("MY=1 ls ~/Desktop"), "Schaue auf deinem Schreibtisch nach")
            && expect(bash("find ~ -name '*.md' 2>/dev/null"), "Suche .md-Dateien in deinem Benutzerordner")
    }

    check("Work steps: no raw paths, flags or pipes in any phrase; long names are shortened") {
        let inputs = [
            #"find /Users/anna/Library/Application\ Support -name "*.sqlite" | xargs ls"#, "grep -rn --include=*.swift foo /usr/local/lib",
            "ls -R /private/var/folders/xx/yy", "cat /etc/hosts", "find / -name x",
        ]
        for command in inputs {
            guard let phrase = bash(command) else { return false }
            if phrase.contains("/") || phrase.contains(" -") || phrase.contains("|") || phrase.contains("--") { print("  \(command) -> \(phrase)"); return false }
        }
        let long = String(repeating: "Lang", count: 40)
        guard let phrase = de("read", "{\"path\": \"/Users/anna/Documents/\(long).pdf\"}"), phrase.count < 80, phrase.hasPrefix("Lese ") else { return false }
        return true
    }

    check("Work steps: short result when cheaply known") {
        func out(_ tool: String, _ args: String, error: Bool = false, _ result: String, cut: Bool = false) -> String? {
            WorkStepPhrase.outcome(tool: tool, arguments: args, isError: error, result: result, home: home, language: "de", resultWasCut: cut)
        }
        let find = #"{"command": "find ~ -name '*.md'"}"#
        return expect(out("bash", find, "/Users/anna/a.md\n/Users/anna/b.md\n/Users/anna/c.md\n"), "3 Treffer")
            && expect(out("bash", find, "/Users/anna/a.md\n"), "1 Treffer")
            && expect(out("bash", find, "(no output)"), "nichts gefunden")
            && expect(out("bash", find, ""), "nichts gefunden")
            && expect(out("bash", find, "find: /Users/anna/Library/x: Operation not permitted\n/Users/anna/a.md\n"), "1 Treffer")
            && expect(out("bash", #"{"command": "grep -ril miete ~/Documents"}"#, error: true, "\n\nCommand exited with code 1"), "nichts gefunden")
            && expect(out("bash", #"{"command": "mdfind Miete"}"#, "/a\n/b\n"), "2 Treffer")
            && expect(out("bash", find, "/a\n/b\n", cut: true), "viele Treffer")
            && expect(out("bash", #"{"command": "ls ~/Downloads"}"#, "a.pdf\nb.pdf\n"), "2 Einträge")
            && expect(out("bash", #"{"command": "ls ~/Downloads"}"#, ""), "leer")
            && expect(out("ls", #"{"path": "/Users/anna/Nope"}"#, error: true, "ls: /Users/anna/Nope: No such file or directory"), "Ordner nicht gefunden")
            && expect(out("find", #"{"pattern": "*.md"}"#, "No files found matching pattern"), "nichts gefunden")
            && expect(out("read", #"{"path": "/Users/anna/x.md"}"#, error: true, "ENOENT: no such file or directory, open '/Users/anna/x.md'"), "Datei nicht gefunden")
            && expect(out("read", #"{"path": "/Users/anna/x.md"}"#, error: true, "EACCES: permission denied"), "kein Zugriff")
            && out("read", #"{"path": "/Users/anna/x.md"}"#, "Inhalt") == nil
            && out("bash", #"{"command": "python3 x.py"}"#, "ok") == nil
            && expect(out("bash", #"{"command": "python3 x.py"}"#, error: true, "boom"), "hat nicht geklappt")
            && out("mcp__pippa__propose_actions", "{}", "x") == nil
    }

    check("Work steps: every phrase exists in German and English (no raw key leaks)") {
        let tools: [(String, String)] = [
            ("read", #"{"path":"/Users/anna/A.md"}"#), ("read", "{}"), ("edit", "{}"), ("write", "{}"), ("ls", "{}"), ("find", "{}"), ("grep", "{}"),
            ("mcp__pippa__calendar_read", "{}"), ("mcp__pippa__calendar_add", "{}"), ("mcp__pippa__mail_search", "{}"), ("mcp__pippa__mail_selected", "{}"),
            ("mcp__pippa__mail_draft", "{}"), ("mcp__pippa__reminders_read", "{}"), ("mcp__pippa__reminder_add", "{}"), ("mcp__pippa__read_document", "{}"),
            ("mcp__pippa__read_document", #"{"name":"A.pdf"}"#), ("mcp__pippa__list_context", "{}"), ("web_search", "{}"), ("fetch_content", "{}"),
        ]
        let commands = ["ls", "ls ~", "ls ~/Desktop", "ls ~/Documents", "ls ~/Downloads", "ls ~/Pictures", "ls /Volumes/Stick", "ls /Users/anna/x", "find ~ -name '*.md'",
                        "find ~ -type d", "find ~ -iname 'x*'", "find ~ -type d -name 'x'", "mdfind a", "mdfind", "mdfind -onlyin ~ a", "grep a ~", "grep a", "grep '\\.' ~",
                        "grep -r", "cat a b", "cat", "stat a", "mv a b", "cp a b", "mkdir x", "frob", "cat x", "grep a ~/f.txt"]
        var count = 0
        for language in ["de", "en"] {
            var phrases = tools.compactMap { WorkStepPhrase.phrase(tool: $0.0, arguments: $0.1, home: home, language: language) }
            phrases += commands.compactMap { bash($0, language) }
            for phrase in phrases {
                if phrase.contains("%") { print("  placeholder left: \(phrase)"); return false }
                let english = ["Looking", "Searching", "Reading", "Working", "Writing", "Changing", "Moving", "Copying", "Creating", "Adding", "Going", "Taking"]
                if language == "de", english.contains(where: { phrase.hasPrefix($0) }) { print("  not translated: \(phrase)"); return false }
                count += 1
            }
        }
        for (key, expected) in [("nothing found", "nichts gefunden"), ("file not found", "Datei nicht gefunden"), ("1 item", "1 Eintrag"),
                                ("in the file %@", "in der Datei %@")] {
            guard L(key, table: "Thought", language: "de") == expected, L(key, table: "Thought", language: "en") == key else { return false }
        }
        return count > 60
    }

    check("Work steps: the Thought Line keeps the steps, shows the current one and hands them to the receipt") {
        let request = UUID()
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var line = ThoughtLine()
        line.begin(request, at: t0)
        // Pi's own tool: no mapped phase before; now a calm "working" phase with the step as detail.
        let changed = line.apply(.toolStarted(name: "bash", source: nil, step: "Suche .md-Dateien in deinem Benutzerordner"), request: request, at: t0)
        guard changed, line.phase == .working, line.currentStep == "Suche .md-Dateien in deinem Benutzerordner", line.recentSteps.shown.isEmpty else { return false }
        line.apply(.toolEnded(name: "bash", outcome: "3 Treffer"), request: request, at: t0)
        guard line.currentStep == nil, line.recentSteps.shown.map(\.outcome) == ["3 Treffer"], line.phase == .waitingForAnswer(continuing: false) else { return false }
        for index in 1...7 {
            line.apply(.toolStarted(name: "read", source: nil, step: "Lese \(index).md"), request: request, at: t0)
            line.apply(.toolEnded(name: "read", outcome: nil), request: request, at: t0)
        }
        let recent = line.recentSteps
        guard recent.shown.count == ThoughtLine.visibleSteps, recent.hidden == 4, recent.shown.last?.text == "Lese 7.md" else { return false }
        // Bookkeeping tools without a step leave everything as it is.
        line.apply(.toolStarted(name: "propose_actions", source: nil), request: request, at: t0)
        guard line.currentStep == nil else { return false }
        line.apply(.toolEnded(name: "propose_actions"), request: request, at: t0)
        line.textArrived(request: request)
        guard let receipt = line.finish(request: request, at: t0.addingTimeInterval(9)) else { return false }
        let data = try JSONEncoder().encode(receipt)
        let back = try JSONDecoder().decode(WorkReceipt.self, from: data)
        let old = try JSONDecoder().decode(WorkReceipt.self, from: Data(#"{"seconds":3,"sources":[],"lookedUpOnline":false,"checkedCalendar":false}"#.utf8))
        return back == receipt && receipt.steps?.count == 8 && receipt.steps?.first?.outcome == "3 Treffer" && old.steps == nil
            && receipt.summary == L("%lld steps · %@", table: "Thought", 8, WorkReceipt.duration(9))
    }

    check("Work steps: each step knows what it touched and whether it worked, old receipts still open") {
        let home = "/Users/anna"
        let step = { (tool: String, args: String) in WorkStepPhrase.step(tool: tool, arguments: args, home: home, language: "de")?.kind }
        guard step("read", #"{"path":"~/Documents/Brief.docx"}"#) == .file, step("edit", #"{"path":"a.txt"}"#) == .change,
              step("bash", #"{"command":"find ~/Documents -name '*.pdf'"}"#) == .search, step("bash", #"{"command":"osascript -e x"}"#) == .mac,
              step("web_search", #"{"query":"Miete"}"#) == .online, step("mcp__pippa__mail_search", "{}") == .mail,
              step("remember", "{}") == .memory, step("mcp__pippa__search_files", #"{"query":"Miete"}"#) == .search,
              step("move_files", "{}") == .change, step("propose_actions", "{}") == nil else { return false }
        let missing = WorkStepPhrase.ending(tool: "read", arguments: #"{"path":"x.pdf"}"#, isError: true, result: "ENOENT", home: home, language: "de")
        let nothing = WorkStepPhrase.ending(tool: "grep", arguments: #"{"pattern":"Miete"}"#, isError: true, result: "", home: home, language: "de")
        guard missing.failed, missing.outcome == "Datei nicht gefunden", !nothing.failed, nothing.outcome == "nichts gefunden" else { return false }
        let request = UUID()
        var line = ThoughtLine()
        line.begin(request, at: Date())
        line.apply(.toolStarted(name: "read", source: nil, step: "Lese x.pdf", kind: .file), request: request, at: Date())
        line.apply(.toolEnded(name: "read", outcome: "Datei nicht gefunden", failed: true), request: request, at: Date())
        let old = try JSONDecoder().decode(WorkStep.self, from: Data(#"{"text":"Lese a.md","outcome":"leer"}"#.utf8))
        return line.doneSteps == [WorkStep(text: "Lese x.pdf", outcome: "Datei nicht gefunden", kind: .file, failed: true)]
            && old == WorkStep(text: "Lese a.md", outcome: "leer")
    }

    check("Work steps: stale tool events after the end change nothing") {
        let request = UUID()
        var line = ThoughtLine()
        line.begin(request, at: Date())
        line.apply(.toolStarted(name: "bash", source: nil, step: "Suche Dateien"), request: request, at: Date())
        line.end(request: request)
        let late = line.apply(.toolStarted(name: "bash", source: nil, step: "Suche mehr"), request: request, at: Date())
        return !late && line.steps.isEmpty && line.currentStep == nil
    }

    check("Work steps: AppleScript names the app it talks to, never the script") {
        let mailKind = WorkStepPhrase.step(tool: "bash", arguments: #"{"command":"osascript -e 'tell application \"Mail\" to get subject of messages 1 thru 5 of inbox'"}"#,
                                           home: home, language: "de")?.kind
        return expect(bash(#"osascript -e 'tell application "Mail" to count messages of inbox'"#), "Schaue in deine Mails")
            && expect(bash("osascript <<'EOF'\ntell application \"Calendar\"\n  get name of calendars\nend tell\nEOF"), "Schaue in deinen Kalender")
            && expect(bash(#"osascript -e 'tell app "Notes" to get name of notes'"#), "Schaue in deine Notizen")
            && expect(bash(#"osascript -e 'tell application "Safari" to get URL of front document'"#), "Nutze Safari")
            && expect(bash(#"osascript -e 'tell application "Finder" to get selection'"#), "Arbeite an deinem Mac")
            && expect(bash(#"osascript -e 'display dialog "hi"'"#), "Arbeite an deinem Mac")
            && expect(bash(#"osascript -e 'tell application "Mail" to count messages of inbox'"#, "en"), "Looking in your mail")
            && mailKind == .mail
    }

    check("Work steps: the same step four times in a row is one row with a count") {
        let request = UUID()
        var line = ThoughtLine()
        line.begin(request, at: Date())
        for _ in 1...4 {
            line.apply(.toolStarted(name: "bash", source: nil, step: "Arbeite an deinem Mac", kind: .mac), request: request, at: Date())
            line.apply(.toolEnded(name: "bash"), request: request, at: Date())
        }
        line.apply(.toolStarted(name: "read", source: nil, step: "Lese a.md", kind: .file), request: request, at: Date())
        line.apply(.toolEnded(name: "read"), request: request, at: Date())
        line.apply(.toolStarted(name: "bash", source: nil, step: "Arbeite an deinem Mac", kind: .mac), request: request, at: Date())
        line.apply(.toolEnded(name: "bash"), request: request, at: Date())
        let recent = line.recentSteps
        let differentOutcomes = WorkStep.merged([WorkStep(text: "Suche x", outcome: "3 Treffer"), WorkStep(text: "Suche x", outcome: "nichts gefunden")])
        guard recent.hidden == 0, recent.shown.map(\.text) == ["Arbeite an deinem Mac", "Lese a.md", "Arbeite an deinem Mac"],
              recent.shown.map(\.repeats) == [4, nil, nil], differentOutcomes.count == 2 else { return false }
        // The receipt keeps every step (the summary counts them); only the list merges.
        guard let receipt = line.finish(request: request, at: Date()), receipt.steps?.count == 6 else { return false }
        let data = try JSONEncoder().encode(WorkStep.merged(receipt.steps ?? []))
        return try JSONDecoder().decode([WorkStep].self, from: data).first?.repeats == 4
            && WorkStep(text: "Arbeite an deinem Mac", repeats: 4).line.contains("4")
    }
}
