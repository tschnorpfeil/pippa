import AppKit
import PiRPC
import PippaCore

/// `Pippa --snapshot-island <folder>`: renders Pippa Island in each state, at a notch and under a menu bar symbol, in
/// front of a neutral background as PNGs. Uses the real island view and geometry with made-up conversations; nothing is
/// read from or written to the person's conversations.
@MainActor
enum IslandSnapshots {
    static func run(into folder: URL) async -> Int32 {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSApp.setActivationPolicy(.accessory)
        let chat = ChatModel.shared, setup = SetupModel.shared, island = Island.shared, approvals = Approvals.shared
        setup.showForSnapshot(.ready(adoptedFrom: nil))
        // A presenter without a window: the sample question waits in `Approvals` instead of an alert.
        approvals.present("snapshot")
        func status(questions: Int = 0, flash: ChatModel.Unseen? = nil) -> IslandStatus {
            IslandStatus.current(chat: chat, setup: setup, questions: questions, flash: flash, targeted: false)
        }
        var question: Task<PiUIResponse, Never>?
        // Name, whether the island is open, and how to set it up.
        let scenes: [(String, Bool, () async -> Void)] = [
            ("rest", false, {
                chat.showSample(sample(.answered), current: "s1", answering: false)
                island.showForSnapshot(status())
            }),
            ("working", false, {
                chat.showSample(sample(.working), current: "s1", answering: true)
                island.showForSnapshot(status())
            }),
            ("needs-you-compact", false, {
                question = Task { await approvals.ask(sampleQuestion) }
                for _ in 0..<5 { await Task.yield() }
                island.showForSnapshot(status(questions: approvals.questions.count))
            }),
            ("needs-you", true, {}),
            ("done", false, {
                approvals.cancelAll()
                _ = await question?.value
                chat.showSample(sample(.answered), current: "s1", answering: false)
                island.showForSnapshot(status(flash: .answer))
            }),
            // A command Pippa wants to run: the whole command shows before Allow.
            ("needs-you-command", true, {
                question = Task { await approvals.ask(commandQuestion) }
                for _ in 0..<5 { await Task.yield() }
                island.showForSnapshot(status(questions: approvals.questions.count))
            }),
            ("failed", false, {
                approvals.cancelAll()
                _ = await question?.value
                chat.showSample(sample(.failed), current: "s1", answering: false)
                island.showForSnapshot(status(flash: .failed))
            }),
            ("downloading", false, {
                // Built directly: an online AI chosen on this Mac would hide the setup from `IslandStatus.current`.
                island.showForSnapshot(IslandStatus(tone: .working, label: T("Loading my AI · %lld %%", table: "App", 42), progress: 0.42))
            }),
            ("open", true, {
                chat.showSample(sample(.answered), current: "s1", answering: false)
                island.showForSnapshot(status())
            }),
            ("open-working", true, {
                chat.showSample(sample(.working), current: "s1", answering: true)
                island.showForSnapshot(status())
            }),
            // No step running: her thinking at the end of the chain, then the answer as it is written.
            ("open-thinking", true, {
                chat.showSample(sample(.thinking), current: "s1", answering: true)
                island.showForSnapshot(status())
            }),
            ("open-writing", true, {
                chat.showSample(sample(.writing), current: "s1", answering: true, writing: true)
                island.showForSnapshot(status())
            }),
            ("writing", false, {}),
            // A file dragged toward the island, then over its tray.
            ("drop-tray", true, {
                chat.showSample(sample(.answered), current: "s1", answering: false)
                island.showForSnapshot(status(), dropMode: true)
            }),
            ("drop-tray-over", true, { DropFeedback.island.targeted = true }),
        ]
        for (name, open, prepare) in scenes {
            await prepare()
            for notch in [true, false] {
                await render(notch: notch, open: open, status: island.status,
                             to: folder.appendingPathComponent("\(name)-\(notch ? "notch" : "menubar").png"))
            }
            // Without another notch tool in front of the open island.
            if open && ["open", "open-writing", "needs-you"].contains(name) {
                await render(notch: true, open: true, tool: false, status: island.status,
                             to: folder.appendingPathComponent("\(name)-notch-alone.png"))
            }
        }
        DropFeedback.island.targeted = false
        island.showForSnapshot(status())
        approvals.dismiss("snapshot")
        print(folder.path)
        return 0
    }

