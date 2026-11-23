import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Fast, on-device reflex model for short, non-agentic helper tasks (such as conversation titles).
public protocol LocalReflexModel: Sendable {
    /// Whether the on-device reflex model can answer right now without network or setup.
    var isAvailable: Bool { get }
    /// Generates a short, single-line conversation title for the user's opening prompt, or `nil` on fallback.
    func conversationTitle(for prompt: String, language: String) async -> String?
}

/// Cleans and bounds inputs and outputs for `LocalReflexModel` title generation.
public enum LocalReflexTitleSanitizer {
    /// Maximum prompt length passed to the on-device reflex model.
    public static let maxInputLength = 2000
    /// Maximum length of a refined conversation title.
    public static let maxTitleLength = 60

    private static let trimQuotes = CharacterSet(charactersIn: "\"'“”„‚‘’«»‹›")

    private static let refusalSubstrings: [String] = [
        "i'm sorry",
        "i am sorry",
        "sorry, i can",
        "sorry, i cannot",
        "i apologize",
        "i cannot ",
        "i can't ",
        "i am unable to",
        "i'm unable to",
        "unable to assist",
        "unable to help",
        "unable to generate",
        "unable to create",
        "unable to provide",
        "cannot assist",
        "can't assist",
        "cannot help with",
        "can't help with",
        "cannot fulfill",
        "can't fulfill",
        "cannot generate a title",
        "can't generate a title",
        "as an ai",
        "as a language model",
        "may contain sensitive content",
        "sensitive content",
        "safety policy",
        "content policy",
        "usage policy",
        "against my policy",
        "violates safety",
        "violates policy",
        "guardrail",
        "content filter",
        "don't have enough information",
        "es tut mir leid",
        "ich kann leider",
        "ich kann dabei nicht",
        "ich kann dir dabei nicht",
        "ich kann ihnen dabei nicht",
        "ich kann keine auskunft",
        "ich kann keinen titel",
        "ich kann diesen text nicht",
        "leider kann ich",
        "als ki-modell",
        "als sprachmodell",
        "sensible inhalte",
        "sensibler inhalt",
    ]

    private static let exactBoilerplate: Set<String> = [
        "untitled",
        "no title",
        "none",
        "n/a",
        "null",
        "sorry",
        "refused",
        "kein titel",
    ]

    /// Trims outer whitespace and caps the prompt sent to the reflex model at `limit` characters.
    public static func truncateInput(_ prompt: String, limit: Int = maxInputLength) -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0 else { return "" }
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit))
    }

    /// Normalizes a raw model response into a single-line, plain conversation title, or `nil` if unusable.
    public static func sanitize(_ raw: String) -> String? {
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let firstLine = lines.first else { return nil }
        if isRefusalOrBoilerplate(firstLine) { return nil }

        var cleaned = firstLine
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "`", with: "")

        // Repeatedly peel outer whitespace, quotes, and leading markdown heading markers (`#`).
        while true {
            let before = cleaned
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            while cleaned.hasPrefix("#") {
                cleaned.removeFirst()
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            cleaned = cleaned.trimmingCharacters(in: trimQuotes)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned == before { break }
        }

        // Collapse internal whitespace runs (including tabs) into single spaces.
        cleaned = cleaned
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        guard !cleaned.isEmpty else { return nil }
        guard cleaned.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else {
            return nil
        }
        guard !isRefusalOrBoilerplate(cleaned) else { return nil }

        if cleaned.count > maxTitleLength {
            let prefix = String(cleaned.prefix(maxTitleLength))
            let nextIndex = cleaned.index(cleaned.startIndex, offsetBy: maxTitleLength)
            if !cleaned[nextIndex].isWhitespace,
               let lastSpace = prefix.lastIndex(where: \.isWhitespace),
               prefix.distance(from: prefix.startIndex, to: lastSpace) >= maxTitleLength / 2 {
                cleaned = String(prefix[..<lastSpace]).trimmingCharacters(in: .whitespaces)
            } else {
                cleaned = prefix.trimmingCharacters(in: .whitespaces)
            }
        }

        return cleaned.isEmpty ? nil : cleaned
    }

    private static func isRefusalOrBoilerplate(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if exactBoilerplate.contains(normalized) { return true }
        return refusalSubstrings.contains { normalized.contains($0) }
    }
}

/// Pure rules for safely applying an asynchronous conversation title refinement.
public enum ConversationTitlePolicy {
    /// Returns `true` only if the conversation still has its `initial` title (no manual user rename)
    /// and `refined` sanitizes to a different, non-empty title.
    public static func shouldApplyRefinedTitle(current: String, initial: String, refined: String?) -> Bool {
        resolvedTitle(current: current, initial: initial, refined: refined) != nil
    }

    /// Returns the sanitized refined title to persist, or `nil` if the current title must stay unchanged.
    public static func resolvedTitle(current: String, initial: String, refined: String?) -> String? {
        guard current == initial,
              let candidate = refined.flatMap(LocalReflexTitleSanitizer.sanitize),
              candidate != current else {
            return nil
        }
        return candidate
    }
}

/// Hard wall-clock timeout wrapper for reflex calls so a stalled model never hangs callers.
enum LocalReflexTimeout {
    private final class Gate<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T?, Never>?
        private var resolved = false
        private var pendingValue: T??
        private var workTask: Task<Void, Never>?
        private var timerTask: Task<Void, Never>?

