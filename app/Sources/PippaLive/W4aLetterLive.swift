import Foundation
import PippaCore

/// Letter suggestions and "Check online" via the new path (LetterModel → LocalModelJSON → llama-server),
/// with a real model. As in the app's Pi path, LocalEngine uses a shared server (`useSharedServer`), no
/// PiRuntimeClient, no runtime/pi. Invented letter, fake support directory (PIPPA_LIVE_BASE).
///
///   PIPPA_LIVE=1 PIPPA_LLAMA_SERVER=… PIPPA_MODEL_FILE=…K2-Horizon-7B….gguf PippaLive w4a-letter [stub|web]
///
/// `stub` (default): an invented official page instead of the network. `web`: the real fetch process (PIPPA_NODE_BINARY,
/// PIPPA_WEB_RUNTIME=runtime/pippa-web), a general search query, after approval exactly as in the app.
enum W4aLetterLive {
    static func run(base: URL, arguments: [String]) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let model = env["PIPPA_MODEL_FILE"], let binary = LlamaServer.binaryURL() else {
            print("needs PIPPA_MODEL_FILE and PIPPA_LLAMA_SERVER"); exit(2)
        }
        let memory = ProcessInfo.processInfo.physicalMemory
        let choice = try ModelSelector.named("k2-horizon-7b", physicalMemory: memory) ?? ModelSelector.choose(physicalMemory: memory).get()
        let server = LlamaServer(choice: choice, modelPath: URL(fileURLWithPath: model), binary: binary, logDirectory: base)
        let engine = LocalEngine(baseDirectory: base, integrations: DemoIntegrations(), existingModelRoots: [])
        await engine.useSharedServer(.init(server: { try await server.ensureRunning(); return server }, status: { .ready }))
        defer { Task { await server.stop() } }

        let mail = base.appendingPathComponent("brief-finanzamt.eml")
        try """
        From: Finanzamt Musterstadt <poststelle@finanzamt-musterstadt.example>
        To: kim.beispiel@example.com
        Subject: Bescheid für 2025 über Einkommensteuer
        Date: Mon, 5 Oct 2026 09:00:00 +0200
        Content-Type: text/plain; charset=utf-8

        Sehr geehrte Frau Beispiel,

        anbei erhalten Sie den Bescheid für 2025 über Einkommensteuer. Es ergibt sich eine Nachzahlung von 312,00 €.
        Bitte überweisen Sie den Betrag bis zum 06.11.2026 auf das unten genannte Konto.

        Rechtsbehelfsbelehrung: Gegen diesen Bescheid ist der Einspruch zulässig. Er ist innerhalb eines Monats nach
        Bekanntgabe dieses Bescheids beim Finanzamt Musterstadt schriftlich oder elektronisch einzulegen.

        Mit freundlichen Grüßen
        Ihr Finanzamt Musterstadt
        """.write(to: mail, atomically: true, encoding: .utf8)

        print("Model: \(URL(fileURLWithPath: model).lastPathComponent), ctx \(choice.ctx)")
        var started = Date()
        try await server.ensureRunning()
        print(String(format: "Server ready: %.1f s", Date().timeIntervalSince(started)))

        // 1. Suggestions
        started = Date()
        let proposals = try await engine.proposeLetterActions(mail: mail, choices: LetterActions.allowedForAgent()) ?? []
        let valid = LetterActions.validated(proposals) ?? []
        print(String(format: "\n[Suggestions] %.1f s", Date().timeIntervalSince(started)))
        for p in proposals { print("  raw: \(p.id) · \(p.reason) · \(p.instruction)") }
        print("  checked: " + valid.map { "\($0.id)(\($0.reason ?? "-"))" }.joined(separator: ", "))

        // 2. Check online
        let web = arguments.first == "web"
        let fetcher: any WebFetching = web ? WebFetcher() : StubOfficialPage()
        let host = LookupHost(fetcher: fetcher, personal: PersonalTerms.from(texts: [(try? String(contentsOf: mail, encoding: .utf8)) ?? ""],
                                                                               senders: ["Finanzamt Musterstadt"], fileNames: [mail.lastPathComponent],
                                                                               userName: "Kim Beispiel"), language: "de")
        let statement = "Einspruch möglich innerhalb eines Monats nach Bekanntgabe"
        started = Date()
        var outcome = try await engine.checkOnline(statement: statement, host: host)
        let pending = await host.pendingConfirmation
        print(String(format: "\n[Check online, %@] Step 1: %.1f s → %@, request for approval: %@", web ? "real fetch" : "invented page",
                     Date().timeIntervalSince(started), "\(outcome)", pending ?? "-"))
        if outcome == .needsPerson, let pending {
            await host.approve(pending)   // here: the person clicks "Search"
            started = Date()
            outcome = try await engine.checkOnline(statement: statement, host: host)
            print(String(format: "  after approval: %.1f s → %@", Date().timeIntervalSince(started), "\(outcome)"))
        }
        if case .cited(let cites) = outcome {
            let answer = await host.verify(cites)
            print("  Citations from the model: \(cites.count), supported: \(answer.facts.count), discarded: \(answer.dropped), note: \(answer.note ?? "-")")
            for fact in answer.facts { print("  ✓ \(fact.statement) — “\(fact.quote.prefix(160))” (\(fact.source.site))") }
        }
        if let web = fetcher as? WebFetcher { await web.shutdown() }
        await server.stop()
    }
}

/// Invented official page (wording loosely after § 355 AO, not fetched).
private struct StubOfficialPage: WebFetching {
    func lookup(_ query: String, language: String) async throws -> [WebSource] {
        print("  (invented page for the query “\(query)”)")
        return [WebSource(id: "", url: URL(string: "https://www.gesetze-im-internet.de/ao_1977/__355.html")!, site: "gesetze-im-internet.de",
                          title: "§ 355 AO Einspruchsfrist", asOf: DayDate(year: 2026, month: 1, day: 1), fetchedAt: Date(),
                          text: "§ 355 Einspruchsfrist. (1) Der Einspruch nach § 347 Abs. 1 Satz 1 ist innerhalb eines Monats nach Bekanntgabe des Verwaltungsakts einzulegen. "
                            + "Ein Einspruch gegen eine Steueranmeldung ist innerhalb eines Monats nach Eingang der Steueranmeldung bei der Finanzbehörde einzulegen. "
                            + "(2) Der Einspruch nach § 347 Abs. 1 Satz 2 ist unbefristet, solange die Verwaltungsentscheidung nicht ergangen ist.")]
    }
}