    /// `tool`: another notch tool shows right of the housing, like tinyStats, in front of the island.
    private static func render(notch: Bool, open: Bool, tool: Bool = true, status: IslandStatus, to file: URL) async {
        let size = NSSize(width: 640, height: open ? 420 : 110)
        let barHeight: CGFloat = notch ? 32 : 24
        let canvas = Canvas(frame: NSRect(origin: .zero, size: size))
        canvas.barHeight = barHeight
        let placement: IslandPlacement
        if notch {
            let housing = CGRect(x: ((size.width - 185) / 2).rounded(), y: size.height - barHeight, width: 185, height: barHeight)
            canvas.housing = housing
            placement = .notch(housing: housing, screen: canvas.bounds)
        } else {
            let anchor = CGRect(x: size.width - 150, y: size.height - barHeight, width: 30, height: barHeight)
            let mark = MarkNSView(size: 18, monochromeIdle: true)
            mark.frame = NSRect(x: anchor.midX - 9, y: anchor.midY - 9, width: 18, height: 18)
            mark.setState(status.tone == .done || status.tone == .rest ? .ruht : status.markState)
            canvas.addSubview(mark)
            placement = .menuBar(anchor: anchor, visible: CGRect(x: 0, y: 0, width: size.width, height: size.height - barHeight))
        }
        let window = SnapshotWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = canvas
        var height: CGFloat = 200
        var view: IslandView?
        func layout() {
            guard let view else { return }
            let width = status.showsCompact ? (notch ? status.wingWidth : status.capsuleWidth) : nil
            let compact = width.map { IslandGeometry.compact(placement, width: $0) } ?? IslandGeometry.rest(placement)
            let openRect = IslandGeometry.open(placement, contentHeight: ceil(height))
            let frame = IslandGeometry.windowFrame(placement, covering: [compact] + (open ? [openRect] : []))
            view.frame = frame
            view.show(placement, compactShape: compact, compactTarget: compact, compactAlpha: width == nil && !notch ? 0 : 1,
                      open: open ? 1 : 0, openRect: openRect, origin: frame.origin)
        }
        view = IslandView(island: .shared) { measured in
            guard abs(measured - height) > 0.5 else { return }
            height = measured
            layout()
        }
        if let view { canvas.addSubview(view) }
        if notch && tool, let housing = canvas.housing {
            canvas.addSubview(NotchTool(frame: NSRect(x: housing.maxX - 10, y: housing.minY, width: 110, height: housing.height)))
        }
        layout()
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        // Let SwiftUI lay out and report the panel's height before drawing.
        for _ in 0..<6 { try? await Task.sleep(for: .milliseconds(120)); canvas.layoutSubtreeIfNeeded(); layout() }
        // Twice the points, like a Retina display.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
        window.orderOut(nil)
    }

