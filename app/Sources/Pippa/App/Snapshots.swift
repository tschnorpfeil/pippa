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
            // First run: the choice with a draft already typed (it stays), a Mac that can't run the AI, and the
            // online sheet's steps. Made-up providers; nothing signs in or downloads.
            let chat = ChatModel.shared
            chat.showSample([], current: nil, answering: false)
            chat.draft = "Fasse meinen Mietvertrag zusammen"
            let firstRun: [(String, PiSetupState)] = [
                ("first-run-choice", .askDownload(bytes: 5_400_000_000)),
                ("first-run-downloading", .downloading(progress: 0.42, remaining: 380)),
                ("first-run-unsupported", .failed(PiSetupProblem(message: "This Mac has too little memory to run the AI itself.",
                                                                 details: "No local model fits this Mac", canRetry: false))),
            ]
            for (name, state) in firstRun {
                setup.showForSnapshot(state)
                for dark in [false, true] {
                    await render(ChatView(chat: chat, setup: setup, inspector: false), size: NSSize(width: 1240, height: 760), dark: dark,
                                 to: folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                }
            }
            chat.draft = ""
            let catalog = #"[{"id":"openai","name":"OpenAI","configured":true,"methods":[{"id":"oauth","name":"ChatGPT Plus/Pro"},{"id":"api_key","name":"API key"}],"models":[{"id":"gpt-old","name":"GPT Old"},{"id":"gpt-best","name":"GPT Best"}],"defaultModel":"gpt-best"},{"id":"anthropic","name":"Anthropic","configured":false,"methods":[{"id":"oauth","name":"Claude Pro/Max"},{"id":"api_key","name":"API key"}],"models":[]},{"id":"openrouter","name":"OpenRouter","configured":false,"methods":[{"id":"api_key","name":"API key"}],"models":[]},{"id":"custom","name":"Custom","configured":false,"methods":[],"models":[]}]"#
            let providers = (try? JSONDecoder().decode([PiProvider].self, from: Data(catalog.utf8))) ?? []
            let sheets: [(String, String?, String?)] = [
                ("online-setup-choose", nil, nil), ("online-setup-sign-in", "anthropic", nil),
                ("online-setup-activate", "openai", nil), ("online-setup-error", "anthropic", T("The connection didn’t work. Please try again.", table: "Settings")),
            ]
            setup.showForSnapshot(.downloading(progress: 0.42, remaining: 380))
            for (name, picked, problem) in sheets {
                let model = PiProviderSettingsModel()
                model.providers = providers
                if let picked { model.select(picked) }
                model.problem = problem
                for dark in [false, true] {
                    await render(OnlineSetupSheet(settings: .shared, setup: setup, provider: model, picked: picked, loadsOnAppear: false) {},
                                 size: NSSize(width: 560, height: 460), dark: dark,
                                 to: folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                }
            }
            // The review before sharing (issue #193): made-up texts, Photos set to "Only on this Mac".
            var rules = SourceSharing(); rules.photos = .localOnly
            let destination = ShareDestination(PiModelSelection(providerID: "openai", modelID: "gpt-best", providerName: "OpenAI", modelName: "GPT Best"), recipient: "snapshot-account")
            let plan = SharePlan(destination: destination, question: "Is the notice period in my lease right?", candidates: [
                SharePiece(sources: [.documents], title: "Lease (sample).pdf", text: "§ 4 Notice period\nEither party may end the lease with three months’ notice to the end of a month."),
                SharePiece(sources: [.mail, .calendar], title: T("Pippa’s answer on this Mac", table: "App"),
                           text: "The landlord’s email asks you to confirm by 30 November. Your calendar has nothing that day."),
                SharePiece(sources: [.photos], title: "Picture “Scan 12.jpg”", text: "unused"),
            ], rules: rules)
            chat.review = ShareReview(plan: plan, handoff: false, files: [])
            for dark in [false, true] {
                await render(ShareReviewSheet(chat: chat), size: NSSize(width: 640, height: 720), dark: dark,
                             to: folder.appendingPathComponent("share-review-\(dark ? "dark" : "light").png"))
            }
            chat.review = nil
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
            // A document too long to read at once: "About this answer" lists Pippa's notes on it.
            ("context-notes", { chat.showSample(sampleLongDocument() + sampleConversations(), current: "thesis", answering: false) }, 760, false, true),
            ("answering", { chat.showSample(sampleConversations(answering: true), current: "c1", answering: true) }, 760, false, false),
            // The question is out, the AI on this Mac still loads: nothing from Pi yet.
            ("starting", { chat.showSample(sampleConversations(answering: true, starting: true), current: "c1", answering: true, starting: true) }, 760, false, false),
            ("steps", { chat.showSample(sampleConversations(answering: true), current: "c1", answering: true) }, 760, true, false),
            // An online AI with Mac access went through the inbox with a script: one step for all its calls.
            ("steps-script", { chat.showSample(sampleScript() + sampleConversations(), current: "script", answering: false) }, 760, true, false),
            // Words of the answer coming in: her handwriting instead of the mark.
            ("writing", { chat.showSample(sampleConversations(answering: true, writing: true), current: "c1", answering: true, writing: true) }, 760, false, false),
            ("approval", {
                chat.showSample(sampleConversations(answering: true), current: "c1", answering: true)
                askSampleQuestion()
            }, 760, false, false),
            ("error", { chat.showSample(sampleConversations(failed: true), current: "c1", answering: false) }, 760, false, false),
            // The online AI said "too many requests": Pi waits and tries again, the row counts down.
            ("rate-limit-wait", { chat.showSample(sampleConversations(answering: true, starting: true), current: "c1", answering: true, waiting: 42) }, 760, false, false),
            // Still at its limit after every try: Continue counts down its minute.
            ("rate-limit-continue", { chat.showSample(sampleConversations(limited: true), current: "c1", answering: false) }, 760, false, false),
            ("cards", { chat.showSample(sampleCards() + sampleConversations(), current: "cards", answering: false) }, 1480, false, false),
            // One receipt per answer from the run journal: all checked with Undo, unclear after a crash, and after Undo.
            ("run-receipt", { chat.showSample(sampleRuns() + sampleConversations(), current: "runs", answering: false) }, 900, false, false),
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
                                                    .accessibility: .granted, .mail: .unavailable("")])
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
         "notice": "Nicht gelesen: Reisen (Zeitüberschreitung)",
         "items": [
          {"subject": "Nebenkostenabrechnung 2025", "sender": "Hausverwaltung Berger", "account": "Privat", "dateLabel": "Fr., 31. Okt.",
           "preview": "Sehr geehrte Frau Schneider, anbei erhalten Sie die Abrechnung der Betriebskosten für das Jahr 2025 mit einer Nachzahlung von 184,37 €."},
          {"subject": "Re: Zählerstand Wasser", "sender": "Stadtwerke Kundenservice", "account": "Arbeit", "dateLabel": "Di., 21. Okt.",
           "preview": "Vielen Dank für Ihre Meldung. Der Zählerstand wurde übernommen."},
          {"subject": "Termin Ablesung Heizung", "sender": "Techem", "account": "Privat", "dateLabel": "09:12", "preview": ""}]}
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
        answer.steps = [step("c1", "calendar_read"), step("c2", "mail_search"), step("c3", "reminders_read"), step("c4", "prepare_files")]
        answer.duration = 24
        answer.sources = [ChatSource(kind: .mail, name: "Nebenkostenabrechnung 2025", location: "", detail: "Hausverwaltung Berger")]
        return [Conversation(id: "cards", title: "Nebenkosten und Termine", updated: Date(), messages: [
            ChatMessage(role: .user, text: "Wie haben sich die Nebenkosten entwickelt, und was steht diese Woche an?"), answer,
        ])]
    }

    /// A thesis read part by part (runtime/pippa-tools/digest.ts): the answer rests on Pippa's notes.
    private static func sampleRuns() -> [Conversation] {
        let sample = CreatedItem(integration: .calendar, identifier: "snapshot", modified: nil)
        var tidy = ChatMessage(role: .assistant, text: "Erledigt: zwei Termine eingetragen und die Rechnung ins Archiv verschoben.")
        tidy.receipts = [PippaMCPWriteReceipt(action: "calendarAdd", outcome: "done", name: "Mo., 24. Nov., 09:00 – Zahnarzt", created: sample),
                         PippaMCPWriteReceipt(action: "calendarAdd", outcome: "done", name: "Di., 25. Nov., 18:00 – Elternabend", created: sample)]
        tidy.run = RunSummary(run: UUID(), changes: 3, checked: 3, undoable: 3)
        tidy.duration = 9
        var cut = ChatMessage(role: .assistant, text: "")
        cut.run = RunSummary(run: UUID(), changes: 2, checked: 1, unclear: 1)
        var undone = ChatMessage(role: .assistant, text: "Drei Erinnerungen für die Steuer sind angelegt.")
        undone.run = RunSummary(run: UUID(), changes: 3, checked: 3, undone: 2, left: 1)
        undone.duration = 5
        var sorted = ChatMessage(role: .assistant, text: "Erledigt: 18 Rechnungen liegen jetzt im Ordner „Rechnungen“.")
        sorted.run = RunSummary(run: UUID(), changes: 18, checked: 18, undoable: 18, mailMoves: 18)
        sorted.duration = 31
        return [Conversation(id: "runs", title: "Woche vorbereiten", updated: Date(), messages: [
            ChatMessage(role: .user, text: "Trag die Termine aus dem Brief ein und leg die Rechnung ins Archiv."), tidy,
            ChatMessage(role: .user, text: "Und die Termine für Dezember?"), cut,
            ChatMessage(role: .user, text: "Erinnere mich an die Steuerunterlagen."), undone,
            ChatMessage(role: .user, text: "Sortier die Rechnungen aus dem Posteingang in „Rechnungen“."), sorted,
        ])]
    }

    private static func sampleLongDocument() -> [Conversation] {
        var answer = ChatMessage(role: .assistant, text: """
        Die Arbeit untersucht, wie sich **Wärmepumpen in Altbauten** rechnen.

        - **Methode:** 42 Gebäude, Messzeitraum zwei Heizperioden
        - **Ergebnis:** Jahresarbeitszahl im Mittel 3,4; unter 2,8 nur ohne Dämmung der obersten Geschossdecke
        - **Fazit:** wirtschaftlich ab einer Vorlauftemperatur unter 55 °C

        Ich habe das Dokument in Teilen gelesen und mir Notizen gemacht. Für ein genaues Zitat lese ich die Stelle nach.
        """)
        answer.steps = [step("t1", "read", ["path": "/Users/me/Documents/Thesis.docx"], seconds: 312)]
        answer.duration = 341
        answer.sources = [ChatSource(kind: .file, name: "Thesis.docx", location: "/Users/me/Documents/Thesis.docx", detail: nil,
                                     notes: "/Users/me/Library/Application Support/Pippa/digests/Thesis.docx.3f9a1c2b7d.md")]
        answer.context = ContextUsage(tokens: 9_870, window: 16_384)
        return [Conversation(id: "thesis", title: "Thesis zusammenfassen", updated: Date(), messages: [
            ChatMessage(role: .user, text: "Fass mir die Thesis zusammen.", files: ["/Users/me/Documents/Thesis.docx"]), answer,
        ])]
    }

    private static func sampleScript() -> [Conversation] {
        var answer = ChatMessage(role: .assistant, text: """
        In deinem Posteingang sind **240 Mails**. **31** davon sind Rechnungen, **4** warten auf deine Antwort.

        Ich habe dir eine Erinnerung gesetzt, die vier Antworten morgen zu schreiben.
        """)
        answer.steps = [step("s1", "mail_search", ["query": "Posteingang"], seconds: 2),
                        step("s2", "codemode", ["code": "…"], seconds: 9)]
        let sample = CreatedItem(integration: .reminders, identifier: "snapshot-script", modified: nil)
        answer.receipts = [PippaMCPWriteReceipt(action: "reminderAdd", outcome: "done", name: "Vier Mails beantworten · Fr., 20. Nov.", created: sample)]
        answer.duration = 14
        return [Conversation(id: "script", title: "Was liegt im Posteingang?", updated: Date(), messages: [
            ChatMessage(role: .user, text: "Was liegt in meinem Posteingang, und was muss ich beantworten?"), answer,
        ])]
    }

    /// A sample step labelled the way Pippa labels that tool, in the language the snapshot runs in.
    /// `seconds`: how long it took (or, still running, has taken so far).
    private static func step(_ id: String, _ tool: String, _ arguments: [String: String] = [:], done: Bool = true,
                             failed: Bool = false, seconds: TimeInterval? = nil) -> ChatStep {
        let json = (try? JSONSerialization.data(withJSONObject: arguments)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let now = Date()
        return ChatStep(id: id, label: StepLabel.text(tool: tool, arguments: json), done: done, failed: failed,
                        started: seconds.map { now.addingTimeInterval(-$0) }, ended: seconds != nil && done ? now : nil)
    }

    private static func sampleConversations(answering: Bool = false, failed: Bool = false, starting: Bool = false,
                                            writing: Bool = false, limited: Bool = false) -> [Conversation] {
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
            step("1", "search_files", ["query": "ETF"]),
            step("2", "read", ["path": "/Users/me/Documents/ETF-Portfolio.md"], seconds: 4),
            step("3", "read", ["path": "/Users/me/Documents/ETF-Ideen.md"], seconds: 2),
        ]
        let sample = CreatedItem(integration: .reminders, identifier: "snapshot", modified: nil)
        answer.receipts = [PippaMCPWriteReceipt(action: "reminderAdd", outcome: "done", name: "Sparplan prüfen · Fr., 7. Nov.", created: sample)]
        answer.duration = 18
        if answering {
            answer.text = ""
            answer.receipts = []
            answer.steps = [step("1", "search_files", ["query": "ETF"]),
                            step("2", "read", ["path": "/Users/me/Documents/ETF-Portfolio.md"], done: false, seconds: 6)]
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
            answer.steps = [step("1", "calendar_read", failed: true)]
            answer.error = "Pippa darf deinen Kalender nicht lesen. Erlaube es in den Systemeinstellungen unter Datenschutz & Sicherheit."
        }
        if limited {
            answer.text = ""
            answer.receipts = []
            answer.steps = [step("1", "search_files", ["query": "ETF"])]
            answer.error = T("The online AI is still at its limit. Wait a minute, then continue where it stopped.", table: "App")
            answer.resumeAfter = now.addingTimeInterval(38)
        }
        var letter = ChatMessage(role: .assistant, text: """
        Die Nachzahlung von **184,37 €** musst du **bis zum 15. November 2026** überweisen.

        Einwände gehen innerhalb von vier Wochen nach Zugang, also bis **19. November 2026**.
        """)
        letter.steps = [step("4", "read_document", ["path": "/Users/me/Downloads/Brief-Stadtwerke.pdf"])]
        letter.unsupportedDates = ["19. November 2026"]
        letter.checkedDates = ["15. November 2026"]
        letter.sources = [ChatSource(kind: .file, name: "Brief-Stadtwerke.pdf", location: "/Users/me/Downloads/Brief-Stadtwerke.pdf", detail: "Ganze Seite")]
        var undone = PippaMCPWriteReceipt(action: "calendarAdd", outcome: "done", name: "Fr., 14. Nov., 09:00 – Nachzahlung", created: sample)
        undone.undo = "removed"
        letter.receipts = [PippaMCPWriteReceipt(action: "reminderAdd", outcome: "done", name: "Nachzahlung überweisen · Fr., 14. Nov.", created: sample), undone]
        letter.context = ContextUsage(tokens: 12_431, window: 32_768)
        letter.duration = 6
        if !answering && !failed && !limited {
            answer.sources = [ChatSource(kind: .file, name: "ETF-Portfolio.md", location: "/Users/me/Documents/ETF-Portfolio.md", detail: nil),
                              ChatSource(kind: .file, name: "ETF-Ideen.md", location: "/Users/me/Documents/ETF-Ideen.md", detail: nil)]
            answer.checkedDates = ["1. November 2026"]
        }
        var messages = [ChatMessage(role: .user, text: "Wo ist meine aktuelle ETF-Übersicht und was steht drin?"), answer]
        if !answering && !failed && !limited {
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
                    writing: Bool = false, waiting: TimeInterval? = nil) {
        replaceForSnapshot(conversations, current: current, answering: answering, starting: starting, writing: writing, waiting: waiting)
    }
}
