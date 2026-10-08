import AppKit
import PippaCore

#if DEBUG
/// Exercises pill reopening against isolated history through the real attachment and send paths.
@MainActor enum ConversationResumeSnapshot {
    static func run(model: AppModel, shell: ShellController, directory: URL) async {
        var observations: [String] = []
        var failures: [String] = []
        func verify(_ condition: Bool, _ description: String) {
            observations.append("\(condition ? "PASS" : "FAIL"): \(description)")
            if !condition { failures.append(description) }
        }
        func finish() {
            let heading = failures.isEmpty ? "PASS: conversation resume fixture" : "FAIL: conversation resume fixture"
            try? (heading + "\n" + observations.joined(separator: "\n") + "\n")
                .write(to: directory.appendingPathComponent("conversationresume.txt"), atomically: true, encoding: .utf8)
        }
        guard model.engine is StubEngine,
              DevSnapshot.directory?.standardizedFileURL == directory.standardizedFileURL else {
            verify(false, "Requires demo engine and isolated PIPPA_SNAPSHOT directory")
            finish(); return
        }
        NSApp.activate()
        NSApp.appearance = NSAppearance(named: .darkAqua)
        model.conversationSize = DevSnapshot.workspaceSize
        let source = directory.appendingPathComponent("conversationresume-source.md")
        let bytes = "# Synthetische Quelle\nNur isolierte lokale Testdaten.\n"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try bytes.write(to: source, atomically: true, encoding: .utf8)
        } catch {
            verify(false, "Synthetic source created: \(error.localizedDescription)")
            finish(); return
        }
        func waitForAnswer() async -> Bool {
            for _ in 0..<200 {
                if !model.conversations.isRunning {
                    verify(model.conversations.error == nil, "Synthetic answer completes")
                    return model.conversations.error == nil
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            verify(false, "Synthetic answer timed out")
            model.conversations.stop()
            return false
        }
        func snapshot(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(650))
            verify(capture(shell, to: directory.appendingPathComponent(name + ".png")), "Screenshot \(name)")
        }
        model.newConversation()
        model.attach(.files([source]), items: [source], startsFresh: false, open: true)
        verify(model.conversations.current?.context?.files == [source], "Real attachment path retains source")
        verify(model.conversations.current?.messages.contains(where: { $0.role == .user }) == false,
               "Attaching source does not send a prompt")
        model.conversations.send("Fasse diese Quelle zusammen.")
        guard await waitForAnswer() else { finish(); return }
        model.conversations.append(.assistant, (1...24).map { "Abschnitt \($0): Synthetischer Lesetext zur Prüfung der erhaltenen Scrollposition." }.joined(separator: "\n\n"))
        guard let conversation = model.conversations.current else { finish(); return }
        verify(conversation.messages.contains(where: { $0.role == .user && $0.attachments == [source] }),
               "Sent prompt owns its source attachment")
        verify(conversation.messages.contains(where: { $0.role == .assistant }), "Real send creates assistant history")
        let topicID = conversation.id
        let messages = conversation.messages
        let context = conversation.context
        let draft = "Welche Folgefrage passt zu dieser Quelle?"
        model.query = draft
        func unchanged(_ step: String) {
            verify(model.conversations.current?.id == topicID, "\(step): same topic")
            verify(model.conversations.current?.messages == messages, "\(step): messages and prompt evidence unchanged")
            verify(model.conversations.current?.context == context, "\(step): source context unchanged")
            verify(model.query == draft, "\(step): unsent draft preserved")
        }
        let activity = Date(timeIntervalSince1970: 1_800_000_000)
        model.collapse()
        try? await Task.sleep(for: .milliseconds(600))
        verify(model.mode.key == "pill", "Close returns to pill")
        model.recordConversationActivity(at: activity)
        model.conversationViewports[topicID] = ConversationViewport(offsetY: 210, followsLatest: false)
        model.openConversationFromPill(now: activity.addingTimeInterval(9 * 60))
        verify(model.mode.key == "input", "Reopening after nine minutes shows expanded conversation")
        unchanged("Nine-minute reopen")
        try? await Task.sleep(for: .milliseconds(650))
        let firstOffset = readingOffset(in: shell.panel.contentView)
        verify(firstOffset.map { abs($0 - 210) < 8 } == true, "Native scroll view restores reading offset on recent reopen (actual: \(firstOffset ?? -1))")
        model.collapse()
        try? await Task.sleep(for: .milliseconds(600))
        model.recordConversationActivity(at: activity)
        model.openConversationFromPill(now: activity.addingTimeInterval(10 * 60))
        verify(model.mode.key == "resume", "Reopening at ten-minute boundary shows compact resume")
        unchanged("Ten-minute reopen")
        await snapshot("conversationresume-01-compact")
        model.recordConversationActivity(at: Date().addingTimeInterval(-660))
        model.collapse()
        try? await Task.sleep(for: .milliseconds(600))
        model.openConversationFromPill()
        verify(model.mode.key == "resume", "Peeking and closing compact input does not refresh conversation activity")
        model.resumeConversation()
        verify(model.mode.key == "input", "Continue expands compact resume")
        unchanged("Continue")
        await snapshot("conversationresume-02-expanded")
        let expandedOffset = readingOffset(in: shell.panel.contentView)
        verify(expandedOffset.map { abs($0 - 210) < 8 } == true, "Native scroll view restores reading offset after compact expansion (actual: \(expandedOffset ?? -1))")

        model.collapse()
        try? await Task.sleep(for: .milliseconds(600))
        model.recordConversationActivity(at: activity)
        model.conversations.send("Eine weitere synthetische Frage.")
        verify(model.conversations.isRunning, "Real send is running before its actor task executes")
        let runningMessages = model.conversations.current?.messages
        model.openConversationFromPill(now: activity.addingTimeInterval(11 * 60))
        verify(model.mode.key == "input", "Running conversation opens expanded even after idle threshold")
        verify(model.conversations.isRunning, "Reopening does not stop running generation")
        verify(model.conversations.current?.id == topicID && model.conversations.current?.messages == runningMessages,
               "Running reopen preserves topic and messages")
        verify(model.conversations.current?.context == context && model.query == draft,
               "Running reopen preserves source and unsent draft")
        guard await waitForAnswer() else { finish(); return }
        model.show(.notice(title: "Synthetisches Ergebnis", detail: "Nur Testdaten.", buttons: []))
        let resultAnchor = model.cardAnchor
        model.conversations.append(.user, "Nachfrage nach dem Ergebnis")
        model.collapse()
        try? await Task.sleep(for: .milliseconds(600))
        model.recordConversationActivity(at: Date().addingTimeInterval(-660))
        model.openConversationFromPill()
        verify(model.mode.key == "resume", "Completed result does not permanently prevent compact reopening")
        model.resumeConversation()
        verify(model.mode.key == "notice" && model.cardAnchor == resultAnchor,
               "Expanding a previous result preserves its original conversation anchor")
        let historical = model.conversations.current
        model.newConversation()
        verify(model.conversations.current?.id != topicID, "Explicit new topic deliberately changes topic")
        verify(model.conversations.current?.messages.isEmpty == true && model.conversations.current?.context == nil,
               "Explicit new topic starts without messages or source context")
        verify(model.query.isEmpty, "Explicit new topic clears unsent draft")
        verify(model.conversations.history.contains(where: { $0.id == topicID }), "Previous topic remains in isolated history")
        verify(historical?.messages.contains(where: { $0.attachments == [source] }) == true,
               "Previous topic retains prompt-bound source evidence")
        verify((try? String(contentsOf: source, encoding: .utf8)) == bytes, "Synthetic source bytes remain unchanged")
        finish()
    }

    private static func readingOffset(in root: NSView?) -> CGFloat? {
        guard let root else { return nil }
        if let scroll = root as? NSScrollView, scroll.bounds.width > 250,
           let document = scroll.documentView, document.frame.height > scroll.contentView.bounds.height + 100 {
            return scroll.contentView.bounds.minY
        }
        for view in root.subviews {
            if let offset = readingOffset(in: view) { return offset }
        }
        return nil
    }

    /// Captures only Pippa's current window; fallback draws its native view hierarchy.
    private static func capture(_ shell: ShellController, to destination: URL) -> Bool {
        let window = shell.panel
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("conversationresume-window-\(UUID().uuidString).png")
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
        if data == nil, let view = window.contentView,
           let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
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
