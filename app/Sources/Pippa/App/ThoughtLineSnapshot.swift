import AppKit
import CoreText
import PippaCore

#if DEBUG
/// Holds the engine at named points so the fixture can photograph each real phase. Reading pauses are synchronous
/// (they sit inside the real host reader's callback); later pauses are async continuations.
private final class PhaseGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var holding: String?
    private var released: Set<String> = []
    private var pending: [String: CheckedContinuation<Void, Never>] = [:]

    var current: String? { condition.lock(); defer { condition.unlock() }; return holding }

    /// Blocks the calling (reader) thread until `release(name)`; at most 8 s so a broken fixture never hangs.
    func holdSync(_ name: String) {
        condition.lock()
        holding = name
        let deadline = Date().addingTimeInterval(8)
        while !released.contains(name), condition.wait(until: deadline) {}
        holding = nil
        condition.unlock()
    }

    func hold(_ name: String) async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if released.contains(name) { condition.unlock(); continuation.resume(); return }
            holding = name
            pending[name] = continuation
            condition.unlock()
        }
    }

    func release(_ name: String) {
        condition.lock()
        released.insert(name)
        if holding == name { holding = nil }
        let continuation = pending.removeValue(forKey: name)
        condition.broadcast()
        condition.unlock()
        continuation?.resume()
    }

    func releaseAll() {
        condition.lock()
        let waiting = Array(pending.values)
        pending.removeAll()
        released.formUnion(["read", "ocr", "waiting", "searching", "looking", "writing", "again", "continuing", "stop-wait"])
        holding = nil
        condition.broadcast()
        condition.unlock()
        waiting.forEach { $0.resume() }
    }
}

/// Runs the real host reader on the attached files, then real-shaped Pi events, pausing for the camera.
/// After Stop it fires late events on purpose: the controller must drop them.
private actor ThoughtScript {
    let gate: PhaseGate
    var stopScenario = false
    private var late: (work: WorkEventHandler?, delta: (@Sendable (String) -> Void)?) = (nil, nil)
    private(set) var cancelled = false
    init(gate: PhaseGate) { self.gate = gate }
    func setStopScenario(_ value: Bool) { stopScenario = value; cancelled = false }

    func respond(_ context: ChatContext, onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        let work = context.onWork
        late = (work, onDelta)
        if stopScenario {
            work?(.phase(.reading(name: context.files.first?.lastPathComponent ?? "", index: 1, count: max(1, context.files.count))))
            await gate.hold("stop-wait")
            return "FULL_RETURN_AFTER_STOP"
        }
        // The real host reader: its events reach the controller unchanged; two of them pause for a photo.
        var reading = context
        let gate = self.gate
        reading.onWork = { event in
            work?(event)
            // Each pause happens once: a released name passes straight through.
            if case .phase(.reading(let name, _, _)) = event, name.hasPrefix("Mietvertrag") { gate.holdSync("read") }
            if case .phase(.recognizing(_, let page, _)) = event, page == 2 { gate.holdSync("ocr") }
        }
        let snapshots = try await LocalEngine.snapshots(for: reading)
        work?(.phase(.choosingPassages))
        work?(.sources(snapshots.map { snapshot in
            let status: SourceReading.Status = switch snapshot.readStatus {
            case .readable: .read
            case .partial: .partial
            case .unreadable: .unreadable
            case .unavailable: .unavailable
            case .metadataOnly: .namesOnly
            }
            return SourceReading(name: snapshot.name, status: status)
        }))
        work?(.phase(.waitingForAnswer(continuing: false)))
        await gate.hold("waiting")
        // Pi searches with its own tools first: finished steps with results, as the host words them.
        for (step, outcome, kind, failed) in [("Suche .md-Dateien in deinem Benutzerordner", "3 Treffer", WorkStep.Kind.search, false),
                                              ("Suche mit Spotlight nach „Kaution“", "nichts gefunden", .search, false),
                                              ("Lese Kaution.pdf", "Datei nicht gefunden", .file, true),
                                              ("Schaue in Downloads nach", "12 Einträge", .search, false),
                                              ("Suche deine Mails nach „Kaution“", "1 Treffer", .mail, false)] {
            work?(.toolStarted(name: "bash", source: nil, step: step, kind: kind))
            work?(.toolEnded(name: "bash", outcome: outcome, failed: failed))
        }
        work?(.toolStarted(name: "bash", source: nil, step: "Suche „Miete“ in deinen Dokumenten", kind: .search))
        await gate.hold("searching")
        work?(.toolEnded(name: "bash", outcome: "2 Treffer"))
        work?(.toolStarted(name: "read_context", source: "Mietvertrag.pdf"))
        await gate.hold("looking")
        work?(.toolEnded(name: "read_context"))
        let first = "Laut **Mietvertrag** beträgt die Kaution drei Nettokaltmieten, also 2.340 Euro (§ 5, Seite 2)."
        onDelta(first)
        await gate.hold("writing")
        work?(.toolStarted(name: "read_context", source: "Nebenkosten 2025.md"))
        await gate.hold("again")
        work?(.toolEnded(name: "read_context"))
        await gate.hold("continuing")
        let rest = "\n\nDie Nebenkostenabrechnung 2025 erwähnt die Kaution nicht. Das Übergabeprotokoll konnte ich nur als Bild lesen; der Zählerstand darin ist erkannt, aber bitte prüfe ihn."
        onDelta(rest)
        return first + rest
    }

    func cancel() async {
        cancelled = true
        // A real stop takes a moment (the helper finishes its step); long enough to photograph "Stopping…".
        let gate = self.gate
        Task { try? await Task.sleep(for: .seconds(1.5)); gate.release("stop-wait") }
    }

    /// Late callbacks of a stopped or abandoned request.
    func fireLate() {
        late.work?(.toolStarted(name: "read_context", source: "Mietvertrag.pdf"))
        late.work?(.phase(.waitingForAnswer(continuing: false)))
        late.work?(.sources([SourceReading(name: "LATE.pdf", status: .read)]))
        late.delta?("LATE_DELTA")
    }
}

