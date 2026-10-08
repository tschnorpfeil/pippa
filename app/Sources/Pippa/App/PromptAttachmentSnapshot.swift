import AppKit
import PippaCore

#if DEBUG
/// Runs only against the synthetic snapshot history and demo engine.
@MainActor enum PromptAttachmentSnapshot {
    static func run(model: AppModel, shell: ShellController, directory: URL) async {
        var failures: [String] = []
        var observations: [String] = []
        func verify(_ condition: Bool, _ description: String) {
            observations.append("\(condition ? "PASS" : "FAIL"): \(description)")
            if !condition { failures.append(description) }
        }
        func finish() {
            let heading = failures.isEmpty ? "PASS: prompt attachment fixture" : "FAIL: prompt attachment fixture"
            try? (heading + "\n" + observations.joined(separator: "\n") + "\n")
                .write(to: directory.appendingPathComponent("promptattachments.txt"), atomically: true, encoding: .utf8)
        }
        guard model.engine is StubEngine, DevSnapshot.directory?.standardizedFileURL == directory.standardizedFileURL else {
            verify(false, "Requires demo engine and isolated PIPPA_SNAPSHOT directory")
            finish(); return
        }
        NSApp.activate()
        NSApp.appearance = NSAppearance(named: .darkAqua)
        model.conversationSize = CGSize(width: 400, height: 700)
        let names = ["Strategie.md", "Maßnahmenplan.md", "Notizen mit einem langen vollständigen Dateinamen.md", "Budget.md", "Zeitplan.md", "Vergleich A.md", "Vergleich B.md"]
        let files = names.map { directory.appendingPathComponent($0) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for file in files {
                try "# Synthetische Testdatei\nNur lokale UI-Testdaten.\n".write(to: file, atomically: true, encoding: .utf8)
            }
        } catch {
            verify(false, "Could not create synthetic files: \(error.localizedDescription)")
            finish(); return
        }
        func snapshot(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(650))
            verify(capture(shell, to: directory.appendingPathComponent(name + ".png")), "Screenshot \(name)")
        }
        func send(_ text: String) async -> Bool {
            model.conversations.send(text)
            for _ in 0..<200 {
                if !model.conversations.isRunning {
                    verify(model.conversations.error == nil, "Request completes: \(text)")
                    return model.conversations.error == nil
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            verify(false, "Request timed out: \(text)")
            model.conversations.stop()
            return false
        }
        func pending() -> [URL] {
            model.conversations.current.map { ConversationPromptAttachments.pendingFiles(in: $0) } ?? []
        }
        func users() -> [ConversationMessage] {
            model.conversations.current?.messages.filter { $0.role == .user } ?? []
        }
        model.newConversation()
        let firstBatch = Array(files.prefix(5)), secondBatch = Array(files.suffix(2))
        model.attach(.files(firstBatch), items: firstBatch, startsFresh: false, open: true)
        verify(pending() == firstBatch, "Five initial documents wait above composer")
        verify(users().isEmpty, "Attachment preparation does not send a question")
        await snapshot("promptattachments-01-pending")
        guard await send("Vergleiche diese fünf Dokumente.") else { finish(); return }
        verify(users().last?.attachments == firstBatch && pending().isEmpty, "First prompt owns its five attachments and composer clears")
        await snapshot("promptattachments-02-first-prompt")
        guard await send("Was ist der wichtigste Punkt?") else { finish(); return }
        verify(users().last?.attachments.isEmpty == true, "Plain followup does not repeat earlier attachments")
        await snapshot("promptattachments-03-plain-followup")
        let topicID = model.conversations.current?.id
        model.attach(.files(secondBatch), items: secondBatch, startsFresh: false, open: true)
        verify(model.conversations.current?.id == topicID && pending() == secondBatch, "Explicit comparison keeps topic and only two new pending documents")
        await snapshot("promptattachments-04-two-new-files")
        guard await send("Vergleiche auch die beiden neuen Dokumente.") else { finish(); return }
        verify(users().last?.attachments == secondBatch && pending().isEmpty, "Second document prompt owns only the new batch")
        await snapshot("promptattachments-05-second-prompt")
        let historical = model.conversations.current?.messages ?? []
        model.removeConversationAttachment(files[0])
        verify(model.conversations.current?.context?.files.contains(files[0]) == false, "Removed document is excluded from future answers")
        verify(model.conversations.current?.messages == historical, "Removing future source preserves every historical message and attachment")
        await snapshot("promptattachments-06-source-removed")
        model.attach(.files([files[0]]), items: [files[0]], startsFresh: false, open: true)
        verify(pending() == [files[0]], "Re-adding same URL creates one new pending attachment")
        verify(users().first?.attachments == firstBatch, "Re-add leaves first prompt evidence intact")
        await snapshot("promptattachments-07-readded")
        guard await send("Prüfe das erste Dokument noch einmal.") else { finish(); return }
        verify(users().last?.attachments == [files[0]] && pending().isEmpty, "Re-added file belongs to its new prompt")
        await snapshot("promptattachments-08-readded-prompt")
        verify(files.allSatisfy {
            (try? String(contentsOf: $0, encoding: .utf8)) == "# Synthetische Testdatei\nNur lokale UI-Testdaten.\n"
        }, "All synthetic original file bytes remain untouched")
        finish()
    }

    /// Captures only Pippa's current window; fallback draws its native view hierarchy.
    private static func capture(_ shell: ShellController, to destination: URL) -> Bool {
        let window = shell.panel
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("promptattachments-window-\(UUID().uuidString).png")
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