        func attach(_ continuation: CheckedContinuation<T?, Never>) {
            let immediate: T?? = lock.withLock {
                if resolved {
                    let value = pendingValue ?? nil
                    pendingValue = nil
                    return .some(value)
                }
                self.continuation = continuation
                return nil
            }
            if let value = immediate {
                continuation.resume(returning: value)
            }
        }

        func setTasks(work: Task<Void, Never>, timer: Task<Void, Never>) {
            let alreadyResolved: Bool = lock.withLock {
                workTask = work
                timerTask = timer
                return resolved
            }
            if alreadyResolved {
                work.cancel()
                timer.cancel()
            }
        }

        func resolve(_ value: T?) {
            let action: (CheckedContinuation<T?, Never>?, Task<Void, Never>?, Task<Void, Never>?)? = lock.withLock {
                guard !resolved else { return nil }
                resolved = true
                let cont = continuation
                continuation = nil
                if cont == nil { pendingValue = .some(value) }
                let work = workTask
                let timer = timerTask
                workTask = nil
                timerTask = nil
                return (cont, work, timer)
            }
            guard let action else { return }
            action.1?.cancel()
            action.2?.cancel()
            action.0?.resume(returning: value)
        }
    }

    static func run<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T?
    ) async -> T? {
        let gate = Gate<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.attach(continuation)
                let work = Task {
                    let value = try? await operation()
                    gate.resolve(value)
                }
                let timer = Task {
                    try? await Task.sleep(for: duration)
                    gate.resolve(nil)
                }
                gate.setTasks(work: work, timer: timer)
            }
        } onCancel: {
            gate.resolve(nil)
        }
    }
}

/// Tier-0 on-device reflex backed by Apple's `FoundationModels` without `@Generable` macros
/// so Pippa stays buildable with macOS Command Line Tools.
public struct AppleFoundationReflex: LocalReflexModel {
    public let timeout: Duration
    private let respectDisableEnv: Bool

    public init(timeout: Duration = .seconds(4), respectDisableEnv: Bool = true) {
        self.timeout = timeout
        self.respectDisableEnv = respectDisableEnv
    }

    public var isAvailable: Bool {
        if respectDisableEnv, ProcessInfo.processInfo.environment["PIPPA_NO_SYSTEM_MODEL"] == "1" {
            return false
        }
        #if canImport(FoundationModels)
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        if case .available = model.availability {
            return true
        }
        return false
        #else
        return false
        #endif
    }

    public func conversationTitle(for prompt: String, language: String) async -> String? {
        guard isAvailable else { return nil }
        let bounded = LocalReflexTitleSanitizer.truncateInput(prompt)
        guard !bounded.isEmpty else { return nil }
        #if canImport(FoundationModels)
        let instructions = Self.titleInstructions(for: language)
        let raw: String? = await LocalReflexTimeout.run(timeout) {
            let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
            guard case .available = model.availability else { return nil }
            let session = LanguageModelSession(model: model, instructions: instructions)
            let response = try await session.respond(to: bounded)
            return response.content
        }
        return raw.flatMap(LocalReflexTitleSanitizer.sanitize)
        #else
        return nil
        #endif
    }

    static func titleInstructions(for language: String) -> String {
        let code = language.lowercased()
        if code.hasPrefix("de") {
            return "Erstelle einen kurzen, sachlichen Gesprächs-Titel auf Deutsch (2 bis 6 Wörter, maximal 60 Zeichen). Gib nur den Titel als einzelne Zeile ohne Anführungszeichen, ohne Markdown und ohne Erklärung zurück."
        }
        if code.hasPrefix("en") {
            return "Create a short, factual conversation title in English (2 to 6 words, maximum 60 characters). Return only the plain title on a single line with no quotes, no markdown, and no explanation."
        }
        return "Create a short, factual conversation title (2 to 6 words, maximum 60 characters) matching the language of the message. Return only the plain title on a single line with no quotes, no markdown, and no explanation."
    }
}

/// Deterministic `LocalReflexModel` stand-in for offline checks and CI.
public final class StubReflexModel: LocalReflexModel, @unchecked Sendable {
    public let isAvailable: Bool
    private let timeout: Duration?
    private let handler: @Sendable (String, String) async throws -> String?
    private let lock = NSLock()
    private var _receivedPrompts: [String] = []
    private var _receivedLanguages: [String] = []

    public var receivedPrompts: [String] { lock.withLock { _receivedPrompts } }
    public var receivedLanguages: [String] { lock.withLock { _receivedLanguages } }
    public var callCount: Int { lock.withLock { _receivedPrompts.count } }

    public init(available: Bool = true, title: String? = nil) {
        self.isAvailable = available
        self.timeout = nil
        self.handler = { _, _ in title }
    }

    public init(
        available: Bool = true,
        timeout: Duration? = nil,
        handler: @escaping @Sendable (String, String) async throws -> String?
    ) {
        self.isAvailable = available
        self.timeout = timeout
        self.handler = handler
    }

    public func conversationTitle(for prompt: String, language: String) async -> String? {
        guard isAvailable else { return nil }
        let bounded = LocalReflexTitleSanitizer.truncateInput(prompt)
        guard !bounded.isEmpty else { return nil }
        lock.withLock {
            _receivedPrompts.append(bounded)
            _receivedLanguages.append(language)
        }
        let raw: String?
        if let timeout {
            let handler = self.handler
            raw = await LocalReflexTimeout.run(timeout) {
                try await handler(bounded, language)
            }
        } else {
            raw = try? await handler(bounded, language)
        }
        return raw.flatMap(LocalReflexTitleSanitizer.sanitize)
    }
}
