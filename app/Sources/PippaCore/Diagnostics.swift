import Foundation
import os

/// Small rolling log for troubleshooting with testers: `pippa.log` plus an older file `pippa.1.log`.
/// Only events go in (name, error code, duration, model, version), never file contents, conversation text or paths.
/// Everything stays on this Mac; Pippa uploads nothing.
public final class DiagnosticsLog: @unchecked Sendable {
    public static let maxFileBytes = 1_000_000
    public static let maxFieldLength = 120
    public static let shared = DiagnosticsLog(directory: defaultDirectory)

    /// `~/Library/Logs/Pippa` (earlier versions ran in the App Sandbox and wrote to their container).
    public static var defaultDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["PIPPA_LOG_DIR"], !override.isEmpty { return URL(fileURLWithPath: override, isDirectory: true) }
        return (FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Logs/Pippa", isDirectory: true)
    }

    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("pippa.log") }
    private var olderURL: URL { directory.appendingPathComponent("pippa.1.log") }
    private let queue = DispatchQueue(label: "pippa.diagnostics")
    private let logger = Logger(subsystem: "app.pippa", category: "events")
    private let maxBytes: Int

    public init(directory: URL, maxFileBytes: Int = DiagnosticsLog.maxFileBytes) {
        self.directory = directory; self.maxBytes = maxFileBytes
    }

    /// Writes a line. `fields` only with short values (code, model, duration, version); everything is shortened and stripped of paths, addresses and keys.
    public func event(_ name: String, _ fields: [String: String] = [:]) {
        let line = Self.format(name: name, fields: fields, date: Date())
        logger.notice("\(line, privacy: .public)")
        queue.async { self.append(line) }
    }

    /// Waits until everything is written (for checks and before quitting).
    public func flush() { queue.sync {} }

    static func format(name: String, fields: [String: String], date: Date) -> String {
        var parts = [ISO8601DateFormatter().string(from: date), Self.redact(name)]
        for key in fields.keys.sorted() { parts.append("\(Self.redact(key))=\(Self.redact(fields[key] ?? ""))") }
        return parts.joined(separator: " ")
    }

    /// Removes what looks like personal data, and shortens. Deliberately coarse: when in doubt, gone.
    public static func redact(_ text: String) -> String {
        var value = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let rules: [(String, String)] = [
            (#"[\w.+\-]+@[\w\-]+\.[\w.\-]+"#, "<mail>"),
            (#"(?i)(bearer\s+|sk-|key[=:\s]+)[A-Za-z0-9._\-]{6,}"#, "<schluessel>"),
            (#"[A-Za-z][A-Za-z0-9+.\-]*://\S+"#, "<adresse>"),
            (#"(~|/)[^\s]*/[^\s]*"#, "<pfad>"),
            (#"\b[A-Za-z0-9_\-]{32,}\b"#, "<kennung>"),
        ]
        for (pattern, template) in rules {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            value = expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: template)
        }
        if value.count > maxFieldLength { value = String(value.prefix(maxFieldLength)) + "…" }
        return value
    }

    private func append(_ line: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size + line.utf8.count + 1 > maxBytes {
            try? fm.removeItem(at: olderURL)
            try? fm.moveItem(at: fileURL, to: olderURL)
        }
        if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }
}

/// App version and build for the log and problem report.
public enum AppVersion {
    public static var short: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L("Development", table: "Core") }
    public static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
    public static var label: String { "\(short) (\(build))" }
}

/// Error → a short German sentence for the UI. Technical details go only into the log.
public enum UserMessage {
    public static var generic: String { L("That didn’t work just now. Please try again. If it keeps happening, choose “Report a Problem…” in the Help menu.", table: "Core") }

    /// Every error gets German text; system texts (English, with technical terms) never reach the person.
    public static func text(for error: Error, context: String = "") -> String {
        record(error, context: context)
        if error is PippaError || error is InferenceError || error is AnswerFailure
            || error is ConversationStoreError { return error.localizedDescription }
        if let url = error as? URLError { return network(url) }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain || ns.domain == NSCocoaErrorDomain {
            let reason = SystemError.reason(error)
            if reason != SystemError.reason(errno: 0) { return L("%@ Check the folder or the free space and try again.", table: "Core", reason) }
        }
        return generic
    }

    public static func network(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            L("There’s no internet connection right now. Check your Wi-Fi or cable, then try again.", table: "Core")
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            L("The connection isn’t working right now. Please try again in a few minutes.", table: "Core")
        default: generic
        }
    }

    /// Only the kind and code of the error, never description or contents.
    public static func record(_ error: Error, context: String = "") {
        let ns = error as NSError
        var fields = ["art": String(describing: type(of: error)), "bereich": ns.domain, "code": String(ns.code)]
        if let failure = error as? AnswerFailure, case .pi(let code, _) = failure { fields["pi"] = code.rawValue }
        if !context.isEmpty { fields["wo"] = context }
        DiagnosticsLog.shared.event("fehler", fields)
    }
}

public extension AnswerFailureCode {
    /// Everyday sentence per code. `switch` without `default`: a new code breaks the build until it has a text.
    var fallbackText: String {
        switch self {
        case .providerUnreachable: L("The answer didn’t come through just now. Please try again in a moment.", table: "Core")
        case .providerRejected: L("The request was turned down. Please check the service and address under Settings › Advanced.", table: "Core")
        case .authFailed: L("The service you chose didn’t let me in. Please check the key under Settings › Advanced.", table: "Core")
        }
    }
}
