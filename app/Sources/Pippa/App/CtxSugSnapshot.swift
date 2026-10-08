import AppKit
import PippaCore

#if DEBUG
/// Records what the demo engine was asked, and lets a request wait until the fixture releases it.
private actor ChatLog {
    struct Request: Sendable { let text: String; let taskID: String; let files: [String]; let focused: [String] }
    private(set) var requests: [Request] = []
    private var gate: CheckedContinuation<String?, Never>?
    private var holdNext = false
    func record(_ text: String, _ taskID: String, _ context: ChatContext) {
        requests.append(Request(text: text, taskID: taskID, files: context.files.map(\.lastPathComponent),
                                focused: context.focusedFiles.map(\.lastPathComponent)))
    }
    func hold() { holdNext = true }
    var waiting: Bool { gate != nil }
    /// Returns nil for the stub's normal answer, or the text passed to `release`.
    func answer() async -> String? {
        guard holdNext else { return nil }
        holdNext = false
        return await withCheckedContinuation { gate = $0 }
    }
    func release(_ text: String?) { gate?.resume(returning: text); gate = nil }
}

/// Times and roles for the injected suggestion classifier (keyed by file name).
private final class ClassifierScript: @unchecked Sendable {
    private let lock = NSLock()
    private var plan: [String: (seconds: Double, role: DocumentRole)] = [:]
    private var cancelled: Set<String> = []
    private var finished: Set<String> = []
    func set(_ name: String, after seconds: Double, _ role: DocumentRole) { lock.withLock { plan[name] = (seconds, role) } }
    func wasCancelled(_ name: String) -> Bool { lock.withLock { cancelled.contains(name) } }
    func didFinish(_ name: String) -> Bool { lock.withLock { finished.contains(name) } }
    func classify(_ urls: [URL]) async -> DocumentRole {
        let name = urls.first?.lastPathComponent ?? ""
        let step = lock.withLock { plan[name] } ?? (0, .unknown)
        do { try await Task.sleep(for: .seconds(step.seconds)) } catch {
            lock.withLock { _ = cancelled.insert(name) }
            return .unknown
        }
        lock.withLock { _ = finished.insert(name) }
        return step.role
    }
}

