import Foundation
import PippaCore

@MainActor func runAnswerChecks() {
    check("Answer: paragraphs, heading and lists stay in reading order") {
        AnswerDocument("Ergebnis.\n\n## Details\n- Eins\n2. Zwei\n\nNoch ein Absatz.").blocks == [
            .paragraph("Ergebnis."), .heading(2, "Details"), .item(0, "•", "Eins"), .item(0, "2.", "Zwei"), .paragraph("Noch ein Absatz.")
        ]
    }
    check("Answer: code stays literal, also when streaming is cut off") {
        AnswerDocument("```swift\nlet value = \"**literal**\"\n# No heading").blocks == [
            .code("swift", "let value = \"**literal**\"\n# No heading")
        ] && AnswerDocument("Ein **halb").blocks == [.paragraph("Ein **halb")]
    }
    check("Answer: a table needs a real separator row; an incomplete row is preserved") {
        let source = "| Name | Wert |\n| :--- | ---: |\n| A | 3 |\n| B |"
        return AnswerDocument(source).blocks == [.table(["Name", "Wert"], [["A", "3"]]), .paragraph("| B |")]
            && AnswerDocument("a | b\nc | d").blocks == [.paragraph("a | b\nc | d")]
    }
    check("Answer: tables keep code and escaped separators in their cells") {
        AnswerDocument("| Name | Wert |\n| --- | --- |\n| `a|b` | x\\|y |").blocks == [
            .table(["Name", "Wert"], [["`a|b`", "x\\|y"]])
        ]
    }
    check("Answer: long code fences only close with a matching empty line") {
        AnswerDocument("````text\n```\n~~~\n```` wrong\n````\nDanach").blocks == [
            .code("text", "```\n~~~\n```` wrong"), .paragraph("Danach")
        ] && AnswerDocument("```\n").blocks == [.code("", "")]
    }
    check("Answer: nested lists keep their indentation without unbounded layout") {
        AnswerDocument("- Start\n  - Kind\n    3. Enkel").blocks == [
            .item(0, "•", "Start"), .item(1, "•", "Kind"), .item(2, "3.", "Enkel")
        ]
    }
    check("Answer: a bold link title gets the domain only once") {
        String(AnswerDocument.inline("[**Report** lesen](https://example.org/a)").characters) == "Report lesen (example.org)"
    }
    check("Answer: foreign schemes and credentials are not clickable sources") {
        let values = ["file:///tmp/a", "javascript:alert(1)", "pippa://do", "https://user:pass@example.org", "https:/relative"]
        return values.allSatisfy { !AnswerDocument.safeLink(URL(string: $0)!) }
            && AnswerDocument.safeLink(URL(string: "https://example.org/report")!)
    }
    check("Answer: sources show the real domain; blocked targets are visible verbatim") {
        let safe = AnswerDocument.inline("[Report](https://example.org/a)")
        let unsafe = AnswerDocument.inline("[Run](file:///tmp/run)")
        return String(safe.characters) == "Report (example.org)"
            && safe.runs.contains { $0.link?.host == "example.org" }
            && String(unsafe.characters) == "Run (file:///tmp/run)"
            && unsafe.runs.allSatisfy { $0.link == nil }
    }
    check("Answer: HTML and task status stay visible and are not executed") {
        let html = "<script>alert(1)</script> <iframe src=\"https://example.org\"></iframe>"
        return String(AnswerDocument.inline(html).characters) == html
            && AnswerDocument("- [x] Fertig\n- [ ] Offen").blocks == [.item(0, "•", "[x] Fertig"), .item(0, "•", "[ ] Offen")]
            && String(AnswerDocument.inline("[ ] Offen").characters) == "[ ] Offen"
    }
    check("Answer: images load nothing; long answers are not truncated") {
        let image = "![Scan](https://example.org/image.png)"
        let long = String(repeating: "Absatz mit vollständigem Inhalt.\n\n", count: 2000)
        return String(AnswerDocument.inline(image).characters) == image
            && AnswerDocument(long).blocks.count == 2000
            && AnswerDocument.inline(image).runs.allSatisfy { $0.link == nil }
    }
    check("Answer: 2/2 verified file links work; 5/5 unverified or foreign destinations stay inactive") {
        let file = URL(fileURLWithPath: "/fake/Documents/Mietvertrag.pdf")
        let text = "[Vertrag](file:///fake/Documents/Mietvertrag.pdf)"
        let relative = "[Vertrag](/fake/Documents/Mietvertrag.pdf)"
        let unknown = [URL(fileURLWithPath: "/fake/Documents/other.pdf"), URL(string: "file://evil.example/fake/Documents/Mietvertrag.pdf")!,
                       URL(string: "file:///fake/Documents/Mietvertrag.pdf?x=1")!, URL(string: "file:///fake/Documents/Mietvertrag.pdf#x")!, URL(string: "javascript:alert(1)")!]
        return [text, relative].allSatisfy { source in
            AnswerDocument.inline(source, files: [file]).runs.contains { $0.link == file }
                && AnswerDocument.inline(source).runs.allSatisfy { $0.link == nil }
        } && unknown.allSatisfy { !AnswerDocument.safeLink($0, files: [file]) }
    }

}
