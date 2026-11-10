import AppKit
import PiRPC
import PippaCore
import PDFKit
import ScreenCaptureKit
import SwiftUI

/// `Pippa --snapshot <folder>`: renders the chat window with sample conversations, light and dark, as PNGs. For
/// checking the layout without screen access; nothing is read from or written to the person's conversations.
/// With `PIPPA_SNAPSHOT_LIVE=1` the window server draws each window, Liquid Glass included, and ScreenCaptureKit takes
/// it from Pippa's own windows, which needs no Screen Recording permission. Only a 2-point edge of each window shows.
@MainActor
enum Snapshots {
    private static var fixtureDirectory: URL?
    private static let live = ProcessInfo.processInfo.environment["PIPPA_SNAPSHOT_LIVE"] == "1"
    /// Live captures that failed: the run then ends with 1, and no older PNG stands in for them.
    private static var failed: [String] = []
    static func run(into folder: URL) async -> Int32 {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Theme.drawsGlass = live
        if ProcessInfo.processInfo.environment["PIPPA_SNAPSHOT_PROVIDERS_ONLY"] == "1" {
            let setup = SetupModel.shared
            setup.showForSnapshot(.ready(adoptedFrom: nil))
            for dark in [false, true] {
                await render(SettingsView(tab: .ai, settings: .shared, setup: setup), size: NSSize(width: SettingsWindow.width, height: 820), dark: dark,
                             to: folder.appendingPathComponent("providers-\(dark ? "dark" : "light").png"))
            }
            setup.showForSnapshot(.askDownload(bytes: 5_400_000_000))
            await render(SettingsView(tab: .ai, settings: .shared, setup: setup), size: NSSize(width: SettingsWindow.width, height: 820), dark: false,
                         to: folder.appendingPathComponent("providers-first-run.png"))
            let preview = PiProviderSettingsModel()
            preview.providers = (try? JSONDecoder().decode([PiProvider].self, from: Data(#"[{"id":"openrouter","name":"OpenRouter","configured":false,"methods":[],"models":[]}]"#.utf8))) ?? []
            preview.selectedID = "openrouter"
            preview.prompt = try? JSONDecoder().decode(PiProviderEvent.self, from: Data(#"{"event":"prompt","id":"key","type":"secret","message":"API key","placeholder":"Enter API key"}"#.utf8))
            await render(ProviderLoginSheet(provider: preview), size: NSSize(width: 520, height: 400), dark: false,
                         to: folder.appendingPathComponent("provider-login.png"))
            return finish(folder)
        }
        let fixtures = folder.appendingPathComponent("fixtures", isDirectory: true)
        try? FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        fixtureDirectory = fixtures
        let image = NSImage(size: NSSize(width: 480, height: 320))
        image.lockFocus()
        NSColor(calibratedRed: 0.82, green: 0.90, blue: 0.96, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 480, height: 320).fill()
        ("Pippa · Preview" as NSString).draw(at: NSPoint(x: 40, y: 145), withAttributes: [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black])
        image.unlockFocus()
        if let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
            try? bitmap.representation(using: .png, properties: [:])?.write(to: fixtures.appendingPathComponent("IMG-2041.png"))
        }
        let pdf = PDFDocument()
        if let page = PDFPage(image: image) { pdf.insert(page, at: 0) }
        pdf.write(to: fixtures.appendingPathComponent("Rechnung-Oktober.pdf"))
        let chat = ChatModel.shared
        let setup = SetupModel.shared
        setup.showForSnapshot(.ready(adoptedFrom: nil))
        // Name, how to set it up, window height, whether "Worked for …" starts open, and whether "About this answer" shows.
        let scenes: [(String, () -> Void, CGFloat, Bool, Bool)] = [
            ("welcome", { chat.showSample([], current: nil, answering: false) }, 760, false, false),
            ("conversation", { chat.showSample(sampleConversations(), current: "c1", answering: false) }, 760, false, false),
            ("context", { chat.showSample(sampleConversations(), current: "c1", answering: false) }, 760, false, true),
            ("answering", { chat.showSample(sampleConversations(answering: true), current: "c1", answering: true) }, 760, false, false),
            // The question is out, the AI on this Mac still loads: nothing from Pi yet.
            ("starting", { chat.showSample(sampleConversations(answering: true, starting: true), current: "c1", answering: true, starting: true) }, 760, false, false),
            ("steps", { chat.showSample(sampleConversations(answering: true), current: "c1", answering: true) }, 760, true, false),
            // Words of the answer coming in: her handwriting instead of the mark.
            ("writing", { chat.showSample(sampleConversations(answering: true, writing: true), current: "c1", answering: true, writing: true) }, 760, false, false),
            ("approval", {
                chat.showSample(sampleConversations(answering: true), current: "c1", answering: true)
                askSampleQuestion()
            }, 760, false, false),
            ("error", { chat.showSample(sampleConversations(failed: true), current: "c1", answering: false) }, 760, false, false),
            ("cards", { chat.showSample(sampleCards() + sampleConversations(), current: "cards", answering: false) }, 1480, false, false),
            ("setup", {
                chat.showSample([], current: nil, answering: false)
                setup.showForSnapshot(.downloading(progress: 0.42, remaining: 380))
            }, 760, false, false),
            ("setup-failed", {
                chat.showSample([], current: nil, answering: false)
                setup.showForSnapshot(.failed(PiSetupProblem(message: "This Mac has too little memory to run the AI itself.",
                                                             details: "No local model fits this Mac", canRetry: false)))
            }, 760, false, false),
            ("setup-space", {
                chat.showSample([], current: nil, answering: false)
                setup.showForSnapshot(.failed(PiSetupProblem(.notEnoughSpace(bytes: 3_400_000_000))), detailsOpen: true)
            }, 760, false, false),
            ("attachments", {
                setup.showForSnapshot(.ready(adoptedFrom: nil))
                chat.showSample(sampleConversations(), current: nil, answering: false)
                chat.attachments = [fixtures.appendingPathComponent("Rechnung-Oktober.pdf"), fixtures.appendingPathComponent("IMG-2041.png")]
            }, 760, false, false),
        ]
        for (name, prepare, height, expandsWork, inspector) in scenes {
            prepare()
            // Let a question asked in `prepare` reach the list before drawing.
            for _ in 0..<5 { await Task.yield() }
            for dark in [false, true] {
                let view = ChatView(chat: chat, setup: setup, inspector: inspector).environment(\.expandsWork, expandsWork)
                let file = folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
                await render(view, size: NSSize(width: 1240, height: height), dark: dark, to: file)
            }
            chat.attachments = []
            Approvals.shared.cancelAll()
        }
        for dark in [false, true] {
            await render(StartingExplanation(), size: NSSize(width: 312, height: 160), dark: dark, chrome: false, fits: true,
                         to: folder.appendingPathComponent("starting-info-\(dark ? "dark" : "light").png"))
        }
        chat.showSample([], current: nil, answering: false)
        setup.showForSnapshot(.ready(adoptedFrom: nil))
        chat.attachments = [fixtures.appendingPathComponent("Rechnung-Oktober.pdf"), fixtures.appendingPathComponent("IMG-2041.png")]
        for width: CGFloat in [640, 860] {
            await render(ChatView(chat: chat, setup: setup, inspector: false), size: NSSize(width: width, height: 520), dark: false,
                         to: folder.appendingPathComponent("attachments-narrow-\(Int(width)).png"))
        }
        chat.attachments = []
        setup.showForSnapshot(.ready(adoptedFrom: nil))
        // One picture per settings page, without the toolbar (offscreen drawing leaves out its glass). Fixed permission
        // states, so the picture doesn't depend on this Mac.
        let permissions = PermissionStatus(sample: [.calendar: .granted, .reminders: .notDetermined, .photos: .denied,
                                                    .mail: .unavailable("")])
        for tab in SettingsTab.allCases {
            let page = SettingsView(tab: tab, settings: .shared, setup: setup, permissions: permissions)
            for dark in [false, true] {
                await render(page, size: NSSize(width: SettingsWindow.width, height: 400), dark: dark, chrome: false, fits: true,
                             to: folder.appendingPathComponent("settings-\(tab.rawValue)-\(dark ? "dark" : "light").png"))
            }
        }
        return finish(folder)
    }

    private static func finish(_ folder: URL) -> Int32 {
        print(folder.path)
        guard failed.isEmpty else {
            print("live snapshot failed: \(failed.joined(separator: ", "))")
            return 1
        }
        return 0
    }

    /// Pi asks to search the web while the answer runs. The question goes to Pippa's own list (never the alert): a
    /// presenter is registered first, and no view's `reveal` may bring the real chat window up meanwhile.
    private static func askSampleQuestion() {
        let approvals = Approvals.shared
        for _ in 0..<20 where approvals.hasPresenter { approvals.dismiss("chat") }
        approvals.present("snapshot")
        let request = PiUIRequest(id: "snapshot-web", method: "confirm", title: "Darf Pippa im Internet suchen?",
                                  message: "Pippa möchte bei DuckDuckGo suchen nach:\n\n„aktuelle Kosten MSCI World ETF Sparplan“")
        Task {
            _ = await approvals.ask(request)
            approvals.dismiss("snapshot")
        }
    }

    /// `chrome`: a titled window with its buttons (the chat); without, just the view (a settings page). `fits`: the
    /// height follows the view once it has loaded (a settings page, as tall as its window).
    private static func render<V: View>(_ view: V, size: NSSize, dark: Bool, chrome: Bool = true, fits: Bool = false, to file: URL) async {
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate()
        let window = SnapshotWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: chrome ? [.titled, .closable, .resizable, .fullSizeContentView] : [.borderless],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.environment(\.controlActiveState, .key))
        window.contentView = host
        // ScreenCaptureKit only takes a window that touches a screen: a live one keeps a 2-point edge on the leftmost
        // screen, so no other display lies under the rest of it.
        let left = NSScreen.screens.min { $0.frame.minX < $1.frame.minX }?.frame ?? .zero
        window.setFrameOrigin(live ? NSPoint(x: left.minX - size.width + 2, y: left.minY + 80) : NSPoint(x: -4000, y: -4000))
        window.makeKeyAndOrderFront(nil)
        // Let SwiftUI lay out, load images and run onAppear before drawing.
        for _ in 0..<6 { try? await Task.sleep(for: .milliseconds(120)); host.layoutSubtreeIfNeeded() }
        if fits {
            window.setContentSize(NSSize(width: size.width, height: host.fittingSize.height))
            host.layoutSubtreeIfNeeded()
        }
        if live {
            try? FileManager.default.removeItem(at: file)
            try? await Task.sleep(for: .milliseconds(400))   // the window server's first frame, glass included
            let png = await capture(window).flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
            if (try? png?.write(to: file)) == nil { failed.append(file.lastPathComponent) }
            window.orderOut(nil)
            return
        }
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
        window.orderOut(nil)
    }

    /// The window as the window server composites it, at its backing scale.
    private static func capture(_ window: NSWindow) async -> CGImage? {
        do {
            let content = try await SCShareableContent.currentProcess
            guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                print("live snapshot: window \(window.windowNumber) not shareable"); return nil
            }
            let config = SCStreamConfiguration()
            config.width = Int(target.frame.width * window.backingScaleFactor)
            config.height = Int(target.frame.height * window.backingScaleFactor)
            config.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target),
                                                              configuration: config)
        } catch {
            print("live snapshot failed: \(error.localizedDescription)"); return nil
        }
    }

