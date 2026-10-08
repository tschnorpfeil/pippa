import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The system's small language model (Apple Intelligence, on-device only) for Pippa's own short texts, e.g. the
/// first line for a letter (`LetterFacts.refined`). Conversations are run by Pi.
public enum QuickModelAvailability: Sendable, Equatable {
    case available, unavailable
}

public enum QuickModelError: Error, Sendable, Equatable {
    case contextOverflow, declined, failed
}

/// Real answers come from `AppleQuickModel`, checks pass a stand-in.
public protocol QuickLanguageModel: Sendable {
    var availability: QuickModelAvailability { get }
    /// Answer in chunks (each chunk only the new text). Errors arrive as `QuickModelError`.
    func stream(instructions: String, prompt: String, maximumTokens: Int) -> AsyncThrowingStream<String, Error>
}

/// The system's language model (FoundationModels, macOS 26+), on this Mac only, never via Apple's servers.
public struct AppleQuickModel: QuickLanguageModel {
    /// `nil` before macOS 26 or without FoundationModels in the SDK.
    public static var system: AppleQuickModel? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return AppleQuickModel() }
        #endif
        return nil
    }

    private init() {}

    public var availability: QuickModelAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            guard case .available = model.availability, model.supportsLocale(Locale(identifier: "de_DE")) else { return .unavailable }
            return .available
        }
        #endif
        return .unavailable
    }

    public func stream(instructions: String, prompt: String, maximumTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                let task = Task {
                    let session = LanguageModelSession(model: .default, instructions: instructions)
                    var sent = ""
                    do {
                        let stream = session.streamResponse(to: prompt, options: GenerationOptions(temperature: 0.4, maximumResponseTokens: maximumTokens))
                        for try await snapshot in stream {
                            try Task.checkCancellation()
                            // Each snapshot contains the whole text so far; only the new part is passed on.
                            let text = snapshot.content
                            guard text.count > sent.count, text.hasPrefix(sent) else { continue }
                            continuation.yield(String(text.dropFirst(sent.count)))
                            sent = text
                        }
                        continuation.finish()
                    } catch is CancellationError {
                        continuation.finish(throwing: CancellationError())
                    } catch {
                        continuation.finish(throwing: Self.classify(error))
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
                return
            }
            #endif
            continuation.finish(throwing: QuickModelError.failed)
        }
    }

    #if canImport(FoundationModels)
    /// Greedy selection. The macOS 27 SDK (Swift ≥ 6.4) calls the parameter `samplingMode`, older SDKs `sampling`;
    /// so Pippa also builds with Xcode 26 (CI runner).
    @available(macOS 26.0, *)
    public static func greedy(maximumResponseTokens: Int) -> GenerationOptions {
        #if compiler(>=6.4)
        GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maximumResponseTokens)
        #else
        GenerationOptions(sampling: .greedy, maximumResponseTokens: maximumResponseTokens)
        #endif
    }

    /// From macOS 27 the errors are called `LanguageModelError`, before that `GenerationError`; both are classified.
    @available(macOS 26.0, *)
    static func classify(_ error: Error) -> QuickModelError {
        #if compiler(>=6.4)
        if #available(macOS 27.0, *), let modern = error as? LanguageModelError {
            switch modern {
            case .contextSizeExceeded: return .contextOverflow
            case .guardrailViolation, .refusal: return .declined
            default: return .failed
            }
        }
        #endif
        if let legacy = error as? LanguageModelSession.GenerationError {
            switch legacy {
            case .exceededContextWindowSize: return .contextOverflow
            case .guardrailViolation, .refusal: return .declined
            default: return .failed
            }
        }
        return .failed
    }
    #endif
}
