import Foundation

// Value types around an answer: sources read (`DocumentSnapshot`, source check, what was shown on the Pi path) and
// errors/stopping (`AnswerFailure`).

/// Error codes of a connection (today: "Test connection", ModelConnectionTest). The message is already everyday language.
public enum AnswerFailureCode: String, Sendable, CaseIterable {
    case providerUnreachable = "provider_unreachable", providerRejected = "provider_rejected", authFailed = "auth_failed", providerBusy = "provider_busy"
}
public enum AnswerFailure: LocalizedError, Sendable {
    case runtime(String)
    /// Error of a connection: code for the app, message for the person.
    case pi(AnswerFailureCode, String)
    /// Stopped. Not an error for the person; `partial` is the text written up to then.
    case stopped(partial: String)
    public var errorDescription: String? {
        switch self {
        case .runtime(let message), .pi(_, let message): message
        case .stopped: L("Answer stopped.", table: "Core")
        }
    }
}
