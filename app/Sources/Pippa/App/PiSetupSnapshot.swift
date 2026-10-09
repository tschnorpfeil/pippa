import AppKit
import ImageIO
import PippaCore

#if DEBUG
/// Setup in the real window.
///
/// `PIPPA_SNAPSHOT=<fresh folder> PIPPA_SNAPSHOT_ONLY=setup-<state>` with `welcome` (the only question),
/// `progress` (loading with examples), `adopted` (existing model adopted, no question), `error` (sentence,
/// "Nochmal versuchen", details), `done` ("Probier's aus") or `all`. Without installer and without network: the state is
/// set (`PiSetupController(flow: nil, state:)`). `PIPPA_APPEARANCE=light|dark`, `PIPPA_REDUCE_MOTION=1`.
///
/// `setup-e2e`: the real flow with `PIPPA_PI_RPC=1` and `PIPPA_PI_HOME=<fake HOME>` (scripts/pi-setup-ui.sh):
/// setup until "ready" (existing model is adopted), then a question to Pippa via the real Pi.
/// Report `setup.txt`, images `setup-*.png`.
@MainActor enum PiSetupSnapshot {
    static func run(model: AppModel, shell: ShellController, directory: URL, only: String) async {
        var lines: [String] = []
        var failures = 0
        let started = Date()
        func note(_ text: String) { lines.append(String(format: "[%6.1f s] ", Date().timeIntervalSince(started)) + text) }
        func verify(_ ok: Bool, _ what: String) { note("\(ok ? "PASS" : "FAIL"): \(what)"); if !ok { failures += 1 } }
        func snap(_ name: String, wait: Double = 0.9) async {
            try? await Task.sleep(for: .seconds(wait))
            let fits = shell.shellScreenRect.height >= shell.lastMeasuredHeight - 0.5
            let url = directory.appendingPathComponent("\(name).png")
            let ok = capture(shell.panel, to: url)
            // Only the shell with its shadow, not the whole (screen-wide) window.
            let panel = shell.panel.frame
            crop(url, to: shell.shellScreenRect.offsetBy(dx: -panel.minX, dy: -panel.minY).insetBy(dx: -24, dy: -24), in: panel.size)
            verify(ok && fits, "Bild \(name).png (\(Int(shell.panel.frame.width))×\(Int(shell.lastMeasuredHeight)) pt, Platz \(Int(shell.shellScreenRect.height)) pt)")
        }
        NSApp.activate()

        if only == "setup-e2e" {
            await endToEnd(model: model, note: note, verify: verify, snap: snap)
        } else if only == "setup-offline" {
            await offline(model: model, note: note, verify: verify, snap: snap)
        } else if only == "setup-download" {
            await download(model: model, note: note, verify: verify, snap: snap)
        } else {
            let fixtures: [(String, PiSetupState, Int, Bool)] = [
                ("setup-welcome", .askDownload(bytes: 6_716_356_800), 0, false),
                ("setup-progress", .downloading(progress: 0.42, remaining: 330), 0, false),
                ("setup-progress-example3", .downloading(progress: 0.81, remaining: 110), 2, false),
                ("setup-adopted", .preparing(adoptingFrom: "LM Studio"), 3, false),
                ("setup-adopted-ready", .ready(adoptedFrom: "LM Studio"), 0, false),
                ("setup-error", .failed(PiSetupProblem(.notEnoughSpace(bytes: 3_100_000_000))), 0, false),
                ("setup-error-details", .failed(PiSetupProblem(.notEnoughSpace(bytes: 3_100_000_000))), 0, true),
                ("setup-done", .ready(adoptedFrom: nil), 0, false),
            ]
            let wanted = only == "setup-all" ? fixtures : fixtures.filter { $0.0 == only || $0.0.hasPrefix(only + "-") }
            verify(!wanted.isEmpty, "Aufnahme \(only) bekannt")
            for (name, state, example, details) in wanted {
                let setup = PiSetupController(flow: nil, state: state)
                setup.exampleIndex = example
                setup.showsDetails = details
                PiSetupController.shared = setup
                setup.attach(to: model)
                model.show(.pill)
                try? await Task.sleep(for: .milliseconds(300))
                model.show(.onboarding)
                await snap(name)
            }
        }
        let heading = failures == 0 ? "PASS: \(only)" : "FAIL: \(only) (\(failures))"
        try? ([heading] + lines).joined(separator: "\n").appending("\n")
            .write(to: directory.appendingPathComponent("setup.txt"), atomically: true, encoding: .utf8)
    }

