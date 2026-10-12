import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// How tidying classifies a document whose place stays unclear after reading (stage 3 of `proposeSort`).
///
/// Only the system's on-device model (Apple Foundation Models, guided output, about 2 s per file). Swift never asks the
/// local model itself: that one belongs to Pi. Without the system model, or when it declines, the document goes to
/// "Dokumente" by kind (`PreSort.documentByKind`). Every file has a time limit: a slow answer never holds up the preview.
/// The answer goes through the evidence check (`LocalEngine.documentInsight`).
public enum TidyClassifier {
    /// Characters of document text per file: about the first page. Enough for sender, kind and date in the letterhead.
    public static let excerptChars = 1500
    /// At most this long per file; then the file stays where it is. Measured: p50 2.0 s per file.
    public static let perFileTimeout: Duration = .seconds(20)
    /// Answer budget for the system model (the guided answer is a handful of short fields).
    static let appleResponseTokens = 200

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
/// The classify schema for the system model. Built at runtime: the Command Line Tools don't ship the @Generable
/// macro plugin. Guided output is constrained to it.
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
