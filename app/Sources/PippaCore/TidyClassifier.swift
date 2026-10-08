import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// How tidying classifies a document whose place stays unclear after reading (stage 3 of `proposeSort`).
///
/// Fast first: the system's on-device model (Apple Foundation Models, guided output, well under a second per file) when
/// it is available; otherwise, or when it declines or fails, the local model (llama-server). Both get the same short
/// excerpt (first page, about 1,500 characters) after the same fixed system prompt, so llama-server can reuse the
/// prompt prefix from file to file. Every file has a time limit: a slow answer never holds up the preview.
/// Results from either model go through the same evidence check (`LocalEngine.documentInsight`).
public enum TidyClassifier {
    /// Characters of document text per file: about the first page. Enough for sender, kind and date in the letterhead.
    public static let excerptChars = 1500
    /// At most this long per file and model; then the next model, or the file stays where it is.
    /// The local model gets more: measured 2026-10-08 (a 12B local model, this corpus; re-measure with K2) p50 26 s, max 39 s per file, almost all of it
    /// generating the ~110–140 answer tokens at ~5 tokens/s (prefill with the cached system prompt ~5 s). The system model: ~3 s.
    public static func perFileTimeout(_ route: Route) -> Duration {
        switch route {
        case .apple: .seconds(20)
        case .local: .seconds(60)
        }
    }
    /// Answer budget for the system model (the guided answer is a handful of short fields).
    static let appleResponseTokens = 200

    public enum Route: String, Sendable, Equatable { case apple, local }

    /// Outcome of one route for one file.
    public enum Outcome: Sendable, Equatable { case answered, declined, timedOut }

    /// Which models to ask, in order. Recordings (checks) answer alone, so checks never depend on this Mac's models.
    /// `localReady`: the local model can answer without starting anything (`LocalEngine.canAskModel`).
    public static func routes(replay: Bool, appleAvailable: Bool, localReady: Bool) -> [Route] {
        if replay { return [.local] }
        return (appleAvailable ? [.apple] : []) + (localReady ? [.local] : [])
    }

    /// Can stage 3 classify at all right now? If not, unclear documents wait for later (`Plan.later`).
    public static func canClassify(replay: Bool, appleAvailable: Bool, localReady: Bool) -> Bool {
        !routes(replay: replay, appleAvailable: appleAvailable, localReady: localReady).isEmpty
    }

    /// After all routes for a file: an answer counts; a time limit with no answer means "stays where it is" (calm note);
    /// only declines everywhere (or no route) leave the file for later.
    public static func settle(_ outcomes: [Outcome]) -> Outcome {
        if outcomes.contains(.answered) { return .answered }
        if outcomes.contains(.timedOut) { return .timedOut }
        return .declined
    }

    /// The user text: file name, then the excerpt. Nothing per file goes before it (the system prompt stays the prefix).
    public static func prompt(name: String, doc: DocumentText) -> String {
        "Dateiname: \(name)\n\n\(doc.capped(maxChars: excerptChars))"
    }

    /// Order for reading with a model: small, text-rich files first, so the preview visibly moves on.
    public static func readingOrder(_ urls: [URL]) -> [URL] {
        func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max }
        func textRich(_ url: URL) -> Bool { ["txt", "md", "rtf", "eml", "html", "htm", "csv", "docx", "doc", "odt"].contains(url.pathExtension.lowercased()) }
        return urls.enumerated().sorted { a, b in
            let (ta, tb) = (textRich(a.element), textRich(b.element))
            if ta != tb { return ta }
            let (sa, sb) = (size(a.element), size(b.element))
            return sa != sb ? sa < sb : a.offset < b.offset
        }.map(\.element)
    }

    /// Runs `op` for at most `limit`. `.timedOut` if the limit came first (the operation is then cancelled).
    /// Cancelling the caller cancels both and is passed on.
    static func withTimeout<T: Sendable>(_ limit: Duration, _ op: @escaping @Sendable () async throws -> T?) async throws -> (value: T?, timedOut: Bool) {
        try await withThrowingTaskGroup(of: (T?, Bool).self) { group in
            group.addTask { (try await op(), false) }
            group.addTask { try await Task.sleep(for: limit); return (nil, true) }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { return (nil, false) }
            return first
        }
    }

    // MARK: System model (Apple Foundation Models)

    /// The system model is there, on this Mac, and speaks German. Debug builds with `PIPPA_NO_SYSTEM_MODEL` (checks) never use it.
    public static var appleAvailable: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["PIPPA_NO_SYSTEM_MODEL"] != nil { return false }
        #endif
        return AppleQuickModel.system?.availability == .available
    }

    /// One guided answer from the system model; `nil` if unavailable, declined (guardrail, refusal) or failed.
    static func askApple(system: String, prompt: String) async throws -> ClassifyJSON? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard appleAvailable else { return nil }
            let session = LanguageModelSession(model: .default, instructions: system)
            do {
                let response = try await session.respond(to: prompt, schema: AppleSchema.classify,
                                                         options: AppleQuickModel.greedy(maximumResponseTokens: appleResponseTokens))
                return try AppleSchema.decode(response.content)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                DiagnosticsLog.shared.event("einordnen-apple", ["fehler": String(describing: AppleQuickModel.classify(error))])
                return nil
            }
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
/// The classify schema (`Prompts.classifySchema`) for the system model. Built at runtime: the Command Line Tools
/// don't ship the @Generable macro plugin. Guided output is constrained to it like llama-server's grammar.
@available(macOS 26.0, *)
enum AppleSchema {
    static let categories = ["rechnung", "vertrag", "brief", "sonstiges"]

    static let classify: GenerationSchema = {
        func text(_ name: String, _ description: String) -> DynamicGenerationSchema.Property {
            .init(name: name, description: description, schema: DynamicGenerationSchema(type: String.self))
        }
        let root = DynamicGenerationSchema(name: "Einordnung", properties: [
            .init(name: "kategorie", schema: DynamicGenerationSchema(name: "Kategorie", anyOf: categories)),
            text("absender", "Firma oder Person, kurz, ohne Rechtsform; sonst leer"),
            text("art", "Ein Wort wie Rechnung, Mietvertrag, Kündigung; sonst leer"),
            text("datum", "TT.MM.JJJJ wie im Text; sonst leer"),
            text("betreff", "Betreff wie im Text; sonst leer"),
            text("beleg", "Wörtliche Zeile aus dem Text, die die Art belegt; sonst leer"),
            .init(name: "entwurf", schema: DynamicGenerationSchema(type: Bool.self)),
            text("entwurf_beleg", "Wörtlich „Entwurf“ oder „Draft“ aus dem Text; sonst leer"),
        ])
        // The schema is fixed; failing here is a programming error.
        return try! GenerationSchema(root: root, dependencies: [])
    }()

    static func decode(_ content: GeneratedContent) throws -> ClassifyJSON {
        func text(_ key: String) -> String { ((try? content.value(String.self, forProperty: key)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let category = text("kategorie")
        let beleg = text("beleg"), draftBeleg = text("entwurf_beleg")
        return ClassifyJSON(kategorie: categories.contains(category) ? category : "sonstiges", absender: text("absender"), art: text("art"),
                            datum: text("datum"), betreff: text("betreff"),
                            entwurf: (try? content.value(Bool.self, forProperty: "entwurf")) ?? false,
                            beleg: beleg.isEmpty ? nil : beleg, entwurf_beleg: draftBeleg.isEmpty ? nil : draftBeleg)
    }
}
#endif