    /// Keeps the size it is given, also taller than the screen (a normal window is clamped to it), and draws as key
    /// so controls keep their active tint in snapshots.
    private final class SnapshotWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { true }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// One answer with a table and every kind of result card that comes from this Mac's apps.
    private static func sampleCards() -> [Conversation] {
        let monday = Date(timeIntervalSinceReferenceDate: 815_904_000)
        func decode<T: Decodable>(_ json: String) -> T? { try? JSONDecoder().decode(T.self, from: Data(json.utf8)) }
        let calendar: CalendarCard? = decode("""
        {"title": "Diese Woche", "rangeLabel": "Mo., 3. – So., 9. Nov.", "showsCalendar": true,
         "footer": "Kalender auf diesem Mac · gelesen um 09:41",
         "days": [
          {"label": "Montag, 3. Nov.", "entries": [
            {"time": "08:30 – 09:15", "title": "Zahnarzt Dr. Weber", "calendar": "Privat", "color": "#E5484D", "inactive": false,
             "location": "Lindenstraße 12", "eventID": "e1", "start": \(monday.timeIntervalSinceReferenceDate)},
            {"time": "14:00 – 15:00", "title": "Abstimmung Umzug", "calendar": "Familie", "color": "#30A46C", "inactive": false,
             "note": "vorläufig", "eventID": "e2", "start": \(monday.timeIntervalSinceReferenceDate)}]},
          {"label": "Mittwoch, 5. Nov.", "entries": [
            {"time": "19:30 – 21:00", "title": "Elternabend 3b", "calendar": "Familie", "color": "#30A46C", "inactive": false,
             "location": "Grundschule am Park", "eventID": "e3", "start": \(monday.timeIntervalSinceReferenceDate)},
            {"time": "ganztägig", "title": "Werkstatt: Winterreifen", "calendar": "Privat", "color": "#E5484D", "inactive": true,
             "note": "abgesagt", "eventID": "e4", "start": \(monday.timeIntervalSinceReferenceDate)}]}]}
        """)
        let mail: MailCard? = decode("""
        {"query": "Nebenkosten", "unread": false, "total": 7, "footer": "Mail auf diesem Mac · 3 von 7",
         "items": [
          {"subject": "Nebenkostenabrechnung 2025", "sender": "Hausverwaltung Berger", "dateLabel": "Fr., 31. Okt.",
           "preview": "Sehr geehrte Frau Schneider, anbei erhalten Sie die Abrechnung der Betriebskosten für das Jahr 2025 mit einer Nachzahlung von 184,37 €."},
          {"subject": "Re: Zählerstand Wasser", "sender": "Stadtwerke Kundenservice", "dateLabel": "Di., 21. Okt.",
           "preview": "Vielen Dank für Ihre Meldung. Der Zählerstand wurde übernommen."},
          {"subject": "Termin Ablesung Heizung", "sender": "Techem", "dateLabel": "09:12", "preview": ""}]}
        """)
        let reminders: ReminderCard? = decode("""
        {"title": "Erinnerungen · offen", "total": 3, "showsList": true, "footer": "Erinnerungen auf diesem Mac",
         "items": [
          {"title": "Nachzahlung überweisen", "list": "Haushalt", "dueLabel": "Gestern", "overdue": true},
          {"title": "Sparplan prüfen", "list": "Finanzen", "dueLabel": "Fr., 7. Nov.", "overdue": false},
          {"title": "Einspruch Finanzamt vorbereiten", "list": "Finanzen", "overdue": false}]}
        """)
        let prepared = PreparedFilesCard(jobID: UUID(), files: [fixtureDirectory?.appendingPathComponent("Rechnung-Oktober.pdf") ?? URL(fileURLWithPath: "/Users/me/Desktop/Umzug-Fotos.pdf")], pageCount: 12,
                                         totalBytes: 3_250_000, sizeLimitBytes: nil, withinLimit: nil, note: "")
        var answer = ChatMessage(role: .assistant, text: """
        Hier ist der Überblick über die Nebenkosten der letzten drei Jahre:

        | Jahr | Vorauszahlung | Abrechnung | Ergebnis |
        |---|---|---|---|
        | 2023 | 1.920,00 € | 1.874,12 € | −45,88 € |
        | 2024 | 1.920,00 € | 2.010,55 € | 90,55 € |
        | 2025 | 2.040,00 € | 2.224,37 € | 184,37 € |

        Dazu deine Termine, die passenden Mails und was noch offen ist.
        """)
        answer.cards = [calendar.map(ResultCard.calendar), mail.map(ResultCard.mail), reminders.map(ResultCard.reminders),
                        .preparedFiles(prepared)].compactMap { $0 }
        answer.steps = [ChatStep(id: "c1", label: "Reading Calendar", done: true), ChatStep(id: "c2", label: "Searching Mail for “Nebenkosten”", done: true),
                        ChatStep(id: "c3", label: "Reading Reminders", done: true), ChatStep(id: "c4", label: "Making one PDF", done: true)]
        answer.duration = 24
        answer.sources = [ChatSource(kind: .mail, name: "Nebenkostenabrechnung 2025", location: "", detail: "Hausverwaltung Berger")]
        return [Conversation(id: "cards", title: "Nebenkosten und Termine", updated: Date(), messages: [
            ChatMessage(role: .user, text: "Wie haben sich die Nebenkosten entwickelt, und was steht diese Woche an?"), answer,
        ])]
    }

