import Foundation

/// Delivers sample data as in the prototype so the UI can be demoed without a model.
/// Never changes anything on disk.
public final class StubEngine: PippaEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var status: ModelStatus = .ready
    /// Artificial wait per step (seconds), for believable progress indicators.
    public var delay: Double
    /// Reminders, Calendar, Mail in memory only.
    public let integrations: DemoIntegrations
    /// Excel in memory only: "Kosten 2026" (`DemoSheetReader.sample`).
    public let sheets: DemoSheetReader

    /// `status`: model state at the start; `.notInstalled` replays first launch while knowledge is still loading.
    public init(delay: Double = 0.8, integrations: DemoIntegrations = DemoIntegrations(), sheets: DemoSheetReader = DemoSheetReader(),
                status: ModelStatus = .ready) {
        self.delay = delay; self.integrations = integrations; self.sheets = sheets; self.status = status
        startedWithoutModel = status == .notInstalled
    }
    private let startedWithoutModel: Bool

    public var modelStatus: ModelStatus {
        get async { lock.withLock { status } }
    }

    /// Sample answer for conversations in demos and debug recordings without a real Pi (app: `SnapshotChat`).
    public static var sampleAnswer: String {
        L("Sample answer: Here you can ask Pippa a question or attach files for context. In the finished app, Pippa answers right here on your Mac.", table: "Core")
    }

    public func prepareModel(allowDownload: Bool) async throws {
        // As on first launch (started without knowledge): loading takes noticeable time so one can already organize meanwhile.
        let step = startedWithoutModel ? delay * 1.2 : delay / 4
        for i in 0...10 {
            lock.withLock { status = .downloading(progress: Double(i) / 10, remaining: Double(10 - i) * 3) }
            try await Task.sleep(for: .seconds(step))
        }
        lock.withLock { status = .ready }
    }

    private func pause(_ factor: Double = 1) async {
        try? await Task.sleep(for: .seconds(delay * factor))
    }

    private var progress: WorkProgress?
    public var workProgress: WorkProgress? { get async { lock.withLock { progress } } }

    /// Like `pause`, but file by file with progress (for the dots while working).
    private func read(_ total: Int, _ factor: Double) async {
        let names = Self.sampleFiles.map(\.old)
        for i in 0..<total {
            lock.withLock { progress = WorkProgress(done: i, total: total, current: names[i % names.count]) }
            try? await Task.sleep(for: .seconds(delay * factor / Double(total)))
        }
        lock.withLock { progress = nil }
    }

    public func overview(of payload: DropPayload) async throws -> Overview {
        if case .files(let urls) = payload, urls.count == 1, urls[0].hasDirectoryPath { await read(47, 1.5) } else { await pause(1.5) }
        switch payload {
        case .files(let urls) where urls.count == 1 && urls[0].pathExtension.lowercased() == "pdf":
            let d = Self.sampleDeadlines(urls[0])
            return Overview(title: "Rechnung · Stadtwerke", subtitle: L("%@ · %lld pages", table: "Core", urls[0].lastPathComponent, 2), kind: .pdf,
                            categories: [(DocCategory.invoice.label, 1)],
                            facts: [(L("Sender", table: "Core"), "Stadtwerke"), (L("Date", table: "Core"), "02.03.2026"), (L("Amount", table: "Core"), "84,20 €"),
                                    (L("Deadline", table: "Core"), d[0].title)],
                            actions: [.deadlines, .sort, .invoiceTable, .ask], deadlines: d, sender: "Stadtwerke")
        case .files(let urls) where urls.count == 1 && ["eml", "emlx"].contains(urls[0].pathExtension.lowercased()):
            let d = [Deadline(kind: .payment, date: DayDate(year: 2026, month: 10, day: 31), title: "Zahlen bis 31.10.2026",
                              quote: "Die Nachzahlung von 312,48 € ist zahlbar bis 31.10.2026.", source: urls[0], location: nil, certainty: .sure)]
            return Overview(title: "Mail · Nebenkostenabrechnung", subtitle: L("%@ · 1 attachment", table: "Core", L("From %@", table: "Core", "Hausverwaltung Berger")), kind: .mail,
                            categories: [(DocCategory.invoice.label, 1)],
                            facts: [(L("Subject", table: "Core"), "Nebenkostenabrechnung 2025"), (L("Amount", table: "Core"), "312,48 €"),
                                    (L("Deadline", table: "Core"), d[0].title)],
                            actions: [.deadlines, .invoiceTable, .ask], deadlines: d, sender: "Hausverwaltung Berger")
        case .text(let text):
            return Overview(title: L("Text", table: "Core"), subtitle: L("%lld characters", table: "Core", text.count), kind: .text, actions: [.ask])
        case .link(let url):
            return Overview(title: url.host ?? "Link", subtitle: url.absoluteString, kind: .link, actions: [.ask])
        case .files(let urls):
            let name = urls.count == 1 ? urls[0].lastPathComponent : L("Selection", table: "Core")
            return Overview(title: name, subtitle: L("%lld files", table: "Core", 47), kind: .folder,
                            categories: [(DocCategory.invoice.label, 18), (DocCategory.contract.label, 7), (DocCategory.photo.label, 14), (DocCategory.other.label, 8)],
                            facts: [(L("Period", table: "Core"), "März 2023 – Sep. 2026")],
                            actions: [.sort, .invoiceTable, .ask])
        }
    }

    static let sampleFiles: [(old: String, new: String, folder: String, why: String)] = [
        ("Scan_20260312.pdf", "2026-03 Stadtwerke Rechnung.pdf", "Rechnungen/2026", L("Sender and invoice date on page 1", table: "Core")),
        ("IMG_4821.jpg", "2026-07-14 Foto 01.jpg", "Fotos/2026", L("Date taken, from the photo’s details", table: "Core")),
        ("Dokument (3).pdf", "Mietvertrag Wohnung 2021.pdf", "Verträge", L("Heading “%@”, signed on %@", table: "Core", "Mietvertrag", "14.06.2021")),
        ("rechnung_final_v2.pdf", "2026-05 Telekom Rechnung.pdf", "Rechnungen/2026", L("Letterhead and invoice date %@", table: "Core", "02.05.2026")),
        ("download.pdf", "2026-02 Zahnarzt Dr. Weber Rechnung.pdf", "Rechnungen/2026", L("Recognized: practice name and date", table: "Core")),
        ("Brief Vermieter.docx", "2026-04 Hausverwaltung Brief (Entwurf).docx", "Verträge", L("No signature, so it’s a draft", table: "Core")),
        ("Screenshot 2026-08-14 um 10.22.31.png", "Screenshot 2026-08-14 um 10.22.31.png", "Sonstiges", L("Nothing to go by", table: "Core")),
        ("Vodafone_Rechnung.pdf", "2026-06 Vodafone Rechnung.pdf", "Rechnungen/2026", L("Sender and date on page 1", table: "Core")),
        ("Kuendigung_Fitness.pdf", "2025-11 FitWerk Kündigung.pdf", "Verträge", L("Subject “%@”", table: "Core", "Kündigung")),
    ]

    /// So the sample numbers add up everywhere: 47 files = 18 invoices, 7 contracts, 14 photos, 8 other
    /// (1 of them unreadable). Organizing moves 46, the sheet has 18 rows.
    static let moreFiles: [(old: String, new: String, folder: String, why: String)] = {
        var out: [(old: String, new: String, folder: String, why: String)] = []
        for b in moreBills + sampleBills.filter({ ["Bauhaus Beleg.pdf", "HUK Beitragsrechnung.pdf"].contains($0.file) }) {
            let p = b.date.split(separator: ".")
            out.append((b.file, "\(p[2])-\(p[1]) \(b.sender) Rechnung.pdf", "Rechnungen/\(p[2])", L("Sender and invoice date on page 1", table: "Core")))
        }
        for (i, name) in ["Mietvertrag Garage.pdf", "Hausrat Police.pdf", "Arbeitsvertrag.pdf", "Bescheinigung Bank.pdf"].enumerated() {
            out.append(("Dokument (\(i + 4)).pdf", name, "Verträge", L("Heading on page 1", table: "Core")))
        }
        for i in 2...14 {
            out.append(("IMG_48\(20 + i).jpg", String(format: "2026-07-14 Foto %02d.jpg", i), "Fotos/2026", L("Date taken, from the photo’s details", table: "Core")))
        }
        for i in 1...6 {
            out.append(("Bildschirmfoto \(i).png", "Bildschirmfoto \(i).png", "Sonstiges", L("Nothing to go by", table: "Core")))
        }
        return out
    }()

    static let moreBills: [(date: String, sender: String, amount: String, file: String, evidence: String, unsure: Bool)] = [
        ("02.01.2026", "Stadtwerke", "84.20", "Rechnung_2026_01.pdf", "Betrag 84,20 €", false),
        ("02.02.2026", "Stadtwerke", "84.20", "Rechnung_2026_02.pdf", "Betrag 84,20 €", false),
        ("02.04.2026", "Stadtwerke", "84.20", "Rechnung_2026_04.pdf", "Betrag 84,20 €", false),
        ("02.05.2026", "Stadtwerke", "84.20", "Rechnung_2026_05.pdf", "Betrag 84,20 €", false),
        ("02.06.2026", "Stadtwerke", "84.20", "Rechnung_2026_06.pdf", "Betrag 84,20 €", false),
        ("02.07.2026", "Stadtwerke", "84.20", "Rechnung_2026_07.pdf", "Betrag 84,20 €", false),
        ("02.01.2026", "Telekom", "39.95", "telekom_jan.pdf", "Rechnungsbetrag 39,95 €", false),
        ("02.02.2026", "Telekom", "39.95", "telekom_feb.pdf", "Rechnungsbetrag 39,95 €", false),
        ("02.03.2026", "Telekom", "39.95", "telekom_mrz.pdf", "Rechnungsbetrag 39,95 €", false),
        ("02.04.2026", "Telekom", "39.95", "telekom_apr.pdf", "Rechnungsbetrag 39,95 €", false),
        ("01.04.2026", "Vodafone", "24.99", "Vodafone_04.pdf", "Zu zahlen: 24,99 €", false),
        ("01.05.2026", "Vodafone", "24.99", "Vodafone_05.pdf", "Zu zahlen: 24,99 €", false),
    ]

    public func proposeSort(folder: URL) async throws -> Plan {
        await pause(2)
        var ops: [PlanOp] = []
        for dir in ["Rechnungen", "Rechnungen/2026", "Verträge", "Fotos", "Fotos/2026", "Sonstiges"] {
            ops.append(PlanOp(kind: .mkdir, source: nil, target: folder.appendingPathComponent(dir, isDirectory: true), reason: L("New folder", table: "Core"), certainty: .sure))
        }
        for f in Self.sampleFiles + Self.moreFiles {
            ops.append(PlanOp(kind: .move, source: folder.appendingPathComponent(f.old),
                              target: folder.appendingPathComponent(f.folder).appendingPathComponent(f.new),
                              reason: f.why, certainty: .sure))
        }
        return Plan(scope: folder, ops: ops,
                    skipped: [(folder.appendingPathComponent("scan0047.pdf"), L("I can’t make out any text. I won’t guess, so the file stays where it is.", table: "Core"))])
    }

    /// Like the real organizing in stages: first everything except the documents (those are "still being read"), then the finished plan.
    public func proposeSort(items: [URL]?, scope: URL, limit: Int?, onUpdate: @escaping @Sendable (Plan) -> Void) async throws -> Plan {
        let full = try await proposeSort(folder: scope)
        let reading = Set(full.ops.filter { ["pdf", "docx"].contains($0.source?.pathExtension.lowercased() ?? "") }.map(\.id))
        var first = full
        first.ops.removeAll { reading.contains($0.id) }
        first.pending = full.ops.filter { reading.contains($0.id) }.compactMap(\.source)
        onUpdate(first)
        await pause(1.5)
        // Without a model, what only the model could sort stays put (here: the Word document).
        guard await modelStatus != .ready else { onUpdate(full); return full }
        var done = full
        let unclear = done.ops.filter { $0.source?.pathExtension.lowercased() == "docx" }
        done.ops.removeAll { op in unclear.contains { $0.id == op.id } }
        done.later = unclear.compactMap(\.source)
        onUpdate(done)
        return done
    }

    public func apply(_ plan: Plan, excluding: Set<UUID>) async throws -> JobReceipt {
        await pause(1.5)
        let files = plan.ops.filter { $0.kind != .mkdir && !excluding.contains($0.id) }.count
        return JobReceipt(id: UUID(), summary: L("%lld files tidied", table: "Core", files),
                          detail: Executor.detail(folders: 4, stayed: plan.skipped.count), revealURL: plan.scope,
                          stayed: plan.skipped.map { FileReason(name: $0.url.lastPathComponent, why: $0.why) })
    }

    static let sampleBills: [(date: String, sender: String, amount: String, file: String, evidence: String, unsure: Bool)] = [
        ("02.03.2026", "Stadtwerke", "84.20", "2026-03 Stadtwerke Rechnung.pdf", "Rechnungsdatum 02.03.2026, Betrag 84,20 €.", false),
        ("18.02.2026", "Zahnarzt Dr. Weber", "128.40", "2026-02 Zahnarzt Dr. Weber Rechnung.pdf", "Gesamtbetrag 128,40 €", true),
        ("02.05.2026", "Telekom", "39.95", "2026-05 Telekom Rechnung.pdf", "Rechnungsbetrag 39,95 €", false),
        ("01.06.2026", "Vodafone", "24.99", "2026-06 Vodafone Rechnung.pdf", "Zu zahlen: 24,99 €", false),
        ("15.04.2026", "Bauhaus", "212.37", "Bauhaus Beleg.pdf", "Summe EUR 212,37", false),
        ("30.01.2026", "HUK-Coburg", "312.00", "HUK Beitragsrechnung.pdf", "Jahresbeitrag 312,00 €", false),
    ]

    public func undo(_ receipt: JobReceipt) async throws { await pause() }

    // MARK: Integrations (in memory only)

    static func sampleDeadlines(_ file: URL) -> [Deadline] {
        [
            Deadline(kind: .payment, date: DayDate(year: 2026, month: 10, day: 31), title: "Zahlen bis 31.10.2026",
                     quote: "Bitte überweisen Sie den Betrag von 84,20 € bis zum 31.10.2026.", source: file, location: "S. 1", certainty: .sure),
            Deadline(kind: .cancellation, date: DayDate(year: 2026, month: 9, day: 30)?.adding(months: 12), title: "Kündigen bis 30.09.2027",
                     quote: "Der Vertrag kann mit einer Frist von drei Monaten zum Ende der Laufzeit am 31.12.2027 gekündigt werden.",
                     source: file, location: "S. 2", certainty: .unsure, note: "3 Monate vor dem Vertragsende 31.12.2027 gerechnet. Bitte prüfen."),
        ]
    }

    public func integrationAccess(_ integration: Integration) async -> IntegrationAccess { await integrations.access(integration) }
    public func requestIntegrationAccess(_ integration: Integration) async -> IntegrationAccess { await integrations.requestAccess(integration) }

    public func addEntry(_ entry: CalendarEntry) async throws -> JobReceipt {
        await pause()
        let item = try await integrations.add(entry, tag: URL(string: "pippa://demo")!)
        _ = item
        return JobReceipt(id: UUID(), summary: entry.target == .reminder ? L("Added to Reminders", table: "Core") : L("Added to Calendar", table: "Core"),
                          detail: "\(entry.title) · \(entry.date.german)", revealURL: nil,
                          undoDetail: entry.target == .reminder ? L("The reminder is gone again.", table: "Core") : L("The event is gone again.", table: "Core"),
                          integration: entry.integration)
    }

    public func selectedMail() async throws -> MailMessage? {
        await pause(0.5)
        return try await integrations.selectedMail()
    }

    /// In memory only (`DemoIntegrations.insertedDrafts`). Never sends.
    public func insertMailReply(_ draft: MailDraft) async throws -> MailInsertResult {
        await pause(0.3)
        return try await integrations.insertReply(draft)
    }
    /// Synthetic events from `DemoIntegrations` (never real calendars).
    public func readCalendar(_ range: CalendarRange) async -> CalendarReadResult {
        await pause(0.2)
        return await CalendarReader.read(range, from: integrations)
    }

    public func sheetAccess() async -> IntegrationAccess { await sheets.sheetAccess() }
    public func requestSheetAccess() async -> IntegrationAccess { await sheets.requestSheetAccess() }
    public func selectedSheet() async throws -> SheetSnapshot? {
        await pause(0.4)
        return try await sheets.selectedSheet()
    }

    public func pendingRecovery() async -> [JobReceipt] { [] }
}

public extension Answer {
    /// Default text when nothing verifiable was found.
    static var notFoundText: String { L("I didn’t find anything about that in your files.", table: "Core") }
}

/// Picks the engine: `StubEngine` with `PIPPA_DEMO=1`, otherwise `LocalEngine`.
public enum PippaEngineFactory {
    public static func make() -> any PippaEngine {
        let env = ProcessInfo.processInfo.environment
        // `PIPPA_DEMO_MODEL=missing`: sample engine as on first launch, knowledge not yet loaded.
        if env["PIPPA_DEMO"] == "1" { return StubEngine(status: env["PIPPA_DEMO_MODEL"] == "missing" ? .notInstalled : .ready) }
        return LocalEngine()
    }
}
