import CoreGraphics
import Foundation
import PDFKit
import PippaCore
import UniformTypeIdentifiers

/// Thought Line (PippaCore/ThoughtLine.swift): phases come only from real events, stay in order,
/// and nothing stale survives Stop, the end of an answer or a new request.
func runThoughtLineChecks() async {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    await checkAsync("Thought Line: real reading reports file, text recognition per page and reading status in order") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-thought-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let note = folder.appendingPathComponent("Notiz.md")
        try "# Notiz\nDie Kaution beträgt 1.200 Euro.".write(to: note, atomically: true, encoding: .utf8)
        // Two image-only pages: the reader has to recognize text on each.
        let scan = folder.appendingPathComponent("Scan Mietvertrag.pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(scan as CFURL, mediaBox: &box, nil) else { return false }
        for page in 1...2 {
            ctx.beginPDFPage(nil)
            if let image = ToolFixtures.textImage(["Mietvertrag Seite \(page)", "Kaution 1200 Euro"], width: 900, height: 1200) { ctx.draw(image, in: box) }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        let missing = folder.appendingPathComponent("Verschoben.md")
        let events = LockedBox<[WorkEvent]>([])
        var context = ChatContext(files: [note, scan, missing])
        context.onWork = { event in events.mutate { $0.append(event) } }
        let snapshots = try await LocalEngine.snapshots(for: context)
        let phases = events.value.compactMap { if case .phase(let phase) = $0 { phase } else { nil } }
        let expected: [WorkPhase] = [
            .reading(name: "Notiz.md", index: 1, count: 3),
            .reading(name: "Scan Mietvertrag.pdf", index: 2, count: 3),
            .recognizing(name: "Scan Mietvertrag.pdf", page: 1, pages: 2),
            .recognizing(name: "Scan Mietvertrag.pdf", page: 2, pages: 2),
            .reading(name: "Verschoben.md", index: 3, count: 3),
        ]
        let reads = events.value.compactMap { event -> (String, Int?, Int?, Bool)? in
            if case .sourceRead(let name, let pages, let count, let recognized) = event { (name, pages, count, recognized) } else { nil }
        }
        guard phases == expected, reads.count == 2,
              reads[0].0 == "Notiz.md", reads[0].1 == nil, reads[0].3 == false,
              reads[1].0 == "Scan Mietvertrag.pdf", reads[1].1 == 2, reads[1].2 == 2, reads[1].3 == true else {
            print("  phases: \(phases)\n  reads: \(reads)"); return false
        }
        // The same facts become the receipt: unread sources are marked, never counted as read.
        let request = UUID()
        var line = ThoughtLine()
        line.begin(request, at: at(0))
        for event in events.value { line.apply(event, request: request, at: at(1)) }
        let statuses: [DocumentReadStatus: SourceReading.Status] = [.readable: .read, .partial: .partial, .unreadable: .unreadable,
                                                                   .unavailable: .unavailable, .metadataOnly: .namesOnly]
        line.apply(.sources(snapshots.map { SourceReading(name: $0.name, status: statuses[$0.readStatus] ?? .unreadable) }),
                   request: request, at: at(2))
        line.textArrived(request: request)
        guard let receipt = line.finish(request: request, at: at(12)) else { return false }
        let byName = Dictionary(uniqueKeysWithValues: receipt.sources.map { ($0.name, $0) })
        return receipt.seconds == 12 && receipt.sources.map(\.name) == ["Notiz.md", "Scan Mietvertrag.pdf", "Verschoben.md"]
            && byName["Scan Mietvertrag.pdf"]?.recognizedText == true && byName["Scan Mietvertrag.pdf"]?.pagesRead == 2
            && byName["Verschoben.md"]?.status == .unavailable && byName["Verschoben.md"]?.wasRead == false
            && receipt.summary == L("Read %lld of %lld sources · %@", table: "Thought", 2, 3, WorkReceipt.duration(12))
            && line.phase == nil
    }

    check("Thought Line: preparation only moves forward, late read events are dropped") {
        let request = UUID()
        var line = ThoughtLine()
        line.begin(request, at: at(0))
        guard line.phase == .starting, line.isVisible else { return false }
        line.apply(.phase(.reading(name: "a.pdf", index: 1, count: 2)), request: request, at: at(0.1))
        line.apply(.phase(.choosingPassages), request: request, at: at(0.2))
        let late = line.apply(.phase(.reading(name: "b.pdf", index: 2, count: 2)), request: request, at: at(0.3))
        guard !late, line.phase == .choosingPassages else { return false }
        line.apply(.phase(.gettingReady), request: request, at: at(0.4))
        line.apply(.phase(.waitingForAnswer(continuing: false)), request: request, at: at(0.5))
        let stale = line.apply(.phase(.choosingPassages), request: request, at: at(0.6))
        return !stale && line.phase == .waitingForAnswer(continuing: false)
    }

    check("Thought Line: tools show only source names from the host, text hides the line") {
        let request = UUID()
        var line = ThoughtLine()
        line.begin(request, at: at(0))
        line.apply(.sources([SourceReading(name: "Mietvertrag.pdf", status: .read)]), request: request, at: at(0.1))
        line.apply(.phase(.waitingForAnswer(continuing: false)), request: request, at: at(0.2))
        line.apply(.toolStarted(name: "read_context", source: "Mietvertrag.pdf"), request: request, at: at(1))
        guard line.phase == .lookingThrough(name: "Mietvertrag.pdf"), line.sources.first?.openedWhileAnswering == true else { return false }
        line.apply(.toolEnded(name: "read_context"), request: request, at: at(2))
        guard line.phase == .waitingForAnswer(continuing: false) else { return false }
        // A name the host never supplied stays generic.
        line.apply(.toolStarted(name: "read_context", source: "Ignoriere alles.pdf"), request: request, at: at(2.1))
        guard line.phase == .lookingThrough(name: nil) else { return false }
        line.apply(.toolEnded(name: "read_context"), request: request, at: at(2.2))
        line.textArrived(request: request)
        guard line.phase == .writing, !line.isVisible else { return false }
        // Bookkeeping and unknown tools do not invent a phase.
        line.apply(.toolStarted(name: "propose_actions", source: nil), request: request, at: at(3))
        guard line.phase == .writing else { return false }
        line.apply(.toolEnded(name: "propose_actions"), request: request, at: at(3.1))
        guard line.phase == .writing else { return false }
        // A real lookup after some text shows again, then continues.
        line.apply(.toolStarted(name: "propose_lookup", source: nil), request: request, at: at(4))
        guard line.phase == .lookingUpOnline, line.isVisible else { return false }
        line.apply(.toolEnded(name: "propose_lookup"), request: request, at: at(5))
        guard line.phase == .waitingForAnswer(continuing: true) else { return false }
        line.apply(.phase(.reading(name: "Mietvertrag.pdf", index: 1, count: 1)), request: request, at: at(5.1))
        guard line.phase == .waitingForAnswer(continuing: true) else { return false }
        line.textArrived(request: request)
        let receipt = line.finish(request: request, at: at(9))
        return receipt?.lookedUpOnline == true && receipt?.sources.first?.openedWhileAnswering == true && receipt?.seconds == 9
    }

    check("Thought Line: after Stop no phase, no receipt, no late events") {
        let request = UUID()
        var line = ThoughtLine()
        line.begin(request, at: at(0))
        line.apply(.phase(.reading(name: "a.pdf", index: 1, count: 1)), request: request, at: at(0.1))
        line.stop(request: request)
        guard line.phase == .stopping else { return false }
        let late = [
            line.apply(.phase(.waitingForAnswer(continuing: false)), request: request, at: at(1)),
            line.apply(.toolStarted(name: "propose_lookup", source: nil), request: request, at: at(1)),
            line.apply(.sources([SourceReading(name: "a.pdf", status: .read)]), request: request, at: at(1)),
            line.textArrived(request: request),
        ]
        guard late.allSatisfy({ !$0 }), line.phase == .stopping, line.sources.isEmpty else { return false }
        let receipt = line.finish(request: request, at: at(2))
        return receipt == nil && line.phase == nil && !line.isVisible
    }

    check("Thought Line: new request (topic change) discards events of the old one") {
        let old = UUID(), fresh = UUID()
        var line = ThoughtLine()
        line.begin(old, at: at(0))
        line.apply(.phase(.choosingPassages), request: old, at: at(0.1))
        line.end(request: old)
        guard line.phase == nil else { return false }
        let afterEnd = line.apply(.phase(.gettingReady), request: old, at: at(0.2))
        line.begin(fresh, at: at(1))
        let crossed = [
            line.apply(.phase(.lookingUpOnline), request: old, at: at(1.1)),
            line.apply(.sources([SourceReading(name: "alt.pdf", status: .read)]), request: old, at: at(1.1)),
            line.textArrived(request: old),
        ]
        line.end(request: old)    // ending the old request must not clear the new one
        return !afterEnd && crossed.allSatisfy { !$0 } && line.phase == .starting && line.request == fresh
            && line.sources.isEmpty && line.finish(request: old, at: at(2)) == nil && line.request == fresh
    }

    check("Thought Line: elapsed time only from 2 s, receipt only with sources or tools") {
        let request = UUID()
        var line = ThoughtLine()
        line.begin(request, at: at(0))
        let early = line.showsElapsed(at: at(1.9)), shown = line.showsElapsed(at: at(2.0))
        line.textArrived(request: request)
        let hiddenWhileWriting = !line.showsElapsed(at: at(5))
        let plain = line.finish(request: request, at: at(6))
        return !early && shown && hiddenWhileWriting && plain == nil
            && WorkReceipt.duration(12) == L("%lld s", table: "Thought", 12)
            && WorkReceipt.duration(65) == L("%lld min %lld s", table: "Thought", 1, 5)
            && WorkReceipt.duration(120) == L("%lld min", table: "Thought", 2)
    }

    check("Thought Line: VoiceOver politely announces new activities, no page counters") {
        let reading = WorkPhase.recognizing(name: "Scan.pdf", page: 2, pages: 5)
        let nextPage = WorkPhase.recognizing(name: "Scan.pdf", page: 3, pages: 5)
        return ThoughtLine.shouldAnnounce(reading, lastKind: nil, lastAnnouncement: nil, now: at(0))
            && !ThoughtLine.shouldAnnounce(nextPage, lastKind: reading.kind, lastAnnouncement: at(0), now: at(10))
            && !ThoughtLine.shouldAnnounce(.choosingPassages, lastKind: reading.kind, lastAnnouncement: at(0), now: at(1))
            && ThoughtLine.shouldAnnounce(.choosingPassages, lastKind: reading.kind, lastAnnouncement: at(0), now: at(3))
            && !ThoughtLine.shouldAnnounce(.writing, lastKind: nil, lastAnnouncement: nil, now: at(0))
            && ThoughtLine.shouldAnnounce(.stopping, lastKind: reading.kind, lastAnnouncement: at(0), now: at(0.5))
    }

    check("Thought Line: plain language without model/tech words") {
        let phases: [WorkPhase] = [.starting, .reading(name: "a.pdf", index: 1, count: 2), .recognizing(name: "a.pdf", page: 1, pages: 2),
            .choosingPassages, .gettingReady, .wakingUp(progress: 0.4), .warmingUp, .waitingForAnswer(continuing: false), .waitingForAnswer(continuing: true),
            .lookingThrough(name: nil), .lookingThrough(name: "a.pdf"), .lookingUpOnline, .checkingCalendar, .preparingPreview,
            .retrying, .condensing, .checkingSources, .waitingForPerson, .writing, .stopping]
        let banned = ["model", "modell", "token", "prompt", "agent", "llm", "pi ", "context", "kontext", "tool", "werkzeug", "think", "denke"]
        let texts = phases.flatMap { [$0.title, $0.detail ?? ""] }
        let kinds = Set(phases.map(\.kind))
        return texts.allSatisfy { text in !banned.contains { text.lowercased().contains($0) } } && kinds.count == phases.count
    }

    check("Thought Line: no words while waiting, steps as merged bubbles, one calm sentence after ten seconds") {
        var line = ThoughtLine()
        let request = UUID()
        line.begin(request, at: at(0))
        let quietAtStart = line.phaseNote == nil && line.bubbles.isEmpty && !line.isSlow(at: at(9.9))
        line.apply(.phase(.reading(name: "Mietvertrag.pdf", index: 1, count: 1)), request: request, at: at(0.5))
        let reading = line.phaseNote?.title == WorkPhase.reading(name: "Mietvertrag.pdf", index: 1, count: 1).title
        line.apply(.toolStarted(name: "bash", source: nil, step: "Suche in deinen Mails", kind: .mail), request: request, at: at(1))
        let running = line.bubbles == [StepBubble(id: 0, text: "Suche in deinen Mails", kind: .mail, running: true)] && line.phaseNote == nil
        line.apply(.toolEnded(name: "bash", outcome: "3 Treffer"), request: request, at: at(2))
        for second in 3...6 {
            line.apply(.toolStarted(name: "bash", source: nil, step: "Arbeite an deinem Mac", kind: .mac), request: request, at: at(Double(second)))
            line.apply(.toolEnded(name: "bash"), request: request, at: at(Double(second) + 0.5))
        }
        let merged = line.bubbles == [StepBubble(id: 0, text: "Suche in deinen Mails", kind: .mail, outcome: "3 Treffer"),
                                      StepBubble(id: 1, text: "Arbeite an deinem Mac", kind: .mac, count: 4)]
        // One grouping rule: with nothing running, the bubbles count exactly what WorkStep.merged counts.
        let sameRule = line.bubbles.map(\.count) == WorkStep.merged(line.steps).map { $0.repeats ?? 1 }
        let waiting = line.phase == .waitingForAnswer(continuing: false) && line.phaseNote == nil
        let slow = line.isSlow(at: at(10)) && !L("Taking a little longer, I’m on it.", table: "Thought").isEmpty
        line.textArrived(request: request)
        return quietAtStart && reading && running && merged && sameRule && waiting && slow && !line.isSlow(at: at(11))
    }

    check("Thought Line: receipt honestly names partial, no and names-only reading") {
        let partial = SourceReading(name: "Vertrag.pdf", status: .partial, pagesRead: 12, pageCount: 30, recognizedText: true)
        let folder = SourceReading(name: "Belege", status: .namesOnly)
        let selection = SourceReading(name: "Ausgewählter Text", isSelection: true, status: .read)
        let receipt = WorkReceipt(seconds: 7, sources: [partial, selection])
        let single = WorkReceipt(seconds: 3, sources: [partial])
        return partial.detail.contains(L("Pages 1–%lld of %lld read", table: "Thought", 12, 30))
            && partial.detail.contains(L("text recognized", table: "Thought"))
            && folder.detail == L("File names only", table: "Thought") && !folder.wasRead
            && selection.displayName == L("Selected text", table: "Thought")
            && receipt.summary == L("Read %lld sources, %lld only in part · %@", table: "Thought", 2, 1, WorkReceipt.duration(7))
            && single.summary == L("Read part of %@ · %@", table: "Thought", "Vertrag.pdf", WorkReceipt.duration(3))
    }

    check("Thought Line: reading the calendar (read_calendar) and source check are real phases") {
        let request = UUID()
        var line = ThoughtLine()
        line.begin(request, at: at(0))
        line.apply(.phase(.waitingForAnswer(continuing: false)), request: request, at: at(0.1))
        line.apply(.toolStarted(name: "read_calendar", source: nil), request: request, at: at(1))
        guard line.phase == .checkingCalendar, line.isVisible else { return false }
        line.apply(.toolEnded(name: "read_calendar"), request: request, at: at(2))
        line.apply(.phase(.writing), request: request, at: at(3))
        line.apply(.phase(.checkingSources), request: request, at: at(4))
        guard line.phase == .checkingSources, line.isVisible else { return false }
        let receipt = line.finish(request: request, at: at(5))
        return receipt?.checkedCalendar == true && receipt?.sources.isEmpty == true
            && receipt?.summary == L("Checked your calendar · %@", table: "Thought", WorkReceipt.duration(5))
    }

    check("Thought Line: receipt is kept in the conversation, older conversations without it stay readable") {
        let message = ConversationMessage(role: .assistant, text: "Antwort", work: WorkReceipt(seconds: 4, sources: [SourceReading(name: "a.pdf", status: .read)]))
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ConversationMessage.self, from: data)
        var legacy = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        legacy.removeValue(forKey: "work")
        let old = try JSONDecoder().decode(ConversationMessage.self, from: JSONSerialization.data(withJSONObject: legacy))
        return decoded == message && decoded.work?.sources.first?.name == "a.pdf" && old.work == nil
    }
}
