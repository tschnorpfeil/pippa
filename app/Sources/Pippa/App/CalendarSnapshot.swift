import AppKit
import PippaCore

#if DEBUG
/// FLOW-10 native fixture: `PIPPA_DEMO=1 PIPPA_SNAPSHOT=<dir> PIPPA_SNAPSHOT_ONLY=calendar`. Drives the real routing,
/// conversation and views with synthetic events from `DemoIntegrations` — never EventKit, never a permission prompt.
/// Writes `calendar.txt` and screenshots of offer → read → follow-up → denied → error → empty.
@MainActor enum CalendarSnapshot {
    static func run(model: AppModel, shell: ShellController, directory: URL) async {
        var observations: [String] = []
        var failures: [String] = []
        func verify(_ condition: Bool, _ description: String) {
            observations.append("\(condition ? "PASS" : "FAIL"): \(description)")
            if !condition { failures.append(description) }
        }
        func finish() {
            let heading = failures.isEmpty ? "PASS: calendar fixture" : "FAIL: calendar fixture"
            try? (heading + "\n" + observations.joined(separator: "\n") + "\n")
                .write(to: directory.appendingPathComponent("calendar.txt"), atomically: true, encoding: .utf8)
        }
        guard let stub = model.engine as? StubEngine, DevSnapshot.directory?.standardizedFileURL == directory.standardizedFileURL else {
            verify(false, "Requires demo engine and isolated PIPPA_SNAPSHOT directory")
            finish(); return
        }
        let demo = stub.integrations
        NSApp.activate()
        func settle() async {
            for _ in 0..<200 {
                if !model.isActiveWork { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            try? await Task.sleep(for: .milliseconds(650))
        }
        func ask(_ text: String) async -> ConversationMessage? {
            model.route(text)
            await settle()
            return model.conversations.current?.messages.last
        }
        func snapshot(_ name: String) {
            verify(capture(shell, to: directory.appendingPathComponent(name + ".png")), "Screenshot \(name)")
        }
        let calendar = Calendar.autoupdatingCurrent
        let noAttachmentWords = { (text: String) in !text.lowercased().contains("attach") && !text.contains("Anhang") && !text.contains("anhäng") }

        model.newConversation()
        let offer = await ask("Fass mir kurz meine anstehenden Termine diese Woche zusammen")
        verify(offer?.role == .assistant && offer?.calendar?.state == .needsAccess, "Calendar question without access offers access (no model, no attachment)")
        verify(offer.map { noAttachmentWords($0.text) } == true, "Offer never asks for an attachment")
        verify(demo.calendarReads.isEmpty, "Nothing read before access")
        snapshot("calendar-01-offer")

        if let offer { model.allowCalendarAccess(offer) }
        await settle()
        let week = model.conversations.current?.messages.last
        verify(week?.calendar?.state == .read && week?.calendar?.range.kind == .restOfWeek, "After allowing, the rest of this week is read and answered")
        verify(demo.calendarReads.count == 1 && demo.calendarReads.first?.end == calendar.dateInterval(of: .weekOfYear, for: Date())?.end,
               "Exactly one bounded read until the end of the local week")
        verify(week.map { noAttachmentWords($0.text) && $0.text.contains("_") } == true, "Answer shows source line, no attachment request")
        verify(week?.calendar?.card?.days.isEmpty == false, "The week is shown as a card with days")
        snapshot("calendar-02-week")

        let tomorrow = await ask("und morgen?")
        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
        verify(tomorrow?.calendar?.state == .read && tomorrow?.calendar?.range.start == tomorrowStart, "Follow-up „und morgen?“ reads tomorrow in the same conversation")
        verify(tomorrow?.text.contains("Team-Standup (Beispiel)") == true, "Tomorrow's synthetic recurring event is listed")
        snapshot("calendar-03-tomorrow")

        demo.set(.calendar, .denied)
        let denied = await ask("Was ist am Donnerstag?")
        verify(denied?.calendar?.state == .denied && denied?.text == CalendarConversation.deniedText, "Denied access is said as such, not as an empty calendar")
        snapshot("calendar-04-denied")

        demo.set(.calendar, .granted)
        demo.calendarFails = true
        let failed = await ask("Meine Termine nächste Woche?")
        verify(failed?.calendar?.state == .failed && failed?.text == CalendarReadResult.failureText, "Technical error is said as such")
        snapshot("calendar-05-error")

        demo.calendarFails = false
        demo.calendarEvents = []
        let empty = await ask("Was steht am Wochenende in meinem Kalender?")
        verify(empty?.calendar?.state == .read && empty?.text.contains(CalendarReadResult.emptyText) == true,
               "Zero events: only a real read says the calendar is empty")
        snapshot("calendar-06-empty")
        verify(demo.createdCount == 0, "Reading never writes to the calendar")
        finish()
    }

    /// Captures only Pippa's current window; fallback draws its native view hierarchy.
    private static func capture(_ shell: ShellController, to destination: URL) -> Bool {
        let window = shell.panel
        let temporary = destination.deletingLastPathComponent().appendingPathComponent("calendar-window-\(UUID().uuidString).png")
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