/// `PIPPA_DEMO=1 PIPPA_SNAPSHOT=<fresh dir> PIPPA_SNAPSHOT_ONLY=thoughtline`: the Thought Line through the real
/// conversation controller and the real host reader (synthetic files only). Writes `thoughtline.txt` and screenshots.
/// `PIPPA_SNAPSHOT_WIDTH=400`, `PIPPA_APPEARANCE=light|dark`, `PIPPA_REDUCE_MOTION=1` vary the surface.
@MainActor enum ThoughtLineSnapshot {
    static func run(model: AppModel, shell: ShellController, directory: URL) async {
        var lines: [String] = []
        var failures = 0
        func verify(_ condition: Bool, _ description: String) {
            lines.append("\(condition ? "PASS" : "FAIL"): \(description)")
            if !condition { failures += 1 }
        }
        func finish() {
            let head = failures == 0 ? "PASS: thoughtline fixture" : "FAIL: thoughtline fixture (\(failures) failed)"
            try? (head + "\n" + lines.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("thoughtline.txt"), atomically: true, encoding: .utf8)
        }
        guard model.engine is StubEngine, DevSnapshot.directory?.standardizedFileURL == directory.standardizedFileURL else {
            verify(false, "Requires PIPPA_DEMO=1 and an isolated PIPPA_SNAPSHOT directory")
            finish(); return
        }
        NSApp.activate()
        model.conversationSize = DevSnapshot.workspaceSize
        let width = Int(model.conversationSize.width)
        let appearance = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
        let tag = "\(width)-\(appearance)" + (MarkHub.shared.reduced ? "-reduced" : "")
        lines.append("     width \(width) pt, appearance \(appearance), reduce motion \(MarkHub.shared.reduced)")

        // Synthetic sources only, inside the snapshot directory.
        let files = directory.appendingPathComponent("sources", isDirectory: true)
        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let lease = files.appendingPathComponent("Mietvertrag.pdf")
        textPDF(["Mietvertrag (synthetisch)\n§ 5 Kaution: drei Nettokaltmieten, 2.340 Euro.", "Seite 2: Übergabe am 01.10.2026."], at: lease)
        let costs = files.appendingPathComponent("Nebenkosten 2025.md")
        try? "# Nebenkosten 2025 (synthetisch)\nHeizung 812 Euro, Wasser 240 Euro.".write(to: costs, atomically: true, encoding: .utf8)
        let scan = files.appendingPathComponent("Scan Übergabeprotokoll.pdf")
        scanPDF(pages: 2, at: scan)
        let photo = files.appendingPathComponent("Foto Zählerstand.heic")
        try? Data([0x00, 0x01, 0x02]).write(to: photo)   // not an image: honestly unreadable
        let sources = [lease, costs, scan, photo]

        let gate = PhaseGate()
        let engine = ThoughtScript(gate: gate)
        let scripted = SnapshotChat(script: { _, _, context, onDelta in try await engine.respond(context, onDelta: onDelta) },
                                    onCancel: { await engine.cancel() })
        let chat = model.conversations
        func snap(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(650))
            verify(capture(shell, to: directory.appendingPathComponent("thoughtline-\(tag)-\(name).png")), "Screenshot \(name)")
        }
        func waitFor(_ point: String, _ seconds: Double = 6) async -> Bool {
            for _ in 0..<Int(seconds * 50) {
                if gate.current == point { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        func settle(_ seconds: Double = 8) async -> Bool {
            for _ in 0..<Int(seconds * 50) {
                if !chat.isRunning { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        defer { gate.releaseAll() }

        model.newConversation()
        model.attach(.files(sources), items: sources, startsFresh: false, open: true)
        if !model.mode.isConversation { model.openInput() }
        chat.send("Wie hoch ist die Kaution, und steht sie auch in den anderen Unterlagen?", chat: scripted)
        verify(chat.isRunning && chat.thought.phase == .starting && chat.thought.isVisible, "Line appears at once with a calm start")

        // 1 Reading a file (real host reader, paused inside its callback).
        verify(await waitFor("read"), "Real reader reached Mietvertrag.pdf")
        try? await Task.sleep(for: .milliseconds(150))
        verify(chat.thought.phase == .reading(name: "Mietvertrag.pdf", index: 1, count: 4), "Phase: reading Mietvertrag.pdf 1 of 4 (\(String(describing: chat.thought.phase)))")
        verify(!chat.thought.showsElapsed(at: Date()), "No seconds before 2 s")
        await snap("01-reading")
        gate.release("read")

        // 2 Text recognition on page 2 of the scan; seconds now visible.
        verify(await waitFor("ocr", 150), "Real reader reached page 2 of the scan")
        try? await Task.sleep(for: .milliseconds(150))
        verify(chat.thought.phase == .recognizing(name: "Scan Übergabeprotokoll.pdf", page: 2, pages: 2), "Phase: recognizing page 2 of 2 (\(String(describing: chat.thought.phase)))")
        if let start = chat.thought.startedAt, Date().timeIntervalSince(start) < 2.2 { try? await Task.sleep(for: .seconds(2.2 - Date().timeIntervalSince(start))) }
        verify(chat.thought.showsElapsed(at: Date()), "Elapsed seconds shown after 2 s")
        await snap("02-recognizing")
        gate.release("ocr")

        // 3 Sent, waiting for the first words.
        verify(await waitFor("waiting", 150), "Engine reached waiting for the answer")
        try? await Task.sleep(for: .milliseconds(150))
        verify(chat.thought.phase == .waitingForAnswer(continuing: false), "Phase: preparing the answer")
        let facts = Dictionary(uniqueKeysWithValues: chat.thought.sources.map { ($0.name, $0) })
        verify(facts["Scan Übergabeprotokoll.pdf"]?.recognizedText == true && facts["Scan Übergabeprotokoll.pdf"]?.pagesRead == 2,
               "Real reader facts reached the controller (scan: 2 pages, text recognized)")
        verify(facts["Foto Zählerstand.heic"].map { !$0.wasRead } == true, "Unreadable photo is marked, not counted as read")
        await snap("03-waiting")
        gate.release("waiting")

        // 3b Pi's own tools: the running step is the detail, finished ones listed quietly below.
        verify(await waitFor("searching"), "Engine reached its own search tool")
        try? await Task.sleep(for: .milliseconds(150))
        verify(chat.thought.phase == .working && chat.thought.currentStep == "Suche „Miete“ in deinen Dokumenten", "Phase: working, current step shown")
        verify(chat.thought.recentSteps.shown.count == 4 && chat.thought.recentSteps.hidden == 1 && chat.thought.doneSteps.contains { $0.failed == true }, "Four finished steps listed, one folded, the failed one marked")
        await snap("03b-steps")
        gate.release("searching")

        // 4 Pi opens a source again: only the host's name is shown.
        verify(await waitFor("looking"), "Engine reached the source tool")
        try? await Task.sleep(for: .milliseconds(150))
        verify(chat.thought.phase == .lookingThrough(name: "Mietvertrag.pdf"), "Phase: looking in Mietvertrag.pdf")
        await snap("04-looking")
        gate.release("looking")

        // 5 Text streams: the line steps aside.
        verify(await waitFor("writing"), "Engine streamed first text")
        try? await Task.sleep(for: .milliseconds(200))
        verify(chat.thought.phase == .writing && !chat.thought.isVisible && !chat.streamingText.isEmpty, "Line hidden while text streams")
        await snap("05-writing")
        gate.release("writing")

        // 6 A tool after text: the line returns below the partial answer.
        verify(await waitFor("again"), "Engine opened a second source after text")
        try? await Task.sleep(for: .milliseconds(150))
        verify(chat.thought.phase == .lookingThrough(name: "Nebenkosten 2025.md") && chat.thought.isVisible, "Line returns below partial text for a real tool")
        await snap("06-looking-after-text")
        gate.release("again")
        verify(await waitFor("continuing"), "Engine continues")
        try? await Task.sleep(for: .milliseconds(150))
        verify(chat.thought.phase == .waitingForAnswer(continuing: true), "Phase: continuing the answer")
        gate.release("continuing")

        // 7 Finished: receipt, then details.
        verify(await settle(), "Answer finished")
        let answer = chat.current?.messages.last
        verify(answer?.role == .assistant && chat.thought.phase == nil && !chat.thought.isVisible, "No line after the answer")
        if let work = answer?.work {
            verify(work.sources.count == 4 && work.sources.filter(\.wasRead).count == 3, "Receipt: 3 of 4 sources read")
            verify(work.summary.contains("3") && work.summary.contains("4") && work.summary.hasSuffix(WorkReceipt.duration(work.seconds)), "Receipt summary: \(work.summary)")
            verify(work.sources.first { $0.name == "Mietvertrag.pdf" }?.openedWhileAnswering == true, "Receipt notes the source opened while answering")
            lines.append("     receipt: \(work.summary)")
            for source in work.sources { lines.append("       \(source.displayName): \(source.detail)") }
        } else { verify(false, "Answer carries a receipt") }
        await snap("07-receipt")
        if let id = answer?.id { chat.toggleReceipt(id) }
        await snap("08-receipt-details")

        // 8 Stop: "Stopping…", then nothing stale; late events after a topic switch are dropped.
        await engine.setStopScenario(true)
        chat.send("Und wann ist die Übergabe?", chat: scripted)
        try? await Task.sleep(for: .milliseconds(300))
        let wasRunning = chat.isRunning
        model.stopChat()
        verify(wasRunning && chat.thought.phase == .stopping, "Stop shows “Stopping” at once (\(String(describing: chat.thought.phase)))")
        await snap("09-stopping")
        verify(await settle(), "Stopped request settles")
        verify(chat.thought.phase == nil && !chat.thought.isVisible, "No phase left after Stop")
        await engine.fireLate()
        try? await Task.sleep(for: .milliseconds(200))
        let afterStop = chat.current?.messages ?? []
        verify(chat.thought.phase == nil && afterStop.allSatisfy { !$0.text.contains("LATE") && !$0.text.contains("FULL_RETURN") }
               && afterStop.last?.work == nil, "Late events after Stop are dropped; no receipt on a stopped answer")
        let stoppedTopic = chat.current?.id
        model.newConversation()
        await engine.fireLate()
        try? await Task.sleep(for: .milliseconds(200))
        verify(chat.current?.id != stoppedTopic && chat.current?.messages.isEmpty == true && chat.thought.phase == nil
               && chat.streamingText.isEmpty && !chat.isRunning, "Topic switch: late events reach no line in the new topic")
        await snap("10-new-topic")
        for url in sources { verify(FileManager.default.fileExists(atPath: url.path), "Source left in place: \(url.lastPathComponent)") }
        finish()
    }

    private static func textPDF(_ pages: [String], at url: URL) {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        for page in pages {
            ctx.beginPDFPage(nil)
            let text = NSAttributedString(string: page, attributes: [.font: NSFont.systemFont(ofSize: 12)])
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text), CFRange(location: 0, length: 0),
                                                 CGPath(rect: box.insetBy(dx: 50, dy: 50), transform: nil), nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// Image-only pages: the reader has to recognize text (OCR) on each.
    private static func scanPDF(pages: Int, at url: URL) {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        for page in 1...pages {
            ctx.beginPDFPage(nil)
            let size = NSSize(width: 600, height: 800)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.white.setFill(); rect.fill()
                ("Übergabeprotokoll Seite \(page)\nZählerstand 04711" as NSString).draw(at: NSPoint(x: 40, y: 700),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 36), .foregroundColor: NSColor.black])
                return true
            }
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) { ctx.draw(cg, in: box) }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    /// Captures only Pippa's current window (same approach as the other native fixtures).
    private static func capture(_ shell: ShellController, to destination: URL) -> Bool {
        let window = shell.panel
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("thoughtline-window-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", temporary.path]
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        var data: Data?
        do {
            try process.run()
            if done.wait(timeout: .now() + 4) == .timedOut { process.terminate() }
            data = try? Data(contentsOf: temporary)
        } catch {}
        if data == nil, let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        guard let data, let rep = NSBitmapImageRep(data: data), let image = rep.cgImage else { return false }
        let region = shell.shellScreenRect.insetBy(dx: -30, dy: -30)
            .offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
            .intersection(CGRect(origin: .zero, size: window.frame.size))
        let scale = CGFloat(image.width) / window.frame.width
        let pixels = CGRect(x: region.minX * scale, y: (window.frame.height - region.maxY) * scale,
                            width: region.width * scale, height: region.height * scale).integral
        guard let cropped = image.cropping(to: pixels),
              let png = NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: destination, options: .atomic); return true } catch { return false }
    }
}
#endif