    /// A desktop with a menu bar and, for a MacBook, the camera housing.
    private final class Canvas: NSView {
        var barHeight: CGFloat = 24
        var housing: CGRect?
        override func draw(_ dirtyRect: NSRect) {
            NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.20, blue: 0.35, alpha: 1),
                       ending: NSColor(srgbRed: 0.34, green: 0.40, blue: 0.53, alpha: 1))?.draw(in: bounds, angle: -65)
            NSColor.white.withAlphaComponent(0.06).setFill()
            NSRect(x: 0, y: bounds.maxY - barHeight, width: bounds.width, height: barHeight).fill()
            guard let housing else { return }
            NSColor.black.setFill()
            let path = NSBezierPath(roundedRect: housing, xRadius: 10, yRadius: 10)
            path.appendRect(NSRect(x: housing.minX, y: housing.midY, width: housing.width, height: housing.height / 2))
            path.fill()
        }
    }

    /// Another notch tool on the right of the housing, like tinyStats: it stays in front of the open island.
    private final class NotchTool: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
            NSColor(srgbRed: 0.5, green: 0.72, blue: 1, alpha: 1).setFill()
            for (i, h) in [6.0, 9, 13].enumerated() {
                NSBezierPath(roundedRect: NSRect(x: 24 + Double(i) * 8, y: 9, width: 4, height: h), xRadius: 2, yRadius: 2).fill()
            }
        }
    }

    private final class SnapshotWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    private enum Sample { case answered, working, thinking, writing, failed }

    private static func sample(_ kind: Sample) -> [Conversation] {
        var answer = ChatMessage(role: .assistant, text: """
        Die Nachzahlung von **184,37 €** musst du **bis zum 15. November 2026** überweisen.

        Einwände gehen innerhalb von vier Wochen nach Zugang, also bis **19. November 2026**. Die Abrechnung nennt \
        dafür die Hausverwaltung als Ansprechpartner.

        **Was du tun kannst**
        - Den Betrag bis zum 15. November überweisen
        - Bei Fragen die Hausverwaltung Berger anrufen
        """)
        let search = StepLabel.text(tool: "search_files", arguments: #"{"query":"Stadtwerke"}"#)
        let read = StepLabel.text(tool: "read", arguments: #"{"path":"/Users/me/Downloads/Brief-Stadtwerke.pdf"}"#)
        answer.steps = [ChatStep(id: "1", label: search, done: true), ChatStep(id: "2", label: read, done: true)]
        switch kind {
        case .answered: break
        case .working:
            answer.text = ""
            answer.steps[1].done = false
        case .thinking:
            answer.text = ""
            answer.thinking = "Der Brief nennt zwei Daten: die Fälligkeit der Nachzahlung und die Frist für Einwände. "
                + "Die Fälligkeit steht im zweiten Absatz, 15. November. Für den Einwand zählen vier Wochen ab Zugang, "
                + "der Brief kam am 22. Oktober, also bis zum 19. November."
        case .writing:
            answer.text = String(answer.text.prefix(150))
        case .failed:
            answer.text = ""
            answer.error = "Pippa darf deinen Kalender nicht lesen. Erlaube es in den Systemeinstellungen unter Datenschutz & Sicherheit."
        }
        return [Conversation(id: "s1", title: "Frist im Brief der Stadtwerke", updated: Date(), messages: [
            ChatMessage(role: .user, text: "Bis wann muss ich hier etwas tun?", files: ["/Users/me/Downloads/Brief-Stadtwerke.pdf"]), answer,
        ])]
    }

    private static let sampleQuestion = PiUIRequest(
        id: "island-snapshot", method: "confirm", title: "Darf Pippa im Internet suchen?",
        message: "Pippa möchte bei DuckDuckGo suchen nach:\n\n„Widerspruchsfrist Nebenkostenabrechnung“")

    /// As shell.ts asks before a write (`grantAskText`), with a command near its 300-character limit.
    private static let commandQuestion = PiUIRequest(
        id: "island-snapshot-command", method: "confirm", title: "Darf Pippa deine Dateien ändern?",
        message: "Für diese Antwort möchte Pippa mit einem Befehl Dateien in Dokumente/Steuer ändern (vorher legt Pippa Kopien an)."
            + "\n\nDetails:\nfor f in ~/Documents/Steuer/2026/Belege/*.pdf; do n=$(basename \"$f\" .pdf); "
            + "mv \"$f\" ~/Documents/Steuer/2026/Belege/\"$(date -r \"$f\" +%Y-%m-%d)-$n.pdf\"; done; "
            + "ls -la ~/Documents/Steuer/2026/Belege | head -40; echo fertig mit allen Belegen aus dem Ordner Steuer 2026")
}