/// `PIPPA_DEMO=1 PIPPA_SNAPSHOT=<dir> PIPPA_SNAPSHOT_ONLY=ctxsug`: topic/source switches and late suggestion
/// results through the production Give → tray → hand-over → conversation path. Writes `ctxsug.txt` and screenshots.
@MainActor enum CtxSugSnapshot {
    static func run(model: AppModel, shell: ShellController, directory: URL) async {
        var lines: [String] = []
        var failures = 0
        func verify(_ condition: Bool, _ id: String, _ description: String) {
            lines.append("\(condition ? "PASS" : "FAIL") [\(id)] \(description)")
            if !condition { failures += 1 }
        }
        func note(_ text: String) { lines.append("     " + text) }
        func finish() {
            let head = failures == 0 ? "PASS: ctxsug fixture" : "FAIL: ctxsug fixture (\(failures) failed)"
            try? (head + "\n" + lines.joined(separator: "\n") + "\n").write(to: directory.appendingPathComponent("ctxsug.txt"), atomically: true, encoding: .utf8)
        }
        guard model.engine is StubEngine, !PiRPCChat.isLive, DevSnapshot.directory?.standardizedFileURL == directory.standardizedFileURL else {
            verify(false, "setup", "Requires PIPPA_DEMO=1 and an isolated PIPPA_SNAPSHOT directory")
            finish(); return
        }
        NSApp.activate()
        let log = ChatLog()
        SnapshotChat.shared.script = { text, taskID, context, onDelta in
            await log.record(text, taskID, context)
            guard let answer = await log.answer() else { return nil }
            onDelta(answer)
            return answer
        }
        SnapshotChat.shared.onCancel = { await log.release(nil) }
        let script = ClassifierScript()
        model.tray.classify = { await script.classify($0) }

        let files = directory.appendingPathComponent("fixtures", isDirectory: true)
        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        func text(_ name: String, _ body: String) -> URL {
            let url = files.appendingPathComponent(name)
            try? body.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        func pdf(_ name: String, _ body: String) -> URL {
            let url = files.appendingPathComponent(name)
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 595, height: 842))
            view.string = body
            try? view.dataWithPDF(inside: view.bounds).write(to: url)
            return url
        }
        func snap(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(700))
            capture(shell, to: directory.appendingPathComponent(name + ".png"))
        }
        func settle(_ seconds: Double = 5) async -> Bool {
            for _ in 0..<Int(seconds * 50) {
                if !model.isActiveWork && !model.tray.isWorking { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        func clearTray() {
            model.collapse()
            for item in model.tray.items { model.tray.remove(item.id) }
        }
        func give(_ urls: [URL]) {
            if model.mode.isConversation || model.mode.key == "resume" { model.collapse() }
            model.receive(.files(urls), items: urls, startsFresh: true)
        }
        func ids() -> [String] { model.tray.offered.map(\.id) }
        /// Samples the visible offer for `seconds`; returns every distinct offer seen.
        func watch(_ seconds: Double) async -> [[String]] {
            var seen: [[String]] = [ids()]
            for _ in 0..<Int(seconds * 20) {
                try? await Task.sleep(for: .milliseconds(50))
                if ids() != seen.last { seen.append(ids()) }
            }
            return seen
        }

        let letterA = pdf("Brief Vermieter.pdf", "Hausverwaltung Beispiel GmbH\nSehr geehrte Frau Mustermann,\nbitte teilen Sie uns bis zum 14.10.2026 mit, ob Sie am 21.10. anwesend sind.\nMit freundlichen Grüßen")
        let letterB = pdf("Brief Krankenkasse.pdf", "Gesundheitskasse Beispiel\nBitte senden Sie uns die Schulbescheinigung bis zum 31.10.2026.")
        let sheet = files.appendingPathComponent("Nebenkosten.xlsx")
        try? Data("PK".utf8).write(to: sheet)
        let strategy = text("Strategie.md", "# Strategie 2030\nSynthetische Bauunternehmensstrategie: Wachstum in Sanierung, zwei neue Standorte.")
        let report = text("Underdog-Report.md", "# Underdog\nSynthetischer Vergleich von Desktop-Assistenten mit Quellenangaben.")
        let notes = text("Notizen Vergleich.md", "# Notizen\nErgänzende synthetische Notizen zum Underdog-Vergleich.")
        let neighbour = text("Nachricht Nachbarin.txt", "Liebe Frau Mustermann, ich habe ein Paket für Sie angenommen. Wann passt es Ihnen?")

        // MARK: Suggestions: late model results
        model.newConversation()
        clearTray()

        // seq-timely
        script.set(letterA.lastPathComponent, after: 0.6, .correspondence)
        give([letterA])
        let firstOffer = ids()
        verify(model.mode.key == "line" && firstOffer.isEmpty, "seq-timely", "A lone letter has no type-based offer, the role refines it later: \(firstOffer)")
        await snap("ctxsug-01-first-offer")
        let timely = await watch(1.4)
        // Since "Drehen" was removed, the first offer is empty; the role can already arrive during the screenshot.
        // Checked: exactly one non-empty state, and it is the role offer (no intermediate state).
        verify(timely.last == ["brief-verstehen", "antwort-schreiben"] && timely.filter { !$0.isEmpty }.count == 1,
               "seq-timely", "Model role replaces the offer once, in place: \(timely)")
        await snap("ctxsug-02-refined-offer")
        clearTray()

        // seq-late-after-choice
        script.set(letterB.lastPathComponent, after: 1.5, .correspondence)
        let topicBefore = model.conversations.current?.id
        give([letterB, letterA])
        try? await Task.sleep(for: .milliseconds(200))
        if let combine = model.tray.offered.first(where: { $0.id == "make-one-pdf" }) { model.tray.choose(combine) }
        let afterChoice = await watch(2.2)
        verify(!afterChoice.joined().contains("brief-verstehen") && !afterChoice.joined().contains("antwort-schreiben"),
               "seq-late-after-choice", "Late role after a click never appears: \(afterChoice)")
        _ = await settle()
        verify(model.conversations.current?.id == topicBefore, "seq-late-after-choice", "A tool click starts no conversation")
        if case .result = model.tray.phase { verify(true, "seq-late-after-choice", "Chosen Make one PDF produced its result") }
        else { verify(false, "seq-late-after-choice", "Chosen Make one PDF produced no result: \(model.tray.phase)") }
        clearTray()

        // seq-late-after-switch
        script.set(letterA.lastPathComponent, after: 1.5, .correspondence)
        give([letterA])
        try? await Task.sleep(for: .milliseconds(200))
        if let item = model.tray.givenItems.first { model.tray.remove(item.id) }
        give([sheet])
        let afterSwitch = await watch(2.0)
        verify(afterSwitch.allSatisfy { $0 == ["tabelle-pruefen"] }, "seq-late-after-switch", "Letter A's late role never reaches the sheet: \(afterSwitch)")
        verify(script.wasCancelled(letterA.lastPathComponent), "seq-late-after-switch", "Refinement for the removed letter was cancelled")
        clearTray()

        // seq-late-after-add
        script.set(letterA.lastPathComponent, after: 1.5, .correspondence)
        give([letterA])
        try? await Task.sleep(for: .milliseconds(200))
        give([letterB])
        let afterAdd = await watch(2.0)
        verify(afterAdd.allSatisfy { $0 == ["make-one-pdf"] }, "seq-late-after-add", "Two letters keep the combined offer: \(afterAdd)")
        clearTray()

        // seq-typing
        script.set(letterA.lastPathComponent, after: 1.0, .correspondence)
        give([letterA])
        try? await Task.sleep(for: .milliseconds(200))
        model.tray.draft = "Was will die Hausverwaltung"
        let typing = await watch(1.5)
        verify(typing.allSatisfy { $0.isEmpty }, "seq-typing", "Typing freezes the offer: \(typing)")
        model.tray.draft = ""
        clearTray()

        // seq-deadline (own file: other sequences already finished or cancelled letter A)
        let slowLetter = pdf("Brief langsam.pdf", "Stadtwerke Beispiel\nBitte bestätigen Sie den neuen Abschlag bis 25.10.2026.")
        script.set(slowLetter.lastPathComponent, after: 6.0, .correspondence)
        give([slowLetter])
        let slow = await watch(4.6)
        verify(slow.allSatisfy { $0.isEmpty } && script.wasCancelled(slowLetter.lastPathComponent) && !script.didFinish(slowLetter.lastPathComponent),
               "seq-deadline", "Refinement past 4 s is cancelled, the rules offer stays: \(slow)")
        clearTray()

        // MARK: Context: switches through the real conversation path
        script.set(strategy.lastPathComponent, after: 0, .report)
        script.set(report.lastPathComponent, after: 0, .report)
        script.set(neighbour.lastPathComponent, after: 0.1, .correspondence)

        // ctx-switch-unrelated
        give([strategy])
        model.tray.ask("Worum geht es in der Strategie?")
        _ = await settle()
        let t1 = model.conversations.current?.id
        var requests = await log.requests
        verify(requests.last?.files == ["Strategie.md"], "ctx-switch-unrelated", "First question sees only A: \(requests.last?.files ?? [])")
        give([report])
        verify(model.mode.key == "line" && model.conversations.current?.id == t1, "ctx-switch-unrelated", "Give B waits on the tray, topic unchanged until asked")
        model.tray.ask("Und worum geht es hier?")
        _ = await settle()
        let t2 = model.conversations.current?.id
        requests = await log.requests
        verify(t2 != nil && t2 != t1, "ctx-switch-unrelated", "Asking about B starts a new topic")
        verify(requests.last?.files == ["Underdog-Report.md"] && requests.last?.focused == ["Underdog-Report.md"],
               "ctx-switch-unrelated", "Engine sees only B: \(requests.last?.files ?? [])")
        verify(model.conversations.current?.messages.contains { $0.previousConversation == t1 } == true,
               "ctx-switch-unrelated", "New topic carries a way back to A")
        await snap("ctxsug-03-new-topic")

        // ctx-add-related (dropped into the open conversation)
        verify(model.mode.isConversation, "ctx-add-related", "Conversation is open after asking (mode \(model.mode.key))")
        model.receive(.files([notes]), items: [notes], startsFresh: true)
        verify(model.conversations.current?.id == t2 && model.conversations.current?.context?.files == [report, notes]
               && model.conversations.current?.context?.focusedFiles == [notes], "ctx-add-related", "Related drop joins the open topic with focus on C")
        model.route("Vergleiche den Bericht mit den Notizen.")
        _ = await settle()
        requests = await log.requests
        let taskBeforeRemoval = requests.last?.taskID
        verify(requests.last?.files == ["Underdog-Report.md", "Notizen Vergleich.md"] && requests.last?.focused == ["Notizen Vergleich.md"],
               "ctx-add-related", "Engine sees B and C, focus C: \(requests.last?.files ?? []) / \(requests.last?.focused ?? [])")
        await snap("ctxsug-04-related-added")

        // ctx-remove-readd
        model.removeConversationAttachment(notes)
        verify(model.conversations.current?.context?.files == [report], "ctx-remove-readd", "Removing C leaves only B")
        model.route("Was steht jetzt noch drin?")
        _ = await settle()
        requests = await log.requests
        verify(requests.last?.files == ["Underdog-Report.md"] && requests.last?.taskID != taskBeforeRemoval,
               "ctx-remove-readd", "Engine sees only B in a fresh model session: \(requests.last?.files ?? [])")
        model.receive(.files([notes]), items: [notes], startsFresh: true)
        verify(model.conversations.current?.id == t2 && model.conversations.current?.context?.files == [report, notes],
               "ctx-remove-readd", "Dropping C again re-adds it to the same topic")

        // ctx-busy-give
        await log.hold()
        model.route("Fasse alles ausführlich zusammen.")
        for _ in 0..<100 where !(await log.waiting) { try? await Task.sleep(for: .milliseconds(20)) }
        verify(model.isActiveWork, "ctx-busy-give", "Answer for T2 is running")
        model.collapse()
        model.receive(.files([neighbour]), items: [neighbour], startsFresh: true)
        try? await Task.sleep(for: .milliseconds(400))
        verify(model.tray.givenItems.map(\.url.lastPathComponent) == ["Nachricht Nachbarin.txt"]
               && model.conversations.current?.context?.files.contains(neighbour) == false,
               "ctx-busy-give", "Give during an answer lands on the tray, not in the running topic")
        let busyOffer = model.tray.offered
        let busySkills = busyOffer.filter { if case .skill = $0.handler { return true } else { return false } }
        note("offer while busy: \(busyOffer.map(\.id)); choosable: \(busyOffer.map { model.tray.canChoose($0) })")
        verify(!busySkills.isEmpty && busySkills.allSatisfy { !model.tray.canChoose($0) },
               "ctx-busy-give", "Actions that need the conversation are shown unavailable while Pippa answers")
        await snap("ctxsug-05-busy-line")
        if let action = busySkills.first { model.tray.choose(action) }
        verify(model.conversations.current?.id == t2 && model.tray.givenItems.count == 1,
               "ctx-busy-give", "A click while busy changes neither topic nor tray")
        await log.release("Antwort zu T2 nach der Wartezeit.")
        _ = await settle()
        let t2Answer = model.conversations.current?.messages.last
        verify(model.conversations.current?.id == t2 && t2Answer?.role == .assistant && t2Answer?.text == "Antwort zu T2 nach der Wartezeit.",
               "ctx-busy-give", "The held answer lands in T2")
        if model.mode.isConversation { model.collapse() }
        model.openLine()
        model.tray.ask("Was möchte die Nachbarin?")
        _ = await settle()
        let t3 = model.conversations.current?.id
        requests = await log.requests
        verify(t3 != t2 && requests.last?.files == ["Nachricht Nachbarin.txt"], "ctx-busy-give", "Asking about D afterwards starts its own topic with only D")

        // ctx-stop-switch
        await log.hold()
        model.route("Schreib eine lange Antwort.")
        for _ in 0..<100 where !(await log.waiting) { try? await Task.sleep(for: .milliseconds(20)) }
        model.stopChat()
        let settled = await settle(6)
        model.newConversation()
        let t4 = model.conversations.current?.id
        await log.release("LATE_AFTER_STOP")
        try? await Task.sleep(for: .milliseconds(200))
        verify(settled && t4 != t3 && model.conversations.current?.messages.isEmpty == true,
               "ctx-stop-switch", "Stop settles and the new topic starts empty")
        model.selectConversation(t3!)
        verify(model.conversations.current?.messages.allSatisfy { !$0.text.contains("LATE_AFTER_STOP") } == true,
               "ctx-stop-switch", "Late text after Stop is not stored as an answer in T3")

        // ctx-reopen
        model.collapse()
        model.recordConversationActivity(at: Date().addingTimeInterval(-9 * 60))
        model.openConversationFromPill()
        verify(model.mode.isConversation && model.conversations.current?.id == t3, "ctx-reopen", "Reopen after 9 min shows the same chat")
        model.collapse()
        model.recordConversationActivity(at: Date().addingTimeInterval(-11 * 60))
        model.openConversationFromPill()
        verify(model.mode.key == "resume" && model.conversations.current?.id == t3, "ctx-reopen", "Reopen after 11 min shows the compact topic line")
        await snap("ctxsug-06-resume")
        model.receive(.files([letterB]), items: [letterB], startsFresh: true)
        note("drop in compact resume: topic \(model.conversations.current?.id == t3 ? "kept" : "changed"), sources \(model.conversations.current?.context?.files.map(\.lastPathComponent) ?? [])")
        verify(model.conversations.current?.id == t3 && model.conversations.current?.context?.files.contains(letterB) == true,
               "ctx-reopen", "A drop on the compact topic line explicitly adds to that topic")
        model.newConversation()
        verify(model.conversations.current?.id != t3 && model.conversations.current?.context == nil && model.conversations.current?.messages.isEmpty == true,
               "ctx-reopen", "New Topic starts without old sources")

        // ctx-back-to-previous
        give([strategy])
        model.tray.ask("Kurz: Ziele?")
        _ = await settle()
        let x = model.conversations.current?.id
        give([report])
        model.tray.ask("Passt der Bericht dazu?")
        _ = await settle()
        let y = model.conversations.current?.id
        verify(x != y, "ctx-back-to-previous", "Second Give after a question starts a new topic")
        if let x { model.continueInPrevious(x) }
        verify(model.conversations.current?.id == x && model.conversations.current?.context?.files == [strategy, report],
               "ctx-back-to-previous", "Back to previous brings the new file into the old topic: \(model.conversations.current?.context?.files.map(\.lastPathComponent) ?? [])")
        verify(model.conversations.history.contains { $0.id == y }, "ctx-back-to-previous", "The topic with its own question stays in history")
        await snap("ctxsug-07-back-to-previous")

        let all = await log.requests
        note("engine requests: " + all.map { "\($0.text.prefix(24))→\($0.files)" }.joined(separator: " | "))
        finish()
    }

    @discardableResult
    private static func capture(_ shell: ShellController, to destination: URL) -> Bool {
        let window = shell.panel
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("ctxsug-window-\(UUID().uuidString).png")
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
