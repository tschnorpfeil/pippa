import AppKit
import PippaCore
import PDFKit
import SwiftUI

/// Developer aid: `PIPPA_DEMO=1 PIPPA_SNAPSHOT=/path Pippa` plays the flows through with the
/// sample engine, photographs the real window (with alpha, via `screencapture -l`)
/// and saves one PNG per form, plus frame sequences of every morph (in slow motion) and a
/// check of the corners (`corners.txt`). `PIPPA_APPEARANCE=dark|light` forces the appearance.
/// `PIPPA_SNAPSHOT_ONLY=morph|states|pillstatus|workspace|chat|natural|keyboard|byom|settings|firstrun|welcome|setup-*` restricts the run. Exits afterwards.
/// `setup-*`: setup without technical questions (PiSetupSnapshot).
/// `firstrun` and `welcome` need `PIPPA_DEMO_MODEL=missing` (sample engine without knowledge, as on first launch);
/// `welcome` additionally without consent to download (`-model.download.allowed NO` as an argument), best with `PIPPA_SNAPSHOT_HEIGHT=700`.
/// `contextstop` needs `PIPPA_DEMO=1`: controlled stop/callback race through the real conversation controller; report `contextstop.txt`.
///
/// Debug build only (`swift run Pippa`, `swift build`): the release build from `scripts/build-app.sh`
/// (`-c release`) knows neither the captures nor the developer environment variables.
enum DevEnvironment {
    /// Developer switches from the environment (`PIPPA_SNAPSHOT`, `PIPPA_ONBOARDING` …); always `nil` in release.
    static func value(_ key: String) -> String? {
        #if DEBUG
        ProcessInfo.processInfo.environment[key]
        #else
        nil
        #endif
    }
}

#if !DEBUG
@MainActor
enum DevSnapshot {
    static var directory: URL? { nil }
    static var workspaceSize: CGSize { ShellTokens.workspaceMax }
    static var testsKeyboard: Bool { false }
    static func run(model: AppModel, shell: ShellController) {}
}
#else
/// Deliberately returns success after cancel and delivers late callbacks. This
/// tests the real controller boundary without a model or external application.
@MainActor
private final class StopRaceChat: ConversationChat {
    private let prefix: String
    private var completion: CheckedContinuation<String, Never>?
    private var delta: (@Sendable (String) -> Void)?
    private var reset: (@Sendable (String) -> Void)?
    private var steered: (@Sendable (String) -> Void)?
    var waiting: Bool { completion != nil }
    init(prefix: String) { self.prefix = prefix }
    func answer(_ text: String, taskID: String, context: ChatContext, newFiles: [URL], skill: PippaSkill?, draftOnly: Bool,
                onDelta: @escaping @Sendable (String) -> Void, onSteered: @escaping @Sendable (String) -> Void,
                onReset: (@Sendable (String) -> Void)?) async throws -> PiRPCChat.ShownAnswer {
        delta = onDelta; reset = onReset; steered = onSteered
        onDelta(prefix)
        let text = await withCheckedContinuation { completion = $0 }
        return PiRPCChat.ShownAnswer(text: text, reviewed: false)
    }
    func lateCallbacks() {
        delta?("LATE_DELTA")
        reset?("LATE_RESET")
        steered?("LATE_STEERED")
    }
    func steer(_ text: String) async -> Bool { false }
    func cancel() async {
        lateCallbacks()
        completion?.resume(returning: "FULL_RETURN_AFTER_STOP")
        completion = nil
    }
    func forget(_ keys: [String]) async {}
    func takeShownActions() -> ActionReceipt? { nil }
}