    /// Download that gets nowhere (`PIPPA_HF_ENDPOINT` pointing at a dead address, fake HOME without a model): the welcome,
    /// the settings line and the footer must say so within ~30 s, with "Try Again", instead of standing still silently.
    private static func offline(model: AppModel, note: (String) -> Void, verify: (Bool, String) -> Void,
                                snap: (String, Double) async -> Void) async {
        guard let setup = PiSetupController.shared, PiRPCChat.isLive else {
            verify(false, "braucht PIPPA_PI_RPC=1, PIPPA_PI_HOME=<leeres Fake-HOME> und PIPPA_HF_ENDPOINT=<tote Adresse>")
            return
        }
        model.show(.onboarding)
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 120 {
            if case .askDownload = setup.state { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard case .askDownload = setup.state else { return verify(false, "keine Download-Frage: \(setup.state)") }
        model.startModelDownload()
        model.collapse()   // "Keep loading in the background": the person no longer looks at the welcome
        let t1 = Date()
        while Date().timeIntervalSince(t1) < 60, !setup.stalled { try? await Task.sleep(for: .milliseconds(250)) }
        let after = Date().timeIntervalSince(t1)
        note(String(format: "Hängen erkannt nach %.1f s (Zustand: %@)", after, String(describing: setup.state)))
        verify(setup.stalled && after <= 35, "Hängen spätestens nach 35 s erkannt")
        verify(model.learningText == AppModel.offlineText, "Statuszeile (Einstellungen, Fußzeile): \(model.learningText ?? "–")")
        verify(model.downloadStalled, "Einstellungen und Menü bieten „Nochmal versuchen“")
        verify(model.toasts?.currentPanel != nil || model.mode.isExpanded, "zugeklappt: Meldung mit „Nochmal versuchen“")
        verify(model.markState == .fehler, "Zeichen zeigt ein Problem, kein grünes Lächeln (\(model.markState))")
        model.show(.onboarding)
        try? await Task.sleep(for: .milliseconds(600))
        verify(model.toasts?.currentPanel == nil, "Fenster wieder offen: Meldung verschwindet, nichts überlappt")
        await snap("setup-offline-01-welcome", 0.9)
        model.retryDownloadNow()
        try? await Task.sleep(for: .seconds(1))
        verify(!setup.stalled, "„Nochmal versuchen“ startet neu")
        if case .downloading = setup.state { verify(true, "lädt wieder") } else { verify(false, "nach Neustart: \(setup.state)") }
        while Date().timeIntervalSince(t1) < 120, !setup.stalled { try? await Task.sleep(for: .milliseconds(250)) }
        verify(setup.stalled, "nach Neustart wieder als hängend erkannt")
    }

    /// Real first download in a fake HOME without a model: question, "Laden", progress, ready. Logs progress every 15 s.
    private static func download(model: AppModel, note: (String) -> Void, verify: (Bool, String) -> Void,
                                 snap: (String, Double) async -> Void) async {
        guard let setup = PiSetupController.shared, PiRPCChat.isLive else {
            verify(false, "braucht PIPPA_PI_RPC=1 und PIPPA_PI_HOME=<leeres Fake-HOME>")
            return
        }
        model.show(.onboarding)
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 120 {
            if case .askDownload = setup.state { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard case .askDownload(let bytes) = setup.state else { return verify(false, "keine Download-Frage: \(setup.state)") }
        note("Frage: \(ModelDownloadSize.gigabytes(bytes))")
        await snap("setup-download-01-question", 0.6)
        model.startModelDownload()
        let t1 = Date()
        var lastLog = Date.distantPast, shotTaken = false, stalls = 0, wasStalled = false
        while Date().timeIntervalSince(t1) < 3600 {
            if setup.stalled != wasStalled { wasStalled = setup.stalled; if wasStalled { stalls += 1; note("hängt (Netz?)") } else { note("läuft wieder") } }
            if case .downloading(let p, let r) = setup.state {
                if Date().timeIntervalSince(lastLog) >= 15 {
                    lastLog = Date()
                    let el = Date().timeIntervalSince(t1)
                    note(String(format: "%.1f %% nach %.0f s, %.1f MB/s, Rest %@", p * 100, el, Double(bytes) * p / el / 1e6,
                                r.map { String(format: "%.0f s", $0) } ?? "–"))
                }
                if p > 0.02, !shotTaken { shotTaken = true; await snap("setup-download-02-progress", 0.3) }
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            if case .preparing = setup.state { try? await Task.sleep(for: .milliseconds(200)); continue }
            break
        }
        let total = Date().timeIntervalSince(t1)
        note(String(format: "Ende nach %.0f s (%.1f MB/s im Schnitt), Hänger: %d, Zustand: %@", total, Double(bytes) / total / 1e6, stalls,
                    String(describing: setup.state)))
        if case .ready = setup.state { verify(true, "KI geladen und bereit") } else { verify(false, "nicht bereit: \(setup.state)") }
        verify(model.learningText == nil, "keine Statuszeile mehr (\(model.learningText ?? "–"))")
        model.show(.onboarding)
        await snap("setup-download-03-ready", 0.9)
    }

    /// Real flow in a fake HOME: set up quietly (adopt without a question), then an answer via the real Pi.
    private static func endToEnd(model: AppModel, note: (String) -> Void, verify: (Bool, String) -> Void,
                                 snap: (String, Double) async -> Void) async {
        guard let setup = PiSetupController.shared, PiRPCChat.isLive else {
            verify(false, "braucht PIPPA_PI_RPC=1 (und die Umgebung aus scripts/pi-setup-ui.sh)")
            return
        }
        model.show(.onboarding)
        let t0 = Date()
        var states: [String] = []
        var adoptedShot = false
        while Date().timeIntervalSince(t0) < 600 {
            let label = String(describing: setup.state)
            if states.last != label { states.append(label); note("Zustand: \(label)") }
            if case .preparing(.some) = setup.state, !adoptedShot { adoptedShot = true; await snap("setup-e2e-01-adopting", 0.4) }
            switch setup.state {
            case .preparing, .downloading: try? await Task.sleep(for: .milliseconds(100)); continue
            default: break
            }
            break
        }
        note(String(format: "Einrichtung fertig nach %.1f s", Date().timeIntervalSince(t0)))
        verify(!states.contains { $0.hasPrefix("askDownload") }, "keine Frage gestellt (vorhandenes Modell)")
        guard case .ready(let source) = setup.state else {
            await snap("setup-e2e-02-failed", 0.6)
            verify(false, "Einrichtung nicht bereit: \(setup.state)")
            return
        }
        verify(source != nil, "KI übernommen aus \(source ?? "–")")
        await snap("setup-e2e-02-ready", 0.9)

        // A real question to Pippa (Pi via RPC, the app's llama-server with the adopted model).
        model.conversationSize = DevSnapshot.workspaceSize
        model.newConversation()
        try? await Task.sleep(for: .milliseconds(400))
        let question = "Antworte in einem kurzen Satz auf Deutsch: Wie heißt die Hauptstadt von Frankreich?"
        note("Frage: \(question)")
        let a0 = Date()
        model.route(question)
        var first: Double?
        try? await Task.sleep(for: .milliseconds(200))
        while model.conversations.isRunning, Date().timeIntervalSince(a0) < 600 {
            if first == nil, !model.conversations.streamingText.isEmpty { first = Date().timeIntervalSince(a0) }
            try? await Task.sleep(for: .milliseconds(50))
        }
        note(String(format: "erster Text nach %@, fertig nach %.1f s", first.map { String(format: "%.1f s", $0) } ?? "–", Date().timeIntervalSince(a0)))
        let answer = model.conversations.current?.messages.last { $0.role == .assistant }?.text ?? ""
        note("Antwort: \(answer.replacingOccurrences(of: "\n", with: " ⏎ "))")
        if let error = model.conversations.error { note("Fehler: \(error)") }
        verify(answer.localizedCaseInsensitiveContains("Paris"), "Pippa antwortet (Paris)")
        do {
            let status = await PiRPCChat.shared.localServerStatus()
            note("llama-server der App: PID \(status.pid.map(String.init) ?? "–"), Start bis /health \(status.lastStart.map { String(format: "%.1f s", $0) } ?? "–")")
        }
        await snap("setup-e2e-03-answer", 0.6)
    }

    /// Crops a window image to `rect` (points in the window, origin bottom left).
    private static func crop(_ url: URL, to rect: CGRect, in size: CGSize) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil), size.width > 0 else { return }
        let scale = CGFloat(image.width) / size.width
        let flipped = CGRect(x: rect.minX * scale, y: (size.height - rect.maxY) * scale, width: rect.width * scale, height: rect.height * scale)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard !flipped.isEmpty, let cropped = image.cropping(to: flipped),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, cropped, nil)
        CGImageDestinationFinalize(destination)
    }

    @discardableResult
    private static func capture(_ window: NSWindow, to destination: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", destination.path]
        do { try process.run(); process.waitUntilExit() } catch {}
        if FileManager.default.fileExists(atPath: destination.path) { return true }
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: destination)) != nil
    }
}
#endif
