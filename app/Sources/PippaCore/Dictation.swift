import Foundation

/// Speaking instead of typing: decisions and text handling without Speech or AVFoundation, so PippaChecks can run
/// them. The recognizer itself is in the app (Pippa/App/Dictation.swift).
public enum DictationAccess: Sendable, Equatable { case notAsked, granted, denied }

/// Why dictation cannot listen; the composer shows one sentence for it.
public enum DictationBlock: String, Sendable, Equatable {
    case microphoneDenied, speechDenied, notOnDevice, noMicrophone, failed

    /// Where the person can fix it; nil when System Settings cannot.
    public var settingsURL: URL? {
        switch self {
        case .microphoneDenied: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .speechDenied: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        case .notOnDevice: URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
        case .noMicrophone, .failed: nil
        }
    }
}

public enum DictationStep: Sendable, Equatable { case askMicrophone, askSpeech, start, blocked(DictationBlock) }

public enum DictationGate {
    /// Longest single dictation; then it is inserted as if Return was pressed.
    public static let maxSeconds = 120

    /// Microphone first, then speech recognition, then listening on this Mac only (no server fallback).
    public static func next(microphone: DictationAccess, speech: DictationAccess, onDevice: Bool) -> DictationStep {
        switch microphone {
        case .denied: return .blocked(.microphoneDenied)
        case .notAsked: return .askMicrophone
        case .granted: break
        }
        switch speech {
        case .denied: return .blocked(.speechDenied)
        case .notAsked: return .askSpeech
        case .granted: break
        }
        return onDevice ? .start : .blocked(.notOnDevice)
    }

    /// The app's language decides what is recognized ("de…" → de-DE, otherwise en-US).
    public static func localeIdentifier(appLanguage: String) -> String { appLanguage.hasPrefix("de") ? "de-DE" : "en-US" }

    /// Appends what was heard to what is typed: trimmed, one space between, nothing when nothing was heard.
    public static func inserting(_ transcript: String, into query: String) -> String {
        let heard = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty else { return query }
        if query.isEmpty { return heard }
        return query.last.map { $0.isWhitespace } == true ? query + heard : query + " " + heard
    }
}