@MainActor
enum DevSnapshot {
    static var directory: URL? {
        DevEnvironment.value("PIPPA_SNAPSHOT").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Test the real window at smaller widths (`PIPPA_SNAPSHOT_WIDTH`) or on a low screen (`PIPPA_SNAPSHOT_HEIGHT`,
    /// e.g. 700 for a 13-inch MacBook) without changing production placement.
    static var workspaceSize: CGSize {
        guard directory != nil else { return ShellTokens.workspaceMax }
        let env = ProcessInfo.processInfo.environment
        var size = ShellTokens.workspaceMax
        if let raw = env["PIPPA_SNAPSHOT_WIDTH"], let width = Double(raw), width.isFinite, width >= 400, width <= Double(ShellTokens.workspaceMax.width) {
            size.width = width
        }
        if let raw = env["PIPPA_SNAPSHOT_HEIGHT"], let height = Double(raw), height.isFinite, height >= 400 {
            size.height = min(size.height, height)
        }
        return size
    }

    static var testsKeyboard: Bool {
        directory != nil && ProcessInfo.processInfo.environment["PIPPA_SNAPSHOT_ONLY"] == "keyboard"
    }

    private static var cornerReport: [String] = []
    private static var timingReport: [String] = []

    static func run(model: AppModel, shell: ShellController) {
        guard let dir = directory else { return }
        let env = ProcessInfo.processInfo.environment
        switch env["PIPPA_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        let only = env["PIPPA_SNAPSHOT_ONLY"]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        marks(to: dir)
        if !model.pillVisible { model.pillVisible = true }
        Task { @MainActor in
            @MainActor func snap(_ name: String, wait: Double = 0.9) async {
                try? await Task.sleep(for: .seconds(wait))
                capture(shell, name: name, to: dir.appendingPathComponent("\(name).png"), checkCorners: true)
            }
            model.start()
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            try? await Task.sleep(for: .seconds(1.0))

            if only == "conversationresume" {
                await ConversationResumeSnapshot.run(model: model, shell: shell, directory: dir)
                NSApp.terminate(nil)
                return
            }

            // Simplified settings (docs/settings-simplification.md): once without, once with a custom online service.
            // No key, no test, nothing goes out; the settings file is in the capture folder.
            if only == "settings" {
                @MainActor func grabSettings(_ name: String) async {
                    let settings = SettingsWindowController(model: model)
                    settings.show()
                    try? await Task.sleep(for: .seconds(1.0))
                    if let window = settings.window, let data = grabWindow(window),
                       let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage {
                        writePNG(cg, to: dir.appendingPathComponent("\(name).png"))
                    }
                    settings.window?.close()
                }
                try? model.saveInferenceSettings(.init(policy: .localOnly, connection: nil))
                await grabSettings("settings-01-local")
                try? model.saveInferenceSettings(.init(policy: .ask, connection: ModelConnection(provider: .openAI, modelID: "gpt-example")))
                await grabSettings("settings-02-online")
                NSApp.terminate(nil)
                return
            }

            if only == "pillstatus" {
                await PillStatusSnapshot.run(model: model, shell: shell, directory: dir)
                NSApp.terminate(nil)
                return
            }

            if only == "pireceipt" {
                await PiReceiptSnapshot.run(model: model, shell: shell, directory: dir)
                NSApp.terminate(nil)
                return
            }

            if let only, only.hasPrefix("setup-") {
                await PiSetupSnapshot.run(model: model, shell: shell, directory: dir, only: only)
                NSApp.terminate(nil)
                return
            }

            if only == "r7b" {
                await PiR7bSnapshot.run(model: model, shell: shell, directory: dir)
                NSApp.terminate(nil)
                return
            }

            if only == "r6" {
                await PiR6Snapshot.run(model: model, shell: shell, directory: dir)
                NSApp.terminate(nil)
                return
            }

            if only == "pirpc-r2" {
                await PiRPCR2Snapshot.run(model: model, shell: shell, directory: dir)
                NSApp.terminate(nil)
                return
            }

            if only == "pirpc" {
                await PiRPCSnapshot.run(model: model, shell: shell, directory: dir)
                NSApp.terminate(nil)
                return
            }

            if only == "mailidentity" {
                await MailIdentitySnapshot.run(model: model, shell: shell, directory: dir)
                NSApp.terminate(nil)
                return
            }

            if only == "ctxsug" {
                await CtxSugSnapshot.run(model: model, shell: shell, directory: dir)
                NSApp.terminate(nil)
                return
            }
            if only == "calendar" {
                await CalendarSnapshot.run(model: model, shell: shell, directory: dir)
                NSApp.terminate(nil)
                return
            }

            if only == "thoughtline" {
                await ThoughtLineSnapshot.run(model: model, shell: shell, directory: dir)
                NSApp.terminate(nil)
                return
            }

            if only == "paste" {
                await PasteSnapshot.run(model: model, shell: shell, directory: dir)
                NSApp.terminate(nil)
                return
            }

            if only == "promptattachments" {
                await PromptAttachmentSnapshot.run(model: model, shell: shell, directory: dir)
                NSApp.terminate(nil)
                return
            }

            if only == "contextstop" {
                guard model.engine is StubEngine else {
                    try? "FAIL: contextstop requires PIPPA_DEMO=1".write(to: dir.appendingPathComponent("contextstop.txt"), atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                    return
                }
                var failures: [String] = []
                func verify(_ condition: Bool, _ note: String) { if !condition { failures.append(note) } }
                guard let skill = PippaSkill.parse("---\nname: antwort-schreiben\ndescription: Synthetic stop fixture\npippa-draft: true\n---", folder: "antwort-schreiben") else {
                    try? "FAIL: fixture skill invalid".write(to: dir.appendingPathComponent("contextstop.txt"), atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                    return
                }
                for prefix in ["Accepted before Stop", ""] {
                    model.newConversation()
                    let controller = model.conversations
                    let engine = StopRaceChat(prefix: prefix)
                    controller.send("Synthetic reply", chat: engine, skill: skill)
                    // Bounded polling of actual controller state, no timed guess
                    // about whether the streamed prefix arrived before Stop.
                    for _ in 0..<200 {
                        if engine.waiting, controller.streamingText == prefix { break }
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                    let waiting = engine.waiting
                    verify(waiting && controller.isRunning && controller.streamingText == prefix, "Engine/prefix did not become ready")
                    controller.stop()
                    for _ in 0..<200 {
                        if !controller.isRunning { break }
                        try? await Task.sleep(for: .milliseconds(10))
                    }
                    verify(!controller.isRunning && controller.streamingText.isEmpty && controller.error == nil, "Stopped request did not settle cleanly")
                    let messages = controller.current?.messages ?? []
                    let answers = messages.filter { $0.role == .assistant }
                    verify(messages.allSatisfy { $0.mailDraft == nil && $0.draft != true }, "Stopped return created a finished draft")
                    verify(messages.allSatisfy { !$0.text.contains("LATE_") && !$0.text.contains("FULL_RETURN") }, "Late output entered history")
                    if prefix.isEmpty {
                        verify(answers.isEmpty && messages.contains { $0.role == .system }, "Empty stopped answer needs a notice")
                    } else {
                        verify(answers.count == 1 && answers.first?.text == prefix && answers.first?.stopped == true, "Accepted prefix was not preserved as stopped")
                    }
                    let savedID = controller.current?.id
                    model.newConversation()
                    let freshID = controller.current?.id
                    engine.lateCallbacks()
                    try? await Task.sleep(for: .milliseconds(50))
                    verify(freshID != savedID && controller.current?.id == freshID && controller.current?.messages.isEmpty == true
                           && controller.streamingText.isEmpty && !controller.isRunning, "Stale callbacks affected fresh conversation")
                }
                try? (failures.isEmpty ? "PASS: stopped successful returns preserve only accepted partial text; no finished draft, late callbacks ignored, fresh topic isolated." : "FAIL:\n" + failures.joined(separator: "\n"))
                    .write(to: dir.appendingPathComponent("contextstop.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }

            if only == "dragtarget" {
                guard model.engine is StubEngine else {
                    try? "FAIL: dragtarget requires PIPPA_DEMO=1".write(to: dir.appendingPathComponent("dragtarget.txt"), atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                    return
                }
                // Synthetic drag metadata exercises the native state machine. It
                // neither reads drag contents nor proves delivery of OS drag events.
                shell.dragPoll?.invalidate()
                shell.dragPoll = nil
                let baseline = shell.dragBaseline
                let trayBefore = model.tray.items
                let contextBefore = model.conversations.current?.context
                defer {
                    shell.takingOut = false
                    shell.isDraggingPill = false
                    shell.dragAnnounced = false
                    shell.dragBaseline = baseline
                    model.busy = false
                    model.dragEnded()
                }
                var failures: [String] = []
                func verify(_ condition: Bool, _ note: String) { if !condition { failures.append(note) } }
                @MainActor func presence(_ pressed: Bool, _ supported: Bool, count: Int? = nil) {
                    shell.updateDragPresence(pressed: pressed, changeCount: count ?? baseline + 1, hasSupportedType: supported)
                }
                @MainActor func isTarget(hot: Bool) -> Bool {
                    if case .target(let actual) = model.mode { return actual == hot }
                    return false
                }
                model.collapse()
                await snap("dragtarget-01-rest")
                verify(shell.stageVisible, "Pill stage is not visible")
                presence(true, false)
                verify(model.mode.key == "pill" && !shell.dragAnnounced, "Unsupported drag announced a drop zone")
                presence(true, true, count: baseline)
                verify(model.mode.key == "pill" && !shell.dragAnnounced, "Unchanged pasteboard announced a drag")
                shell.takingOut = true
                presence(true, true)
                verify(model.mode.key == "pill" && !shell.dragAnnounced, "Own Take drag announced a drop zone")
                shell.takingOut = false
                shell.isDraggingPill = true
                presence(true, true, count: baseline + 2)
                verify(model.mode.key == "pill" && !shell.dragAnnounced, "Moving Pippa announced a drop zone")
                shell.isDraggingPill = false
                model.busy = true
                presence(true, true, count: baseline + 3)
                verify(model.mode.key == "pill" && !shell.dragAnnounced, "Busy pill offered an unavailable drop")
                model.busy = false
                presence(false, false, count: baseline + 3)
                presence(true, true, count: baseline + 4)
                verify(isTarget(hot: false) && shell.dragAnnounced, "Supported drag did not announce the early drop zone")
                verify(model.markState == .ruht, "Early target claimed completion before drop")
                await snap("dragtarget-02-early")
                verify(shell.draggingEntered() == .copy && isTarget(hot: true), "Entering did not highlight the target")
                verify(model.markState == .ruht, "Hot target claimed completion before drop")
                await snap("dragtarget-03-hot")
                shell.draggingExited()
                verify(isTarget(hot: false) && shell.dragAnnounced, "Leaving prematurely removed the announced target")
                await snap("dragtarget-04-exited")
                presence(false, true, count: baseline + 4)
                verify(model.mode.key == "pill" && !shell.dragAnnounced && !model.dropTargeted, "Release did not restore the neutral pill")
                await snap("dragtarget-05-restored")
                verify(model.tray.items == trayBefore, "Drag metadata changed the tray")
                verify(model.conversations.current?.context == contextBefore, "Drag metadata changed conversation context")
                let report = ["Synthetic native state-machine regression only: no drag contents read, no OS pointer drag simulated."]
                    + (failures.isEmpty ? ["PASS: early supported target, hot/exit, release, unsupported and own-drag exclusions; tray/context unchanged."] : failures.map { "FAIL: \($0)" })
                try? report.joined(separator: "\n").write(to: dir.appendingPathComponent("dragtarget.txt"), atomically: true, encoding: .utf8)
            }

            if only == "dropchain" {
                // Which view would AppKit hand a drag to? Hit test, then walk up to the first view
                // registered for drag types (AppKit's destination lookup). Every point of the open
                // conversation must end at a view that forwards to the shell.
                model.newConversation()
                model.conversations.append(.user, "Vorheriges Thema")
                model.conversations.append(.assistant, "Dieses Thema bleibt im Verlauf.")
                try? await Task.sleep(for: .milliseconds(900))
                await snap("dropchain-01-open")
                var lines: [String] = ["mode=\(model.mode.key) firstResponder=\(shell.panel.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")"]
                // The drag poll runs every 80 ms while the button is down, before the drag reaches the panel.
                shell.updateDragPresence(pressed: true, changeCount: shell.dragBaseline, hasSupportedType: true)
                var failures: [String] = []
                if !model.mode.isConversation { failures.append("Conversation did not open") }
                if let editor = shell.panel.firstResponder as? NSTextView, !editor.registeredDraggedTypes.isEmpty { failures.append("Input editor still takes drops itself") }
                if let root = shell.panel.contentView {
                    let rect = shell.shellScreenRect.offsetBy(dx: -shell.panel.frame.minX, dy: -shell.panel.frame.minY)
                    var counts: [String: Int] = [:]
                    for ix in 1..<12 { for iy in 1..<12 {
                        let p = NSPoint(x: rect.minX + rect.width * CGFloat(ix) / 12, y: rect.minY + rect.height * CGFloat(iy) / 12)
                        var view = root.hitTest(p)
                        while let v = view, v.registeredDraggedTypes.isEmpty { view = v.superview }
                        let name = view.map { String(describing: type(of: $0)) } ?? "nil"
                        counts[name, default: 0] += 1
                        let forwards = view is ShellDropView || view is ShellHostingView<ShellHostRoot>
                        if !forwards { failures.append("Point \(Int(p.x)),\(Int(p.y)) ends at \(name)") }
                    } }
                    if let editor = shell.panel.firstResponder as? NSView {
                        let mid = editor.convert(NSPoint(x: editor.bounds.midX, y: editor.bounds.midY), to: nil)
                        var view = root.hitTest(mid)
                        while let v = view, v.registeredDraggedTypes.isEmpty { view = v.superview }
                        let name = view.map { String(describing: type(of: $0)) } ?? "nil"
                        lines.append("input: \(name)")
                        if !(view is ShellHostingView<ShellHostRoot>) { failures.append("Drop on the input ends at \(name)") }
                    }
                    lines.append("destinations: " + counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
                }
                lines += failures.isEmpty ? ["PASS: every sampled point of the open conversation forwards drops to the shell."] : failures.prefix(12).map { "FAIL: \($0)" }
                try? lines.joined(separator: "\n").write(to: dir.appendingPathComponent("dropchain.txt"), atomically: true, encoding: .utf8)
                NSApp.terminate(nil)
                return
            }

            if only == "attachments" {
                NSApp.activate()
                var failures: [String] = []
                func verify(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
                let fixtureNames = ["Strategie.md", "Maßnahmenplan.md", "Notizen mit einem langen vollständigen Dateinamen.md", "Budget.md", "Zeitplan.md"]
                let files = fixtureNames.map { dir.appendingPathComponent($0) }
                for file in files { try? "# Synthetische Testdatei\nNur lokale UI-Testdaten.".write(to: file, atomically: true, encoding: .utf8) }
                model.newConversation()
                model.conversations.append(.user, "Vorheriges Thema")
                model.conversations.append(.assistant, "Dieses Thema bleibt im Verlauf.")
                let previous = model.conversations.current?.id
                model.collapse()
                // Exercise the same routing as an actual file drop, not a direct
                // tray insertion that could hide snapshot-only routing regressions.
                verify(model.dropsOnTray, "Pill file drop bypasses the tray")
                model.receive(.files(files), items: files)
                verify(model.tray.givenItems.count == files.count, "Dropped files missing from pill tray")
                verify(model.conversations.current?.id == previous, "Drop created a conversation before submission")
                model.collapse()
                model.show(.notice(title: "Vorheriges Ergebnis", detail: "", buttons: []))
                model.collapse()
                verify(model.markState == .offen, "Parked result lost its pill attention signal")
                await snap("attachments-01-pill")
                verify(shell.stackScreenRect != nil, "Dropped documents have no pill miniature surface")
                await sequence("attachments-02-open", shell: shell, dir: dir, slow: 3, frames: 5, span: 0.6) {
                    model.openPillDefault()
                }
                verify(model.mode.key == "line", "Given documents did not open the compact line before old result")
                verify(model.parked != nil && model.markState == .ruht, "Parked result changed input-ready mark to success/attention")
                verify(model.conversations.current?.id == previous, "Opening created a conversation before submission")
                model.tray.ask("   ")
                verify(model.mode.key == "line", "Empty submission opened a conversation")
                await snap("attachments-03-preparation")
                await sequence("attachments-04-submit", shell: shell, dir: dir, slow: 3, frames: 5, span: 0.65) {
                    model.tray.ask("Vergleiche die Dokumente.")
                }
                await snap("attachments-05-conversation")
                verify(model.mode.isConversation, "Submit did not open conversation")
                verify(model.conversations.current?.id != previous, "Submit did not start a fresh topic")
                verify(model.conversations.current?.context?.files == files, "Submit lost document order or context")
                verify(model.conversations.current?.messages.contains(where: { $0.role == .user && $0.text == "Vergleiche die Dokumente." }) == true, "Question missing after submit")
                verify(model.tray.givenItems.isEmpty, "Submitted documents remain duplicated on tray")
                model.conversations.setContext(name: "Testkontext", files: files, selectedText: "Testauswahl", announce: false)
                model.removeSelectedTextContext()
                verify(model.conversations.current?.context?.files == files && model.conversations.current?.context?.selectedText == nil, "Removing text also removed documents")
                model.removeConversationAttachment(files[0])
                verify(model.conversations.current?.context?.files == Array(files.dropFirst()), "Individual removal changed other documents")
                verify(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }, "Original test document missing")
                await snap("attachments-06-removed")
                let report = failures.isEmpty ? "PASS: compact preparation, ordered handover, fresh conversation, individual removal and preserved originals." : failures.joined(separator: "\n")
                try? report.write(to: dir.appendingPathComponent("attachments.txt"), atomically: true, encoding: .utf8)
            }

            if only == "mailcards" {
                // This fixture must never touch the person's real Mail app.
                guard model.engine is StubEngine else {
                    try? "FAIL: mailcards requires PIPPA_DEMO=1".write(to: dir.appendingPathComponent("mailcards.txt"), atomically: true, encoding: .utf8)
                    NSApp.terminate(nil)
                    return
                }
                var failures: [String] = []
                func verify(_ condition: Bool, _ note: String) { if !condition { failures.append(note) } }
                model.newConversation()
                model.openInput()
                model.conversations.append(.user, "Schreib eine kurze Terminantwort. (Synthetischer UI-Test)")
                let original = "Hallo Anna,\n\nDonnerstag um 14 Uhr passt für mich.\n\nViele Grüße"
                model.conversations.append(.assistant, original, draft: true, mailDraft: ConversationMailDraft(body: original))
                let id = model.conversations.current!.messages.last!.id
                await snap("mailcards-01-draft")
                if let value = env["PIPPA_SNAPSHOT_HOLD"], let seconds = Double(value), seconds > 0 {
                    shell.panel.allowsKey = true
                    shell.panel.makeKeyAndOrderFront(nil)
                    try? await Task.sleep(for: .seconds(min(seconds, 180)))
                    // Finish native field edits before the scripted phase replaces
                    // their values; otherwise focus-loss autosave races its handoff.
                    shell.panel.makeFirstResponder(nil)
                    try? await Task.sleep(for: .milliseconds(650))
                }
                var edited = ConversationMailDraft(to: "anna@example.invalid", subject: "Unser Termin", body: original + "\nTom")
                verify(model.conversations.updateMailDraft(messageID: id, draft: edited), "Edited draft not saved")
                await snap("mailcards-02-edited")
                verify(model.conversations.current?.messages.last?.text == original, "Editing rewrote original assistant answer")
                _ = await model.engine.requestIntegrationAccess(.mail)
                model.openMailDraft(messageID: id)
                for _ in 0..<40 {
                    if model.conversations.current?.messages.last?.mailDraft?.state == .opened { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                verify(model.conversations.current?.messages.last?.mailDraft?.state == .opened, "Demo Mail handover did not complete")
                model.openMailDraft(messageID: id)
                verify(model.conversations.current?.messages.last?.mailDraft?.state == .opened, "Repeated click changed completed draft")
                await snap("mailcards-03-opened")
                model.conversations.append(.assistant, original, draft: true, mailDraft: ConversationMailDraft(body: original))
                let discardID = model.conversations.current!.messages.last!.id
                model.discardMailDraft(messageID: discardID)
                verify(model.conversations.current?.messages.last?.mailDraft?.state == .discarded, "Discard failed")
                await snap("mailcards-04-discarded")
                model.conversations.append(.assistant, original, draft: true, mailDraft: ConversationMailDraft(body: original))
                let uncertainID = model.conversations.current!.messages.last!.id
                let conversationID = model.conversations.current!.id
                verify(model.conversations.transitionMailDraft(messageID: uncertainID, in: conversationID, to: .opening), "Opening not persisted")
                verify(model.conversations.transitionMailDraft(messageID: uncertainID, in: conversationID, to: .uncertain), "Uncertain status not persisted")
                await snap("mailcards-05-uncertain")
                edited.to = "bad-address"
                verify(!edited.canOpen, "Invalid recipient can open Mail")
                edited.to = "anna@example.invalid\n"
                verify(!edited.canOpen, "Header newline accepted")
                let report = failures.isEmpty ? "PASS: editable draft, original preserved, demo handover, duplicate guard, discard, uncertain outcome and header validation." : failures.joined(separator: "\n")
                try? report.write(to: dir.appendingPathComponent("mailcards.txt"), atomically: true, encoding: .utf8)
            }

            if only == "answers" {
                NSApp.activate()
                model.newConversation()
                model.openInput()
                // Authored presentation fixture with explicit sources, never a model-quality result.
                let strategy = dir.appendingPathComponent("Test-Strategie.md")
                let plan = dir.appendingPathComponent("Test-Plan.md")
                try? """
                # Synthetische Teststrategie
                ## 1 Umfang
                Die Einführung umfasst drei Teams: Nord, Süd und West.
                ## 2 Freigabe
                Auch der Pilot darf erst nach der Freigabe starten. Die Freigabe ist für den 15. September 2026 geplant.
                """.write(to: strategy, atomically: true, encoding: .utf8)
                try? """
                # Synthetischer Testplan
                ## 1 Pilot
                Team Nord startet am 1. September 2026 mit dem Pilotbetrieb.
                ## 2 Weitere Teams
                Für Süd und West enthält dieser Plan noch keine Einführungstermine.
                """.write(to: plan, atomically: true, encoding: .utf8)
                model.attach(.files([strategy, plan]), items: [strategy, plan], startsFresh: false, open: true)
                model.conversations.append(.user, "Vergleiche die Dokumente. (Synthetischer UI-Test)")
                let answer = """
                **Der Pilot startet laut Plan vor der Freigabe.** Außerdem fehlen Termine für zwei Teams.

                **Termin widersprüchlich:** Pilot am 1. September, Freigabe erst am 15. September. Die Strategie verlangt die Freigabe auch für den Pilot. (Test-Plan § 1; Test-Strategie § 2)

                **Umfang noch offen:** Drei Teams sind vorgesehen; nur Nord hat einen Termin. Süd und West fehlen im Zeitplan. (Test-Strategie § 1; Test-Plan § 2)

                **Zuerst klären:** Pilotstart verschieben oder Freigabe vorziehen? Danach Süd und West terminieren.
                """
                model.conversations.append(.assistant, answer)
                await snap("answers-01-comparison")
                model.newConversation()
                model.conversations.append(.user, "Darstellungstest: Tabelle, Liste, Zitat, Link und Code")
                model.conversations.append(.assistant, """
                **Synthetischer Darstellungstest:** Diese Werte stammen aus den beiden Testdateien.

                | Termin | Test-Strategie | Test-Plan |
                | --- | --- | --- |
                | Freigabe | 15.09.2026 | Nicht genannt |
                | Pilot Nord | Nach Freigabe | 01.09.2026 |

                - Den **Starttermin** abgleichen.
                - Für Süd und West Termine ergänzen.

                > Auch der Pilot darf erst nach der Freigabe starten. — Test-Strategie § 2

                Technischer Bezeichner: `Projekt-Test`. Linkdarstellung: [Apple Design](https://developer.apple.com/design/tips/).

                ```text
                Status: synthetischer UI-Test
                ```
                """)
                model.openInput()
                await snap("answers-02-details")
                let original = model.conversations.current?.messages.last?.text
                let fixtureFile = dir.appendingPathComponent("temporary-context.md")
                try? "Synthetic context.".write(to: fixtureFile, atomically: true, encoding: .utf8)
                model.attach(.files([fixtureFile]), items: [fixtureFile], startsFresh: false, open: true)
                model.removeConversationAttachment(fixtureFile)
                let cleared = model.conversations.current?.context == nil && model.context == nil
                let preserved = model.conversations.current?.messages.contains(where: { $0.role == .assistant && $0.text == original }) == true
                try? "\(cleared && preserved ? "PASS" : "FAIL"): Last attachment clears empty scope; original answer text preserved.".write(to: dir.appendingPathComponent("answers.txt"), atomically: true, encoding: .utf8)
            }

            if only == "product" {
                var failures: [String] = []
                func verify(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
                NSApp.activate()
                let fixtures = dir.appendingPathComponent("fixtures", isDirectory: true)
                try? FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
                let strategy = fixtures.appendingPathComponent("Strategie.md")
                let report = fixtures.appendingPathComponent("Underdog-Report.md")
                let notes = fixtures.appendingPathComponent("Notizen mit einem langen vollständigen Dateinamen.md")
                try? "# Strategie\nEine synthetische Bauunternehmensstrategie für 2030.".write(to: strategy, atomically: true, encoding: .utf8)
                try? "# Underdog\nEin synthetischer Produktvergleich von Desktop-Assistenten. Er behandelt Vorschläge, Quellen und überprüfbare Ergebnisse.".write(to: report, atomically: true, encoding: .utf8)
                try? "# Notizen\nDies sind unabhängige Testnotizen ohne persönliche Inhalte.".write(to: notes, atomically: true, encoding: .utf8)
                model.newConversation()
                model.handOver([strategy]) {}
                model.openInput()
                model.conversations.append(.user, "Fasse die Strategie zusammen.")
                model.conversations.append(.assistant, "Diese Teststrategie beschreibt ein Bauunternehmen.")
                let oldID = model.conversations.current?.id
                model.collapse()
                model.handOver([report]) {}
                model.openInput()
                verify(model.conversations.current?.id != oldID, "Frisches Give behält altes Thema")
                verify(model.conversations.current?.context?.files == [report], "Frisches Give enthält alte Quelle")
                verify(model.conversations.current?.context?.focusedFiles == [report], "Neue Datei nicht als Bezug markiert")
                await snap("product-01-new-topic")
                model.receive(.files([notes]), items: [notes], startsFresh: false)
                verify(model.conversations.current?.context?.files == [report, notes], "Explizites Ergänzen verliert Quellen")
                verify(model.conversations.current?.context?.focusedFiles == [notes], "Expliziter neuer Anhang ohne Fokus")
                model.conversations.append(.user, "Vergleiche die beiden Dokumente.")
                for index in 1...8 {
                    model.conversations.append(.assistant, "Testabschnitt \(index): Der Bericht vergleicht Desktop-Assistenten. Die Notizen ergänzen den Vergleich. Dieser längere Text prüft ausschließlich die Lesbarkeit der Oberfläche.")
                }
                await snap("product-02-conversation")
                // Optional bounded pause for native keyboard/scroll inspection of this isolated fixture.
                if let value = env["PIPPA_SNAPSHOT_HOLD"], let seconds = Double(value), seconds > 0 {
                    shell.panel.allowsKey = true
                    shell.panel.makeKeyAndOrderFront(nil)
                    try? await Task.sleep(for: .seconds(min(seconds, 180)))
                }
                model.collapse()
                model.tray.add([strategy, report, notes], origin: "Testdateien")
                model.openLine()
                await snap("product-03-suggestions")
                model.collapse()
                shell.previewFocusedAttachment(at: 1)
                await snap("product-04-focused-card")
                if let stack = shell.stackScreenRect, let data = grabWindow(shell.panel),
                   let image = crop(data, window: shell.panel, region: stack.union(shell.shellScreenRect).insetBy(dx: -20, dy: -20)) {
                    writePNG(image, to: dir.appendingPathComponent("product-04-full-stack.png"))
                }
                let count = model.tray.state.items.count
                shell.previewRemoveFocusedAttachment()
                await snap("product-05-removed-card")
                verify(model.tray.state.items.count == count - 1, "Dateikarte nicht entfernt")
                verify(FileManager.default.fileExists(atPath: report.path), "Entfernen hat Original verändert")
                verify(model.conversations.current?.context?.files.contains(report) != true, "Entfernte Karte bleibt Gesprächsquelle")
                let output = failures.isEmpty ? "PASS: Themenwechsel, neuer Quellenfokus, explizite Ergänzung, Entfernen ohne Originalverlust und Kontextbereinigung" : failures.map { "FAIL: " + $0 }.joined(separator: "\n")
                try? output.write(to: dir.appendingPathComponent("product.txt"), atomically: true, encoding: .utf8)
            }

            if only == "scans" {
                var failures: [String] = []
                func verify(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
                NSApp.activate()
                model.show(.onboarding)
                await snap("scans-01-welcome")
                let fixtures = dir.appendingPathComponent("fixtures", isDirectory: true)
                try? FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
                var inputs: [URL] = []
                for index in 1...3 {
                    let image = NSImage(size: CGSize(width: 600, height: 800))
                    image.lockFocus()
                    NSColor.white.setFill()
                    NSBezierPath(rect: CGRect(x: 0, y: 0, width: 600, height: 800)).fill()
                    ("Pippa scan \(index)" as NSString).draw(at: CGPoint(x: 60, y: 680), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black
                    ])
                    image.unlockFocus()
                    let file = fixtures.appendingPathComponent("Scan \(index).png")
                    if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try? png.write(to: file)
                        inputs.append(file)
                    }
                }
                let originals = inputs.map { try? Data(contentsOf: $0) }
                model.receive(.files(inputs), items: inputs)
                verify(model.mode.key == "line" && model.tray.givenItems.count == 3, "First Give did not open the tray line")
                await snap("scans-02-given")
                if let action = model.tray.offered.first(where: { $0.id == "make-one-pdf" }) {
                    let started = Date()
                    model.tray.choose(action)
                    for _ in 0..<600 {
                        if !model.tray.isWorking { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    try? String(format: "%.3f seconds\n", Date().timeIntervalSince(started)).write(to: dir.appendingPathComponent("scans-duration.txt"), atomically: true, encoding: .utf8)
                } else { failures.append("Make one PDF missing") }
                await snap("scans-03-result")
                if let result = model.tray.items.first(where: { $0.role == .result }) {
                    let pdf = PDFDocument(url: result.url)
                    verify(pdf?.pageCount == 3, "Result must contain three pages")
                    verify(pdf?.string?.contains("Pippa") == true, "Result has no searchable OCR text")
                    model.collapse()
                    model.openLine()
                    verify(model.tray.phase == .result(result.id), "Reopening lost Save and Undo")
                    verify(model.tray.givenItems.isEmpty, "Successful inputs not consumed")
                    model.tray.undoResult(result.id)
                    for _ in 0..<100 {
                        if !model.tray.items.contains(where: { $0.id == result.id }) { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    verify(!FileManager.default.fileExists(atPath: result.url.path), "Undo left the generated result")
                    verify(model.tray.givenItems.count == 3, "Undo did not restore the three sources")
                } else { failures.append("No result produced") }
                await snap("scans-04-undo")
                verify(zip(inputs, originals).allSatisfy { (try? Data(contentsOf: $0.0)) == $0.1 }, "Original changed")
                verify(!model.modelReady, "Scan action activated a model")
                // Inspect the actual settings view and exercise clearing the learned-action store.
                let settings = SettingsWindowController(model: model)
                settings.show()
                try? await Task.sleep(for: .seconds(0.8))
                if let window = settings.window, let data = grabWindow(window),
                   let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage {
                    writePNG(cg, to: dir.appendingPathComponent("scans-05-settings.png"))
                }
                do {
                    let records = try await model.taskLog.recordsForSettings()
                    verify(!records.isEmpty, "Chosen scan action was not visible in learned actions")
                    try await model.taskLog.forgetLearnedActions()
                    await model.tray.reloadHabits()
                    await model.letter.reloadHabits()
                    let cleared = try await model.taskLog.recordsForSettings()
                    verify(cleared.isEmpty, "Forget learned actions retained records")
                } catch { failures.append("Learned actions could not be read or forgotten") }
                let report = failures.isEmpty ? "PASS: First Give → three-page PDF → journalled Undo; originals intact; no model." : failures.map { "FAIL: " + $0 }.joined(separator: "\n")
                try? report.write(to: dir.appendingPathComponent("scans.txt"), atomically: true, encoding: .utf8)
            }

            if only == "byom" {
                var failures: [String] = []
                func verify(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
                verify(model.inferenceSettings.policy == .localOnly && !model.hasConfiguredInference,
                       "Erster Start aktiviert eigene Modelle")
                // Show the actual connection editor without invoking Test or reading a secret.
                let host = NSHostingController(rootView: ModelConnectionSettings(model: model).padding(20).frame(width: 560).background(Color(nsColor: Theme.chatTint)))
                let window = NSWindow(contentViewController: host)
                window.styleMask = [.titled, .closable]
                window.title = "Pippa · Eigenes Modell"
                window.center(); window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(0.8))
                if let data = grabWindow(window), let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage {
                    writePNG(cg, to: dir.appendingPathComponent("byom-03-settings.png"))
                }
                window.orderOut(nil)
                let report = failures.isEmpty ? "PASS: Erster Start nur lokal; Einstellungen für den eigenen Online-Dienst gezeigt, ohne Test oder gespeicherten Schlüssel." : failures.map { "FAIL: " + $0 }.joined(separator: "\n")
                try? report.write(to: dir.appendingPathComponent("byom.txt"), atomically: true, encoding: .utf8)
            }

            if only == "keyboard" {
                var failures: [String] = []
                func verify(_ condition: Bool, _ message: String) {
                    if !condition { failures.append(message) }
                }
                @MainActor func settle() async {
                    for _ in 0..<160 {
                        if !model.isActiveWork { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                @MainActor func enter(_ modifiers: NSEvent.ModifierFlags = [], repeatKey: Bool = false) async {
                    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: shell.panel.windowNumber, context: nil,
                                                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: repeatKey, keyCode: 36)!
                    NSApp.postEvent(event, atStart: false)
                    try? await Task.sleep(for: .milliseconds(300))
                }
                let fixture = dir.appendingPathComponent("files", isDirectory: true)
                try? FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
                model.newConversation()
                model.receive(.files([fixture]), items: [fixture])
                await settle()
                model.startSort()
                await settle()
                model.query = "Zwei Zeilen"
                NSApp.activate(ignoringOtherApps: true)
                shell.panel.makeKeyAndOrderFront(nil)
                await snap("keyboard-01-preview")
                verify(shell.panel.firstResponder is NSTextView, "Chatfeld hat keinen Texteingabefokus")
                if let editor = shell.panel.firstResponder as? NSTextView {
                    editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                }
                await enter(.shift)
                verify(model.query.contains("\n") && model.mode.key == "sort", "Shift Enter erzeugt keinen Zeilenumbruch in der Vorschau")
                model.query = "Warum diese Ordnung?"
                try? await Task.sleep(for: .milliseconds(200))
                await enter()
                await settle()
                verify(model.mode.key == "sort" && model.taskCard?.key == "sort" && model.lastReceipt == nil,
                       "Enter bestätigt Vorschau statt Chatnachricht zu senden oder schließt die Vorschau")
                // ⌘↩ with typed text sends it (whoever types a follow-up wants to send, not tidy);
                // only with an empty field does ⌘↩ confirm a visible preview, never a collapsed one.
                model.openInput()
                model.query = ""
                await enter(.command)
                verify(model.mode.key == "input" && model.lastReceipt == nil, "Command Enter führt eingeklappte Vorschau aus")
                let sentBefore = model.conversations.current?.messages.filter { $0.role == .user }.count ?? 0
                model.query = "Noch eine Frage"
                await enter(.command)
                await settle()
                let sentAfter = model.conversations.current?.messages.filter { $0.role == .user }.count ?? 0
                verify(model.lastReceipt == nil && model.query.isEmpty && sentAfter == sentBefore + 1,
                       "Command Enter mit Text sendet nicht oder führt eingeklappte Vorschau aus")
                model.resumeTaskCard()
                model.query = "Frage zur Vorschau"
                await enter(.command)
                await settle()
                verify(model.mode.key == "sort" && model.lastReceipt == nil, "Command Enter mit Text bestätigt Vorschau statt zu senden")
                model.query = ""
                model.excluded = Set(model.plan?.ops.map(\.id) ?? [])
                await enter(.command)
                verify(model.mode.key == "sort" && model.lastReceipt == nil, "Leere Auswahl wird bestätigt")
                model.excluded = []
                await enter(.command, repeatKey: true)
                verify(model.mode.key == "sort" && model.lastReceipt == nil, "Tastenwiederholung bestätigt Vorschau")
                await enter(.command)
                await settle()
                verify(model.lastReceipt != nil && model.mode.key == "notice", "Command Enter bestätigt sichtbare Vorschau nicht")
                // Confirm via button (mouse) with a draft in the field: the draft stays.
                model.resumeTaskCard()
                if model.mode.key != "sort" {
                    model.startSort()
                    await settle()
                }
                model.query = "Ungesendeter Entwurf"
                let receiptBefore = model.lastReceipt?.id
                model.confirmPreview()
                await settle()
                verify(model.lastReceipt?.id != receiptBefore, "Knopf bestätigt Vorschau nicht")
                verify(model.query == "Ungesendeter Entwurf", "Bestätigen löscht Chatentwurf")
                await snap("keyboard-02-confirmed")
                let report = failures.isEmpty ? "PASS: Enter sendet, Shift Enter neue Zeile, Command Enter sendet getippten Text und bestätigt bei leerem Feld die sichtbare gültige Vorschau; Entwurf bleibt beim Bestätigen per Knopf; eingeklappte/ungültige Vorschau und Tastenwiederholung gesperrt" : failures.map { "FAIL: " + $0 }.joined(separator: "\n")
                try? report.write(to: dir.appendingPathComponent("keyboard.txt"), atomically: true, encoding: .utf8)
            }

            // First launch, knowledge still loading (`PIPPA_DEMO_MODEL=missing`): "Tidy Downloads" from the welcome,
            // unclear items stay put, after waking up Pippa offers it once.
            // Welcome and chat footer while knowledge is missing: with the question before loading, while loading, after.
            // Checks that the welcome fits the height (otherwise it scrolls, starting at the top) and the figure sits in its place.
            if only == "welcome" {
                var failures: [String] = [], report: [String] = []
                func verify(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
                verify(model.needsDownloadConsent, "Ohne Frage vor dem Laden gestartet (Argument -model.download.allowed NO und PIPPA_DEMO_MODEL=missing)")
                model.newConversation()
                model.show(.onboarding)
                await snap("welcome-01-consent")
                verify(shell.shellScreenRect.height >= shell.lastMeasuredHeight - 0.5,
                       "Willkommen mit Frage passt nicht in \(Int(shell.shellScreenRect.height)) pt (braucht \(Int(shell.lastMeasuredHeight)))")
                report.append("welcome-01-consent: Höhe \(Int(shell.lastMeasuredHeight)) pt, Platz \(Int(shell.shellScreenRect.height)) pt")
                model.openInput()
                await snap("welcome-02-chat-not-loaded")
                verify(model.needsDownloadConsent && model.learningText?.contains("noch nicht geladen") == true, "Fußzeile ohne Zustimmung falsch")
                model.startModelDownload()
                try? await Task.sleep(for: .seconds(2.2))
                await snap("welcome-03-chat-downloading", wait: 0.2)
                verify(model.progressValue != nil, "Laden zeigt keinen Fortschritt")
                model.show(.onboarding)
                await snap("welcome-04-downloading", wait: 0.5)
                report.append("welcome-04-downloading: Höhe \(Int(shell.lastMeasuredHeight)) pt, Platz \(Int(shell.shellScreenRect.height)) pt")
                for _ in 0..<200 where !model.modelReady { try? await Task.sleep(for: .milliseconds(100)) }
                model.show(.onboarding)
                await snap("welcome-05-ready")
                report.append("welcome-05-ready: Höhe \(Int(shell.lastMeasuredHeight)) pt, Platz \(Int(shell.shellScreenRect.height)) pt")
                let text = (failures.isEmpty ? ["PASS"] : failures.map { "FAIL: " + $0 }) + report
                try? text.joined(separator: "\n").write(to: dir.appendingPathComponent("welcome.txt"), atomically: true, encoding: .utf8)
            }

            if only == "firstrun" {
                var failures: [String] = []
                func verify(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
                @MainActor func settle() async {
                    for _ in 0..<160 {
                        if !model.isActiveWork { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                verify(!model.modelReady, "Beispiel-Engine hat schon Wissen (PIPPA_DEMO_MODEL=missing setzen)")
                model.newConversation()
                model.show(.onboarding)
                await snap("firstrun-01-welcome")
                // Own folder instead of the real Downloads: the file waiting for the knowledge must exist.
                let fixture = dir.appendingPathComponent("Downloads", isDirectory: true)
                try? FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
                try? "Entwurf".write(to: fixture.appendingPathComponent("Brief Vermieter.docx"), atomically: true, encoding: .utf8)
                model.tidyDownloads(folder: fixture)
                await snap("firstrun-02-working", wait: 0.4)
                await settle()
                verify(model.mode.key == "sort" && model.plan?.later.count == 1 && model.plan?.ops.contains { $0.kind == .move } == true,
                       "Ordnen ohne Wissen zeigt keine Vorschau oder merkt die unklare Unterlage nicht für später")
                verify(!model.modelReady, "Wissen war zu schnell da, Lauf sagt nichts über Ordnen ohne Wissen")
                await snap("firstrun-03-sort")
                model.confirmPreview()
                await settle()
                if case .notice(_, let detail, _) = model.mode {
                    verify(detail.contains("ordne ich genauer"), "Quittung nennt die liegen gebliebene Unterlage nicht")
                } else {
                    verify(false, "Keine Quittung nach dem Ordnen ohne Wissen")
                }
                verify(model.sortLater?.files.count == 1, "Unterlage für später nicht gemerkt")
                await snap("firstrun-04-receipt")
                model.openInput()
                if !model.downloadAllowed { model.startModelDownload() }
                var offered: [ToastButton] = []
                for _ in 0..<300 {
                    if case .notice(let title, _, let buttons) = model.mode, title == "Ich bin jetzt ganz wach" { offered = buttons; break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                verify(model.modelReady && !offered.isEmpty,
                       "Nach dem Wachwerden kein Angebot für die liegen gebliebene Unterlage (bereit: \(model.modelReady), Form: \(model.mode.key), beschäftigt: \(model.isActiveWork), gemerkt: \(model.sortLater?.files.count ?? 0))")
                await snap("firstrun-05-awake")
                offered.first { $0.title == "Jetzt ordnen" }?.action()
                await settle()
                verify(model.mode.key == "sort" && model.plan?.later.isEmpty == true && model.sortLater == nil,
                       "„Jetzt ordnen“ zeigt keine vollständige Vorschau")
                await snap("firstrun-06-later-sorted")
                let report = failures.isEmpty ? "PASS: Downloads aufräumen ohne Wissen, Unklares bleibt liegen und steht in Vorschau und Quittung, nach dem Wachwerden einmal angeboten und geordnet" : failures.map { "FAIL: " + $0 }.joined(separator: "\n")
                try? report.write(to: dir.appendingPathComponent("firstrun.txt"), atomically: true, encoding: .utf8)
            }

            if only == "natural" {
                var failures: [String] = []
                func verify(_ condition: Bool, _ message: String) {
                    if !condition { failures.append(message) }
                }
                @MainActor func settle() async {
                    for _ in 0..<160 {
                        if !model.isActiveWork && model.pendingDrops.isEmpty { break }
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                let fixtures = dir.appendingPathComponent("files", isDirectory: true)
                try? FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
                let urls = ["Rechnung.txt", "Vertrag.txt", "Notiz.txt"].map { fixtures.appendingPathComponent($0) }
                for url in urls { try? "Beispieldatei für den UI-Ablauf.".write(to: url, atomically: true, encoding: .utf8) }
                model.newConversation()
                model.query = "Meine angefangene Frage"
                model.receive(.files([urls[0]]), items: [urls[0]])
                model.receive(.files([urls[1]]), items: [urls[1]])
                verify(model.pendingDrops.count == 1, "Zweiter Drop während Arbeit nicht vorgemerkt")
                await snap("natural-01-queued", wait: 0.2)
                await settle()
                verify(model.conversations.current?.context?.files == Array(urls.prefix(2)), "Zweiter Drop ersetzt erste Datei")
                verify(model.query == "Meine angefangene Frage", "Drop löscht Entwurf")
                await snap("natural-02-added")
                let frame = shell.shellScreenRect
                model.startSort()
                await settle()
                let ids = model.plan?.ops.map(\.id)
                if let op = model.plan?.ops.first { model.excluded.insert(op.id) }
                let excluded = model.excluded
                verify(model.workflowSummary.contains("noch NICHT ausgeführt"), "Pi fehlt der Vorschau-Status")
                model.route("Warum schlägst du diese Ordnung vor?")
                await settle()
                verify(model.taskCard?.key == "sort", "Nachfrage verliert Vorschau")
                verify(model.plan?.ops.map(\.id) == ids && model.excluded == excluded, "Nachfrage verändert Auswahl")
                await snap("natural-03-followup")
                model.resumeTaskCard()
                verify(model.mode.key == "sort" && model.plan?.ops.map(\.id) == ids, "Zurück erzeugt anderen Plan")
                verify(shell.shellScreenRect == frame, "Fenster springt beim Wechsel")
                await snap("natural-04-preview")
                @MainActor func scrollCount(_ view: NSView) -> Int {
                    let own: Int
                    if let scroll = view as? NSScrollView, !(scroll.documentView is NSTextView),
                       (scroll.documentView?.frame.height ?? 0) > scroll.contentSize.height + 1 {
                        own = 1
                    } else { own = 0 }
                    return own + view.subviews.reduce(0) { $0 + scrollCount($1) }
                }
                if let root = shell.panel.contentView {
                    let count = scrollCount(root)
                    verify(count == 1, "Sortiervorschau hat \(count) vertikale Scrollflächen statt einer")
                }
                model.applySort()
                await settle()
                model.route("Was wurde geändert?")
                await settle()
                let count = model.conversations.current?.messages.count
                model.resumeTaskCard()
                verify(model.mode.key == "notice", "Ergebnis nach Nachfrage nicht erreichbar")
                verify(model.conversations.current?.messages.count == count, "Ergebnis erneut in Verlauf eingefügt")
                await snap("natural-05-result")
                if let receipt = model.lastReceipt { model.undo(receipt) }
                await settle()
                model.receive(.files([urls[2]]), items: [urls[2]])
                await settle()
                verify(model.conversations.current?.context?.files == urls, "Weiterer Drop verliert Kontext")
                model.startInvoices()
                await snap("natural-06-reading", wait: 0.4)
                await settle()
                await snap("natural-06-invoices")
                if let root = shell.panel.contentView {
                    verify(scrollCount(root) <= 1, "Rechnungstabelle verschachtelt Scrollflächen")
                }
                model.clearContext()
                verify(model.taskCard == nil && model.plan == nil, "Entfernter Kontext hinterlässt alte Vorschau")
                let report = failures.isEmpty ? "PASS: Drop vormerken, Dateien ergänzen, Entwurf behalten, Vorschau besprechen, Auswahl wiederherstellen, Ergebnis/Rückgängig, Kontext lösen, eine Scrollfläche pro Vorschau" : failures.map { "FAIL: " + $0 }.joined(separator: "\n")
                try? report.write(to: dir.appendingPathComponent("natural.txt"), atomically: true, encoding: .utf8)
            }

            if only == "chat" {
                model.newConversation()
                model.openInput()
                await snap("chat-01-open")
                model.receive(.text("Der Termin mit Anna ist am Donnerstag um 14 Uhr. Bitte den Vertragsentwurf mitbringen."), items: [])
                await snap("chat-02-selection")
                let originalID = model.conversations.current?.id
                model.route("Fasse den ausgewählten Text zusammen.")
                for _ in 0..<100 {
                    if !model.conversations.isRunning { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                await snap("chat-03-answer")
                let count = model.conversations.current?.messages.count
                model.collapse(); model.openInput()
                let reopened = model.conversations.current?.messages.count == count
                model.newConversation()
                let isolated = model.conversations.current?.context == nil && model.conversations.current?.messages.isEmpty == true
                if let originalID { model.selectConversation(originalID) }
                await snap("chat-04-restored")
                let restored = model.conversations.current?.id == originalID && model.conversations.current?.context?.selectedText != nil
                let answered = model.conversations.current?.messages.contains { $0.role == .assistant } == true
                let ok = reopened && isolated && restored && answered
                try? "\(ok ? "PASS" : "FAIL"): Antwort, Öffnen/Schließen, neue Aufgabe ohne alten Kontext, Verlauf wiederhergestellt".write(to: dir.appendingPathComponent("chat.txt"), atomically: true, encoding: .utf8)
            }

            if only == "workspace" {
                // A whole job, without manual closing in between. Checks the
                // actual window frame, not just the computation of the target position.
                var frames: [(String, CGRect)] = []
                var failures: [String] = []
                @MainActor func check(_ name: String, expected: String, wait: Double = 1) async {
                    await snap(name, wait: wait)
                    frames.append((name, shell.shellScreenRect))
                    if model.mode.key != expected { failures.append("\(name): erwartet \(expected), erhalten \(model.mode.key)") }
                    if model.toasts?.currentPanel != nil { failures.append("\(name): separates Meldungsfenster") }
                }
                model.openInput()
                await check("workspace-01-input", expected: "input")
                model.receive(.files([downloads]), items: [downloads])
                await check("workspace-02-overview", expected: "overview", wait: 2.2)
                model.startSort()
                await check("workspace-03-working", expected: "working", wait: 0.4)
                await check("workspace-04-sort", expected: "sort", wait: 2.2)
                model.applySort()
                await check("workspace-05-done", expected: "notice", wait: 2.2)
                if let receipt = model.lastReceipt { model.undo(receipt) }
                await check("workspace-06-undo", expected: "notice", wait: 2.2)
                model.openInput()
                await check("workspace-07-input", expected: "input")
                if let first = frames.first?.1 {
                    for (name, frame) in frames where abs(frame.minX - first.minX) > 1 || abs(frame.maxY - first.maxY) > 1 {
                        failures.append("\(name): Lesebeginn hat sich verschoben")
                    }
                }
                let report = frames.map { "\($0.0): x=\($0.1.minX), top=\($0.1.maxY), width=\($0.1.width), height=\($0.1.height)" }
                    + (failures.isEmpty ? ["PASS: gleicher Lesebeginn, Abschluss und Rückgängig in derselben Hülle"] : failures.map { "FAIL: \($0)" })
                try? report.joined(separator: "\n").write(to: dir.appendingPathComponent("workspace.txt"), atomically: true, encoding: .utf8)
            }

            if only == nil || only == "morph" {
                await morphs(model: model, shell: shell, dir: dir, downloads: downloads)
            }
            if only == nil || only == "states" {
                model.show(.pill)
                await snap("01-pill", wait: 1.0)
                model.show(.onboarding)
                await snap("02-onboarding")
                model.receive(.files([downloads]), items: [downloads])
                await snap("03-working", wait: 0.6)
                await snap("04-overview", wait: 2.0)
                model.openInput()
                await snap("05-input")
                model.query = "Kündigung"
                await snap("06-input-typed")
                model.startSort()
                await snap("07-sort", wait: 2.5)
                model.showReasons = true
                await snap("08-sort-reasons")
                model.startInvoices()
                await snap("09-invoices", wait: 2.5)
                model.show(.message(title: "Hat nicht geklappt", body: "Nichts wurde geändert.", isError: true))
                await snap("12-error")
                // Real waiting result: show overview, then close.
                model.receive(.files([downloads]), items: [downloads])
                try? await Task.sleep(for: .seconds(2.2))
                model.collapse()
                await snap("13-pill-waiting")
                model.show(.pill)
                model.show(.target(hot: true))
                await snap("15-target")
                model.startDeadlines()
                await snap("16-deadlines", wait: 2.0)
                if let d = model.deadlines.last { model.prepareEntry(d, target: .reminder) }
                await snap("17-entry-preview")
                model.show(.permission(.mail, denied: false))
                await snap("18-permission")
                model.show(.permission(.calendar, denied: true))
                await snap("19-permission-denied")
                model.show(.pill)
                await snap("21-pill-end", wait: 1.0)
                model.openInput()
                await snap("22-input")
                model.collapse()
                model.toasts?.show(title: "46 Dateien geordnet", detail: "4 Ordner · 1 übersprungen", buttons: [
                    .init(title: "Rückgängig", primary: true) {}, .init(title: "Im Finder zeigen", primary: false) {},
                ])
                try? await Task.sleep(for: .seconds(0.9))
                if let w = model.toasts?.currentPanel, let data = grabWindow(w), let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage {
                    writePNG(cg, to: dir.appendingPathComponent("24-toast.png"))
                }
                model.toasts?.dismiss()
            }
            try? cornerReport.joined(separator: "\n").write(to: dir.appendingPathComponent("corners.txt"), atomically: true, encoding: .utf8)
            timingReport.insert(contentsOf: springTimeline(), at: 0)
            try? timingReport.joined(separator: "\n").write(to: dir.appendingPathComponent("timings.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    // MARK: Frame sequences of the morph

    private static func morphs(model: AppModel, shell: ShellController, dir: URL, downloads: URL) async {
        let slow = 8.0
        model.show(.pill)
        try? await Task.sleep(for: .seconds(0.8))

        await sequence("m1-pill-input", shell: shell, dir: dir, slow: slow, frames: 12, span: 0.6) { model.openInput() }
        await sequence("m2-input-pill", shell: shell, dir: dir, slow: slow, frames: 12, span: 0.5) { model.collapse() }

        // Set context so that a question has files.
        model.receive(.files([downloads]), items: [downloads])
        try? await Task.sleep(for: .seconds(2.5))
        model.openInput()
        try? await Task.sleep(for: .seconds(1.0))
        await sequence("m3-input-working-result", shell: shell, dir: dir, slow: slow, frames: 20, span: 2.4) {
            model.receive(.files([downloads]), items: [downloads])
        }
        try? await Task.sleep(for: .seconds(1.5))
        await sequence("m4-result-sheet", shell: shell, dir: dir, slow: slow, frames: 20, span: 3.0) { model.startSort() }
        try? await Task.sleep(for: .seconds(1.0))
        await sequence("m5-sheet-pill", shell: shell, dir: dir, slow: slow, frames: 12, span: 0.5) { model.collapse() }
        try? await Task.sleep(for: .seconds(1.0))
        model.show(.pill)
        try? await Task.sleep(for: .seconds(0.6))
        // Interruption: input opens, close again at ~40 %.
        await sequence("m6-interrupt", shell: shell, dir: dir, slow: slow, frames: 16, span: 0.8,
                       midway: (0.18, { model.collapse() })) { model.openInput() }
        shell.slowdown = 1
        try? await Task.sleep(for: .seconds(0.8))
    }

    /// Triggers `action` and photographs `frames` images over `span` seconds (real time before slow motion).
    private static func sequence(_ name: String, shell: ShellController, dir: URL, slow: Double, frames: Int, span: Double,
                                 midway: (Double, @MainActor () -> Void)? = nil, _ action: @MainActor () -> Void) async {
        shell.slowdown = slow
        let folder = dir.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let from = shell.shellScreenRect
        let start = Date()
        var regions: [NSRect] = [from]
        shell.triggerTime = CACurrentMediaTime()
        action()
        if let l = shell.lastLatency {
            timingReport.append(String(format: "%@: Auslöser bis erstes Bild (Animation übergeben) %.1f ms (Messen %.1f ms, Standbild %.1f ms)",
                                       name, l * 1000, shell.measureTime * 1000, shell.snapshotTime * 1000))
        }
        var stamps: [String] = []
        regions.append(shell.shellScreenRect)
        var didMid = false
        var files: [URL] = []
        for i in 0..<frames {
            let due = Double(i) / Double(frames - 1) * span * slow
            let wait = due - Date().timeIntervalSince(start)
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            if let midway, !didMid, Date().timeIntervalSince(start) >= midway.0 * slow {
                didMid = true
                midway.1()
            }
            regions.append(shell.shellScreenRect)
            stamps.append(String(format: "%02d @ %.0f ms", i, Date().timeIntervalSince(start) / slow * 1000))
            let url = folder.appendingPathComponent(String(format: "%02d.png", i))
            if let raw = grabWindow(shell.panel) { try? raw.write(to: url) }
            files.append(url)
        }
        shell.slowdown = 1
        timingReport.append("\(name) Bilder (Echtzeit): " + stamps.joined(separator: ", "))
        // Crop: everything the shell touched in this sequence, plus margin for the shadow.
        let region = regions.dropFirst().reduce(regions[0]) { $0.union($1) }.insetBy(dx: -40, dy: -40)
        contactSheet(files: files, window: shell.panel, region: region, to: dir.appendingPathComponent("\(name).png"))
    }

    // MARK: Capture

    /// The window with alpha (without window shadow), as PNG data.
    private static func grabWindow(_ window: NSWindow) -> Data? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-grab-\(UUID().uuidString).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", tmp.path]
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return renderWindow(window) }
        // With the display asleep screencapture hangs: don't wait forever.
        if done.wait(timeout: .now() + 4) == .timedOut { p.terminate(); return renderWindow(window) }
        defer { try? FileManager.default.removeItem(at: tmp) }
        return (try? Data(contentsOf: tmp)) ?? renderWindow(window)
    }

    /// Without screen recording permission (e.g. in a sandbox): draw the views themselves. Without glass behind the
    /// window (the material stays gray), but exact for layout and text.
    private static func renderWindow(_ window: NSWindow) -> Data? {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// Cuts a screen region out of a window capture.
    private static func crop(_ data: Data, window: NSWindow, region: NSRect) -> CGImage? {
        guard let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage else { return nil }
        let scale = CGFloat(cg.width) / window.frame.width
        let local = region.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY).intersection(CGRect(origin: .zero, size: window.frame.size))
        let px = CGRect(x: local.minX * scale, y: (window.frame.height - local.maxY) * scale,
                        width: local.width * scale, height: local.height * scale).integral
        return cg.cropping(to: px)
    }

    private static func capture(_ shell: ShellController, name: String, to url: URL, checkCorners: Bool) {
        guard let data = grabWindow(shell.panel) else { return }
        let rect = shell.shellScreenRect
        guard let image = crop(data, window: shell.panel, region: rect.insetBy(dx: -30, dy: -30)) else { return }
        writePNG(image, to: url)
        if checkCorners {
            let scale = CGFloat(image.width) / (rect.width + 60)
            checkCorner(image, name: name, inset: 30, scale: scale)
            checkContrast(image, name: name, inset: 30, scale: scale, dark: shell.panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        }
    }

    /// Checks the corner pixels outside the rounded shape: never bright and opaque (no white corners).
    private static func checkCorner(_ image: CGImage, name: String, inset: CGFloat, scale: CGFloat) {
        guard let rep = Optional(NSBitmapImageRep(cgImage: image)) else { return }
        let i = Int(inset * scale)
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let corners = [(i + 1, i + 1), (w - i - 2, i + 1), (i + 1, h - i - 2), (w - i - 2, h - i - 2)]
        var worst = ""
        var ok = true
        for (x, y) in corners {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
            let a = c.alphaComponent
            // White/gray corner = error; colored pixels (e.g. the green figure) are intended.
            let chroma = max(c.redComponent, c.greenComponent, c.blueComponent) - min(c.redComponent, c.greenComponent, c.blueComponent)
            if a > 0.5 && lum > 0.55 && chroma < 0.2 { ok = false }
            worst += String(format: " (a=%.2f l=%.2f)", a, lum)
        }
        cornerReport.append("\(ok ? "OK  " : "FAIL") \(name):\(worst)")
    }

    /// Contrast of secondary and primary text against the actual glass surface (empty spot inside left).
    private static func checkContrast(_ image: CGImage, name: String, inset: CGFloat, scale: CGFloat, dark: Bool) {
        let rep = NSBitmapImageRep(cgImage: image)
        let x = Int((inset + 4) * scale), y = rep.pixelsHigh / 2
        guard let bg = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return }
        func lin(_ c: CGFloat) -> CGFloat { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func lum(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat { 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b) }
        func over(_ v: CGFloat, _ a: CGFloat, _ b: CGFloat) -> CGFloat { v * a + b * (1 - a) }
        let lb = lum(bg.redComponent, bg.greenComponent, bg.blueComponent)
        func ratio(_ v: CGFloat, _ a: CGFloat) -> CGFloat {
            let lf = lum(over(v, a, bg.redComponent), over(v, a, bg.greenComponent), over(v, a, bg.blueComponent))
            return (max(lf, lb) + 0.05) / (min(lf, lb) + 0.05)
        }
        let primary = ratio(dark ? 1 : 0, dark ? 0.85 : 0.85)
        let secondary = dark ? ratio(1, 0.74) : ratio(0, 0.72)
        let ok = secondary >= 4.5
        cornerReport.append(String(format: "%@ %@: Kontrast Text %.1f:1, Sekundärtext %.1f:1 (Hintergrund %.2f/%.2f/%.2f a=%.2f)",
                                   ok ? "OK  " : "FAIL", name, primary, secondary, bg.redComponent, bg.greenComponent, bg.blueComponent, bg.alphaComponent))
    }

    /// Spring curve at 120 frames/s: when the shape settles.
    private static func springTimeline() -> [String] {
        var out: [String] = []
        for (label, s) in [("Öffnen", ShellTokens.expand), ("Schließen", ShellTokens.collapse)] {
            var x = 0.0, v = 0.0, t = 0.0, peak = 0.0
            let dt = 1.0 / 120 / 20
            var frames: [String] = []
            var t95: Double?, tSettled: Double?
            var frame = 0
            while t < 0.6 {
                for _ in 0..<20 {
                    let a = (-Double(s.stiffness) * (x - 1) - Double(s.damping) * v) / Double(s.mass)
                    v += a * dt; x += v * dt; t += dt
                }
                frame += 1
                peak = max(peak, x)
                if t95 == nil, x >= 0.95 { t95 = t }
                if abs(x - 1) < 0.0025 && abs(v) < 0.05 { if tSettled == nil { tSettled = t } } else { tSettled = nil }
                if frame <= 40 { frames.append(String(format: "%.0fms:%.3f", t * 1000, x)) }
            }
            let a = CASpringAnimation()
            a.mass = s.mass; a.stiffness = s.stiffness; a.damping = s.damping
            out.append(String(format: "%@: 95 %% nach %.0f ms, steht (±1 px bei 400 px) nach %.0f ms, Überschwingen %.1f %%, settlingDuration %.0f ms",
                              label, (t95 ?? 0) * 1000, (tSettled ?? 0) * 1000, max(0, peak - 1) * 100, a.settlingDuration * 1000))
            out.append("  120 fps: " + frames.joined(separator: " "))
        }
        return out
    }

    private static func contactSheet(files: [URL], window: NSWindow, region: NSRect, to url: URL) {
        let images = files.compactMap { (try? Data(contentsOf: $0)).flatMap { crop($0, window: window, region: region) } }
        guard let first = images.first else { return }
        let cols = 4
        let rows = (images.count + cols - 1) / cols
        let maxW: CGFloat = 1600
        let cellW = min(CGFloat(first.width), maxW / CGFloat(cols))
        let cellH = cellW * CGFloat(first.height) / CGFloat(first.width)
        let size = NSSize(width: cellW * CGFloat(cols), height: cellH * CGFloat(rows))
        let sheet = NSImage(size: size)
        sheet.lockFocus()
        // Checkerboard shows transparency.
        for r in 0..<Int(size.height / 10 + 1) {
            for c in 0..<Int(size.width / 10 + 1) {
                ((r + c) % 2 == 0 ? NSColor(white: 0.82, alpha: 1) : NSColor(white: 0.62, alpha: 1)).setFill()
                NSRect(x: CGFloat(c) * 10, y: CGFloat(r) * 10, width: 10, height: 10).fill()
            }
        }
        for (i, img) in images.enumerated() {
            let col = i % cols, row = i / cols
            let rect = NSRect(x: CGFloat(col) * cellW, y: size.height - CGFloat(row + 1) * cellH, width: cellW, height: cellH)
            NSImage(cgImage: img, size: rect.size).draw(in: rect)
            NSColor.red.setStroke()
            NSBezierPath(rect: rect).stroke()
            NSString(string: "\(i)").draw(at: NSPoint(x: rect.minX + 4, y: rect.maxY - 16),
                                          withAttributes: [.font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.red])
        }
        sheet.unlockFocus()
        write(sheet, to: url)
    }

    // MARK: Figure

    /// The four states of the figure side by side, large, plus work phases.
    private static func marks(to dir: URL) {
        let size = 120.0
        let frames: [(MarkState, Double)] = [(.ruht, 1), (.arbeitet, 0.8), (.arbeitet, 1.6), (.arbeitet, 3.0), (.offen, 1), (.fehler, 1)]
        for (dark, suffix) in [(false, "light"), (true, "dark")] {
            let image = NSImage(size: NSSize(width: size * Double(frames.count), height: size))
            image.lockFocus()
            (dark ? NSColor(white: 0.12, alpha: 1) : NSColor.white).setFill()
            NSRect(x: 0, y: 0, width: size * Double(frames.count), height: size).fill()
            for (i, f) in frames.enumerated() {
                let r = MarkRenderer(size: size, state: .ruht, palette: dark ? .dark : .light, reduced: false)
                r.state = f.0
                var t = 0.0
                while t < f.1 { r.step(seconds: 1.0 / 30); t += 1.0 / 30 }
                guard let ctx = NSGraphicsContext.current?.cgContext else { continue }
                ctx.saveGState()
                ctx.translateBy(x: size * Double(i), y: size)
                ctx.scaleBy(x: 1, y: -1)
                r.draw(in: ctx)
                ctx.restoreGState()
            }
            image.unlockFocus()
            write(image, to: dir.appendingPathComponent("00-mark-\(suffix).png"))

            // Actual UI sizes, with and without motion. Columns match the large strip.
            for reduced in [false, true] {
                let sizes = [18.0, 24.0, 40.0]
                let cell = 64.0
                let margin = 40.0
                let gridSize = NSSize(width: margin + cell * Double(frames.count), height: cell * Double(sizes.count))
                let grid = NSImage(size: gridSize)
                grid.lockFocus()
                (dark ? NSColor(white: 0.12, alpha: 1) : NSColor.white).setFill()
                NSRect(origin: .zero, size: gridSize).fill()
                for (row, markSize) in sizes.enumerated() {
                    let y = gridSize.height - cell * Double(row + 1)
                    ("\(Int(markSize)) pt" as NSString).draw(at: NSPoint(x: 4, y: y + 25), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: dark ? NSColor.white : NSColor.black
                    ])
                    for (column, frame) in frames.enumerated() {
                        let renderer = MarkRenderer(size: markSize, state: .ruht, palette: dark ? .dark : .light, reduced: reduced)
                        renderer.state = frame.0
                        var elapsed = 0.0
                        while elapsed < frame.1 { renderer.step(seconds: 1.0 / 30); elapsed += 1.0 / 30 }
                        guard let context = NSGraphicsContext.current?.cgContext else { continue }
                        context.saveGState()
                        context.translateBy(x: margin + cell * Double(column) + (cell - markSize) / 2,
                                            y: y + (cell + markSize) / 2)
                        context.scaleBy(x: 1, y: -1)
                        renderer.draw(in: context)
                        context.restoreGState()
                    }
                }
                grid.unlockFocus()
                let motion = reduced ? "reduced" : "motion"
                write(grid, to: dir.appendingPathComponent("00-mark-contexts-\(suffix)-\(motion).png"))
            }
        }
    }

    private static func writePNG(_ image: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    private static func write(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
#endif
