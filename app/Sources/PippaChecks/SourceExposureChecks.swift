import Foundation
import PippaCore

// Source exposure is evidence from before generation or a successful reader result. These checks use only
// synthetic files; a later host-side read must never turn a fabricated answer into an accepted answer.
func runSourceExposureChecks() {
    print("\n— Source exposure: bounded reads and honest recovery —")
    let folder = dir("source-exposure")
    let long = folder.appendingPathComponent("liefernotiz.txt")
    let facts = "Kennung: LINDE-9361\nBetrag: 47,30 EUR\nFällig: 6. November 2026\n"
    let content = facts + String(repeating: "x", count: 3331 - facts.count)
    write(content, long)
    let question = "Nenne mir Kennung, Betrag und Fälligkeit der angehängten Notiz in einem kurzen deutschen Satz."
    func input(_ files: [URL], new: [URL]? = nil, question: String = question, inline: Bool = true) -> PiShownContext.Input {
        .init(question: question, files: files, newFiles: new ?? files, language: "de", inlineShortText: inline)
    }
    let prepared = PiShownContext.prepare(input([long]))
    check("Sources: the exact 3331-character German text is provided before generation under the total budget") {
        content.count == 3331 && prepared.exposed[long.path]?.text == content && prepared.prompt.contains(content)
            && prepared.requiredFiles == [long] && PiAnswerReview.missingSources(prepared: prepared, reads: .init(), files: [long]).isEmpty
    }
    check("Sources: short English and German inline answers retain their evidence") {
        let english = folder.appendingPathComponent("note.txt"), german = folder.appendingPathComponent("kurz.txt")
        write("Reference: MAPLE-7283\nAmount: EUR 47.30", english); write(facts, german)
        let p = PiShownContext.prepare(input([english, german]))
        return p.exposed[english.path]?.text.contains("MAPLE-7283") == true && p.exposed[german.path]?.text.contains("LINDE-9361") == true
            && PiAnswerReview.missingSources(prepared: p, reads: .init(), files: [english, german]).isEmpty
    }
    let unread = PiShownContext.prepare(input([long], inline: false))
    let fabricated = "Die Kennung ist FANTASIE-12345, der Betrag 250 EUR, fällig am 15. November 2026."
    check("Sources: opt-out retains reader-only behavior and removes an entirely unsupported answer") {
        let r = PiAnswerReview.grounded(answer: fabricated, question: question, prepared: unread, reads: .init(), files: [long], language: "de")
        return unread.exposed.isEmpty && !unread.prompt.contains("LINDE-9361") && r?.changed == true
            && r?.text.contains("FANTASIE") == false && r?.text.contains("250") == false
            && r?.text.contains("liefernotiz.txt") == true && r?.text.contains("Bitte mich") == true
    }
    check("Sources: recovery is localized and does not claim that no actions happened") {
        let r = PiAnswerReview.grounded(answer: fabricated, question: question, prepared: unread, reads: .init(), files: [long], language: "en")
        return r?.text.contains("Ask me to read the relevant file") == true && r?.text.contains("nothing changed") == false
    }
    var ledger = PiReadLedger()
    ledger.notePiRead(arguments: jsonPath(long), result: content)
    check("Sources: a successful real-reader receipt supplies the exact content without a host reread") {
        let received = PiSourceExposure.received(unread, reads: ledger, files: [long])
        return received.first?.text == content && received.first?.readStatus == .readable
            && PiAnswerReview.missingSources(prepared: unread, reads: ledger, files: [long]).isEmpty
            && PiAnswerReview.grounded(answer: "Die Kennung ist LINDE-9361.", question: question, prepared: unread,
                                      reads: ledger, files: [long], language: "de")?.changed == false
    }
    check("Sources: drafts require evidence but do not insert numeric review notes into supported draft text") {
        var request = input([long], question: "Write a reply", inline: false); request.requiresFileContents = true
        let p = PiShownContext.prepare(request)
        return PiAnswerReview.grounded(answer: fabricated, question: request.question, prepared: p, reads: .init(), files: [long],
                                       language: "en", verifyValues: false)?.changed == true
            && PiAnswerReview.grounded(answer: "Thank you for the note.", question: request.question, prepared: p, reads: ledger,
                                       files: [long], language: "en", verifyValues: false) == nil
    }
    check("Sources: partial reader evidence keeps a partial-source status") {
        var partial = PiReadLedger()
        partial.notePiRead(arguments: jsonPath(long), result: "Kennung: LINDE-9361\n\n[12 more lines in file. Use offset=2 to continue.]")
        let source = PiSourceExposure.received(unread, reads: partial, files: [long]).first
        let review = PiAnswerReview.grounded(answer: "Die Datei nennt keinen Termin.", question: question, prepared: unread,
                                            reads: partial, files: [long], language: "de")
        return source?.readStatus == .partial && source?.truncated == true && review?.changed == true
    }
    var history = PiSourceExposure()
    history.remember(unread, reads: ledger, files: [long])
    check("Sources: unchanged prior-source follow-up explicitly re-injects evidence instead of relying on Pi memory") {
        // An unsupported extension prevents the deterministic text path, so this exercises actual cached evidence.
        let file = folder.appendingPathComponent("cached.dat"); write(content, file)
        let first = PiShownContext.prepare(input([file], inline: false))
        var read = PiReadLedger(); read.notePiRead(arguments: jsonPath(file), result: content)
        var cache = PiSourceExposure(); cache.remember(first, reads: read, files: [file])
        let next = PiShownContext.prepare(input([file], new: [], question: "What is the reference?"), previous: cache)
        return next.exposed[file.path]?.text == content && next.prompt.contains(content)
            && PiSourceExposure().snapshot(for: file) == nil
    }
    check("Sources: opt-out also prevents injecting prior cached evidence") {
        let next = PiShownContext.prepare(input([long], new: [], inline: false), previous: history)
        return next.exposed.isEmpty && !next.prompt.contains("LINDE-9361")
    }
    check("Sources: same-name different files never share cached content or reader evidence") {
        let second = dir("source-exposure-other").appendingPathComponent(long.lastPathComponent); write("Other source", second)
        let p = PiShownContext.prepare(input([second], inline: false), previous: history)
        return history.snapshot(for: second) == nil
            && PiAnswerReview.missingSources(prepared: p, reads: ledger, files: [second]) == [second]
    }
    check("Sources: a changed source invalidates prior evidence before the follow-up") {
        write("Changed contents with a different size.", long)
        let next = PiShownContext.prepare(input([long], new: [], inline: false), previous: history)
        return history.snapshot(for: long) == nil && next.exposed.isEmpty
            && PiAnswerReview.missingSources(prepared: next, reads: .init(), files: [long]) == [long]
    }
    check("Sources: a file changed during a turn is not added to the history") {
        var cache = PiSourceExposure(); cache.remember(unread, reads: ledger, files: [long])
        return cache.snapshot(for: long) == nil
    }
    check("Sources: the total inline file budget holds across multiple whole records") {
        let files = (0..<8).map { folder.appendingPathComponent("part-\($0).txt") }
        for (index, url) in files.enumerated() { write("RECORD-\(index) " + String(repeating: "a", count: 1900), url) }
        let p = PiShownContext.prepare(input(files))
        return p.exposed.count < files.count && p.exposed.values.reduce(0, { $0 + $1.text.utf8.count }) <= PiShownContext.fileTextBudget
            && p.exposed.allSatisfy { path, snapshot in (try? String(contentsOfFile: path, encoding: .utf8)) == snapshot.text }
            && !PiAnswerReview.missingSources(prepared: p, reads: .init(), files: files).isEmpty
    }
    check("Sources: the description cap never silently excludes an intended source from evidence checks") {
        let files = (0...PiShownContext.maxListed).map { folder.appendingPathComponent("listed-\($0).txt") }
        for url in files { write("Synthetic source", url) }
        let p = PiShownContext.prepare(input(files))
        return p.requiredFiles.count == files.count && p.exposed.count == PiShownContext.maxListed
            && PiAnswerReview.missingSources(prepared: p, reads: .init(), files: files) == [files.last!]
    }
    check("Sources: selected text shares the inline budget") {
        write(String(repeating: "a", count: 7000), long)
        var request = input([long]); request.selectedText = String(repeating: "s", count: 2000)
        let p = PiShownContext.prepare(request)
        return p.exposed.isEmpty && p.prompt.contains(request.selectedText)
    }
    check("Sources: oversized plain text is not silently truncated or treated as exposed") {
        write(String(repeating: "a", count: PiShownContext.fileTextBudget + 1), long)
        let p = PiShownContext.prepare(input([long]))
        return p.exposed.isEmpty && PiAnswerReview.missingSources(prepared: p, reads: .init(), files: [long]) == [long]
    }
    check("Sources: a long symlink and an unsupported binary type are not direct-read candidates") {
        write(content, long)
        let link = folder.appendingPathComponent("linked.txt"), binary = folder.appendingPathComponent("opaque.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: long); write(content, binary)
        return PiShownContext.prepare(input([link])).exposed.isEmpty && PiShownContext.prepare(input([binary])).exposed.isEmpty
    }
    check("Sources: history is bounded by whole records and never truncates identities or content") {
        var cache = PiSourceExposure()
        let files = (0..<5).map { folder.appendingPathComponent("history-\($0).dat") }
        for url in files {
            write(String(repeating: "b", count: 8000), url)
            let p = PiShownContext.prepare(input([url], inline: false))
            var read = PiReadLedger(); read.notePiRead(arguments: jsonPath(url), result: String(repeating: "b", count: 8000))
            cache.remember(p, reads: read, files: [url])
        }
        let saved = files.compactMap { cache.snapshot(for: $0) }
        return saved.count == 4 && saved.allSatisfy { $0.text.utf8.count == 8000 } && cache.snapshot(for: files[0]) == nil
    }
    check("Sources: clear content requests are recognized in both languages") {
        [question, "Read this file", "Summarize the attached letter", "What does this say?", "Was steht in dem Brief?", "Wie viel muss ich zahlen?", "Wann ist das fällig?", "Fasse den Anhang zusammen", "Fass das bitte zusammen", "Was ist das?", "What's this?", "Sum up this document"].allSatisfy(PiShownContext.asksForFileContents)
    }
    check("Sources: file management and ordinary or previous-answer follow-ups do not require reading all attachments") {
        ["Move this file to Downloads", "Rename the file to Delivery", "Make a PDF", "Hello", "Thanks", "Make it shorter", "Explain your previous answer", "Erkläre deine Antwort kürzer"].allSatisfy {
            !PiShownContext.asksForFileContents($0) && PiShownContext.prepare(input([long], question: $0, inline: false)).requiredFiles.isEmpty
        }
    }
    check("Sources: focused source scopes the evidence requirement and explicit source follow-ups still need evidence") {
        let other = folder.appendingPathComponent("other.txt"); write("Other source", other)
        var request = input([long, other], question: "Explain your previous answer using the attached file", inline: false)
        request.focused = [other]
        let p = PiShownContext.prepare(request)
        return p.requiredFiles == [other] && PiAnswerReview.missingSources(prepared: p, reads: ledger, files: [long, other]) == [other]
    }
}

private func jsonPath(_ url: URL) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: ["path": url.path]), as: UTF8.self)
}
