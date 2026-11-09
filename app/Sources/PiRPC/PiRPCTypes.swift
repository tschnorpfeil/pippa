import Foundation

/// Errors the app must distinguish. User-facing texts come from the app, not this client.
public enum PiRPCError: Error, LocalizedError, Equatable, Sendable {
    /// No executable `pi` at the path.
    case notInstalled(path: String)
    /// `pi --version` reports a version outside the tested range.
    case versionMismatch(found: String, supported: String)
    /// `pi --version` returned nothing readable (or did not run).
    case versionUnreadable(output: String)
    case notRunning
    /// A response is already running; use `steer` or `abort` first.
    case busy
    /// Pi rejected a command (`success: false`).
    case commandFailed(command: String, message: String)
    /// The Pi process ended. `diagnostics`: end of stderr, for debugging only.
    case processExited(status: Int32, diagnostics: String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let path): "Pi is not installed at \(path)."
        case .versionMismatch(let found, let supported): "Pi \(found) is not a tested version (tested: \(supported))."
        case .versionUnreadable(let output): "Could not read the Pi version: \(output.prefix(200))"
        case .notRunning: "Pi is not running."
        case .busy: "Pi is still answering."
        case .commandFailed(let command, let message): "Pi rejected \(command): \(message)"
        case .processExited(let status, _): "Pi stopped unexpectedly (exit status \(status))."
        }
    }
}

public struct PiRPCConfiguration: Sendable {
    /// The `pi` executable (e.g. ~/.local/bin/pi).
    public var executable: URL
    /// Pi's working directory: write/edit/bash create relative paths there.
    public var workingDirectory: URL
    /// Additional environment (e.g. PI_CODING_AGENT_DIR, PIPPA_WEB_DIR). PATH gets Homebrew added because `pi` is a
    /// Node script and an app launched from Finder only knows /usr/bin:/bin.
    public var environment: [String: String]
    /// Loaded with `--extension` (Pippa's tools, helps and web access).
    public var extensions: [URL]
    /// Further Pi options, e.g. `--no-session`, `--tools read,write`, `--append-system-prompt …`.
    public var arguments: [String]
    /// Installer (`PiLaunchSpec`): arguments directly after `executable`, before all Pi options, e.g. the path to the
    /// CLI of the pinned release when `executable` is Pippa's Node. Also applies to `--version`.
    public var launcherArguments: [String] = []
    public init(executable: URL, workingDirectory: URL, environment: [String: String] = [:], extensions: [URL] = [], arguments: [String] = ["--no-session"]) {
        self.executable = executable; self.workingDirectory = workingDirectory; self.environment = environment
        self.extensions = extensions; self.arguments = arguments
    }
}

/// What happens during a response, in order.
public enum PiRPCEvent: Sendable, Equatable {
    /// A piece of response text.
    case textDelta(String)
    /// A piece of the model's reasoning before or between answers (only when thinking is on).
    case thinkingDelta(String)
    /// Pi calls a tool. `arguments`: JSON with long string values shortened, never cut mid-structure.
    case toolStarted(id: String, name: String, arguments: String)
    case toolEnded(id: String, name: String, isError: Bool, result: String, outcome: PiActionRecord.Outcome? = nil,
                   fileAccessFailure: PiFileAccessFailure? = nil)
    /// Pi picked up another message from the person (delivered via `steer`).
    case userMessage(String)
    /// A model response is done. `stopReason`: "stop", "toolUse", "aborted", "error", …
    case assistantEnded(text: String, stopReason: String, error: String?)
    /// `ctx.ui.notify` of an extension.
    case notice(String, kind: String)
    /// Pi does not continue on its own (`agent_settled`). Cancellation can happen between assistant messages,
    /// so `aborted` is authoritative even when the last assistant stopped for tool use or completed normally.
    case settled(aborted: Bool)
}

/// A confirmation request from an extension (`extension_ui_request` with `confirm`, `select`, `input` or `editor`).
public struct PiUIRequest: Sendable, Equatable {
    public let id: String
    public let method: String
    public let title: String
    public let message: String
    public let options: [String]
    public let placeholder: String?
    public let prefill: String?
    public let timeout: Int?

    public init(id: String, method: String, title: String, message: String, options: [String] = [],
                placeholder: String? = nil, prefill: String? = nil, timeout: Int? = nil) {
        self.id = id; self.method = method; self.title = title; self.message = message; self.options = options
        self.placeholder = placeholder; self.prefill = prefill; self.timeout = timeout
    }
}

public enum PiUIResponse: Sendable, Equatable {
    case confirmed(Bool)
    case value(String)
    case cancelled
}

public typealias PiUIHandler = @Sendable (PiUIRequest) async -> PiUIResponse
