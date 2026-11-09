import Foundation
import PippaCore

/// The answer's Markdown blocks: what a full parse finds, that parsing while the answer streams in finds the same at
/// every step, and that streaming reads each character about once instead of the whole text on every new word.
func runMarkdownChecks() {
    let fixtures = [
        """
        ## Überblick
        Dein aktueller Stand ist **ETF-Portfolio.md**,
        zuletzt geändert am 1. November.

        - **MSCI World:** 62 %
          - davon Sparplan 400 €
            der Rest einmalig
        - **Anleihen:** 20 %
        1. Erst prüfen
        2. Dann überweisen

        > Einwände gehen innerhalb von vier Wochen.

        ```swift
        let total = 184.37

        print(total)
        ```

        | Jahr | Ergebnis |
        |---|---:|
        | 2024 | 90,55 € |
        | 2025 | 184,37 € |

        ---
        # Ende
        Nach der Tabelle.
        """,
        """
        | kein | Kopf |
        Text gleich danach
        ### Drei
        * Stern
        + Plus
        • Punkt
        10) Zehn
        ***
        ```
        offen bis zum Schluss
        | keine | Tabelle |
        """,
        "Eine Zeile ohne Umbruch, die einfach weitergeht und weitergeht.",
        "\n\n# A\n\n\n- a\n\n- b\n|a|\n|-|\n|1|\n\n___",
    ]

    check("Markdown: a full parse finds every kind of block") {
        let blocks = MarkdownBlock.parse(fixtures[0])
        let expected: [MarkdownBlock] = [
            .heading(2, "Überblick"),
            .paragraph("Dein aktueller Stand ist **ETF-Portfolio.md**,\nzuletzt geändert am 1. November."),
            .list([.init(text: "**MSCI World:** 62 %", indent: 0),
                   .init(text: "davon Sparplan 400 € der Rest einmalig", indent: 1),
                   .init(text: "**Anleihen:** 20 %", indent: 0)], ordered: false),
            .list([.init(text: "Erst prüfen", indent: 0), .init(text: "Dann überweisen", indent: 0)], ordered: true),
            .quote("Einwände gehen innerhalb von vier Wochen."),
            .code("let total = 184.37\n\nprint(total)"),
            .table(["Jahr", "Ergebnis"], [["2024", "90,55 €"], ["2025", "184,37 €"]]),
            .rule,
            .heading(1, "Ende"),
            .paragraph("Nach der Tabelle."),
        ]
        if blocks != expected { print("  got: \(blocks)") }
        return blocks == expected
    }

    check("Markdown: lines that only look like blocks stay text, an open code fence holds the rest") {
        let blocks = MarkdownBlock.parse(fixtures[1])
        let expected: [MarkdownBlock] = [
            .paragraph("| kein | Kopf |\nText gleich danach"),
            .heading(3, "Drei"),
            .list([.init(text: "Stern", indent: 0), .init(text: "Plus", indent: 0), .init(text: "Punkt", indent: 0)], ordered: false),
            .list([.init(text: "Zehn", indent: 0)], ordered: true),
            .rule,
            .code("offen bis zum Schluss\n| keine | Tabelle |"),
        ]
        if blocks != expected { print("  got: \(blocks)") }
        return blocks == expected
    }

    check("Markdown: every prefix in 37-character steps parses the same while streaming as in one go") {
        var mismatches: [String] = []
        for fixture in fixtures {
            var stream = MarkdownStream()
            let characters = Array(fixture)
            var length = 0
            while true {
                let prefix = String(characters[..<length])
                stream.update(prefix)
                if stream.blocks != MarkdownBlock.parse(prefix) { mismatches.append(prefix) }
                if length == characters.count { break }
                length = min(characters.count, length + 37)
            }
            if stream.restarts != 0 { mismatches.append("restarted: \(fixture.prefix(20))") }
        }
        // Every single step as well, so a block boundary falling inside a step can't hide a difference.
        for fixture in fixtures {
            var stream = MarkdownStream()
            var prefix = ""
            for character in fixture {
                prefix.append(character)
                stream.update(prefix)
                if stream.blocks != MarkdownBlock.parse(prefix) { mismatches.append(prefix); break }
            }
        }
        for mismatch in mismatches.prefix(3) { print("  differs after: \(mismatch.suffix(60).debugDescription)") }
        return mismatches.isEmpty
    }

    check("Markdown: a text that does not continue the last one starts over") {
        var stream = MarkdownStream()
        stream.update("# Eins\n\nAlt")
        stream.update("Neu\n\n- a")
        return stream.restarts == 1 && stream.blocks == MarkdownBlock.parse("Neu\n\n- a")
    }

    check("Markdown: streaming 30,000 characters reads at most three times the text") {
        var text = ""
        var round = 0
        while text.utf8.count < 30_000 {
            round += 1
            text += fixtures[0] + "\n\n"
            text += "Absatz \(round): " + String(repeating: "Ein längerer Satz über Nebenkosten, Fristen und Termine. ", count: 1 + round % 9) + "\n\n"
            text += "| Monat | Betrag |\n|---|---|\n" + (1...6).map { "| \($0) | \($0 * 37),00 € |\n" }.joined() + "\n"
        }
        var stream = MarkdownStream()
        let characters = Array(text)
        var prefix = ""
        var start = 0
        var updates = 0
        while start < characters.count {
            prefix += String(characters[start..<min(characters.count, start + 40)])
            start += 40
            stream.update(prefix)
            updates += 1
        }
        let length = text.utf8.count
        let ratio = Double(stream.scanned) / Double(length)
        let reparse = updates * length / 2
        print("  \(length) bytes in \(updates) updates: read \(stream.scanned) (\(String(format: "%.2f", ratio))×); parsing everything per update: ~\(reparse)")
        return stream.restarts == 0 && stream.scanned <= 3 * length && stream.blocks == MarkdownBlock.parse(text)
    }
}