    private static func sampleConversations(answering: Bool = false, failed: Bool = false, starting: Bool = false,
                                            writing: Bool = false) -> [Conversation] {
        let now = Date()
        var answer = ChatMessage(role: .assistant, text: """
        Dein aktueller Stand ist **ETF-Portfolio.md**, zuletzt geändert am 1. November 2026.

        ## Überblick
        - **MSCI World:** 62 % · Sparrate 400 €
        - **Emerging Markets:** 18 % · Sparrate 120 €
        - **Anleihen:** 20 % · keine Sparrate

        Die anderen beiden Dateien (`ETF-Ideen.md`, `ETF-2024.md`) sind älter und nennen andere Zahlen.
        """)
        answer.steps = [
            ChatStep(id: "1", label: "Searching files for “ETF”", done: true),
            ChatStep(id: "2", label: "Reading ETF-Portfolio.md", done: true),
            ChatStep(id: "3", label: "Reading ETF-Ideen.md", done: true),
        ]
        let sample = CreatedItem(integration: .reminders, identifier: "snapshot", modified: nil)
        answer.receipts = [PippaMCPWriteReceipt(action: "reminderAdd", outcome: "done", name: "Sparplan prüfen · Fr., 7. Nov.", created: sample)]
        answer.duration = 18
        if answering {
            answer.text = ""
            answer.receipts = []
            answer.steps = [ChatStep(id: "1", label: "Searching files for “ETF”", done: true), ChatStep(id: "2", label: "Reading ETF-Portfolio.md", done: false)]
            answer.thinking = "Die Person fragt nach der aktuellen ETF-Übersicht. Es gibt drei Dateien; ETF-Portfolio.md ist die neueste (updated 2026-11-01). Ich lese sie und nenne die Aufteilung." 
        }
        if writing {
            answer.steps[1].done = true
            answer.text = "Dein aktueller Stand ist **ETF-Portfolio.md**, zuletzt geändert am"
        }
        if starting {
            answer.steps = []
            answer.thinking = nil
        }
        if failed {
            answer.text = ""
            answer.receipts = []
            answer.steps = [ChatStep(id: "1", label: "Reading Calendar", done: true, failed: true)]
            answer.error = "Pippa darf deinen Kalender nicht lesen. Erlaube es in den Systemeinstellungen unter Datenschutz & Sicherheit."
        }
        var letter = ChatMessage(role: .assistant, text: """
        Die Nachzahlung von **184,37 €** musst du **bis zum 15. November 2026** überweisen.

        Einwände gehen innerhalb von vier Wochen nach Zugang, also bis **19. November 2026**.
        """)
        letter.steps = [ChatStep(id: "4", label: "Reading Brief-Stadtwerke.pdf", done: true)]
        letter.unsupportedDates = ["19. November 2026"]
        letter.checkedDates = ["15. November 2026"]
        letter.sources = [ChatSource(kind: .file, name: "Brief-Stadtwerke.pdf", location: "/Users/me/Downloads/Brief-Stadtwerke.pdf", detail: "Ganze Seite")]
        var undone = PippaMCPWriteReceipt(action: "calendarAdd", outcome: "done", name: "Fr., 14. Nov., 09:00 – Nachzahlung", created: sample)
        undone.undo = "removed"
        letter.receipts = [PippaMCPWriteReceipt(action: "reminderAdd", outcome: "done", name: "Nachzahlung überweisen · Fr., 14. Nov.", created: sample), undone]
        letter.context = ContextUsage(tokens: 12_431, window: 32_768)
        letter.duration = 6
        if !answering && !failed {
            answer.sources = [ChatSource(kind: .file, name: "ETF-Portfolio.md", location: "/Users/me/brain/ETF-Portfolio.md", detail: nil),
                              ChatSource(kind: .file, name: "ETF-Ideen.md", location: "/Users/me/brain/ETF-Ideen.md", detail: nil)]
            answer.checkedDates = ["1. November 2026"]
        }
        var messages = [ChatMessage(role: .user, text: "Wo ist meine aktuelle ETF-Übersicht in brain und was steht drin?"), answer]
        if !answering && !failed {
            messages += [ChatMessage(role: .user, text: "Bis wann muss ich hier etwas tun?", files: ["/Users/me/Downloads/Brief-Stadtwerke.pdf"]), letter]
        }
        let first = Conversation(id: "c1", title: "Wo ist meine aktuelle ETF-Übersicht?", updated: now, messages: messages)
        return [
            first,
            Conversation(id: "c2", title: "Frist im Brief vom Finanzamt", updated: now.addingTimeInterval(-3600 * 5), messages: [
                ChatMessage(role: .user, text: "Bis wann?", files: ["/Users/me/Downloads/Finanzamt.pdf"]),
                ChatMessage(role: .assistant, text: "Einspruch bis **16. Dezember 2026**, steht auf Seite 2."),
            ]),
            Conversation(id: "c3", title: "Fotos vom Umzug als PDF", updated: now.addingTimeInterval(-3600 * 30), messages: [
                ChatMessage(role: .user, text: "", files: ["/Users/me/Desktop/IMG_2041.jpeg"]),
                ChatMessage(role: .assistant, text: "Fertig: ein PDF mit 12 Seiten, 3,1 MB."),
            ]),
            Conversation(id: "c4", title: "Termine nächste Woche", updated: now.addingTimeInterval(-3600 * 24 * 4), messages: [
                ChatMessage(role: .assistant, text: "Drei Termine: Montag Zahnarzt, Mittwoch Elternabend, Freitag Werkstatt."),
            ]),
            Conversation(id: "c5", title: "Kündigungsfrist Mietvertrag", updated: now.addingTimeInterval(-3600 * 24 * 20), messages: [
                ChatMessage(role: .assistant, text: "Drei Monate zum Monatsende, § 4 Absatz 2."),
            ], pinned: true),
        ]
    }
}

extension ChatModel {
    /// Snapshots only: show sample conversations without touching the saved ones.
    func showSample(_ conversations: [Conversation], current: String?, answering: Bool, starting: Bool = false,
                    writing: Bool = false) {
        replaceForSnapshot(conversations, current: current, answering: answering, starting: starting, writing: writing)
    }
}
