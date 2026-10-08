import AppKit
import PippaCore

/// "Problem melden …": opens a prepared email and shows the log file in Finder so the person can attach it.
/// Nothing is sent or uploaded automatically.
enum ProblemReport {
    static let recipient = "tschnorpfeil@gmail.com"

    static func mailURL() -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = recipient
        components.queryItems = [
            URLQueryItem(name: "subject", value: T("Pippa %@: Problem", table: "App", AppVersion.label)),
            URLQueryItem(name: "body", value: T("What did you do?\n\n\nWhat happened?\n\n\n(Please attach the file “pippa.log” from the Finder window here.)", table: "App")),
        ]
        return components.url
    }

    @MainActor static func open() {
        DiagnosticsLog.shared.event("problem-melden", ["version": AppVersion.label])
        DiagnosticsLog.shared.flush()
        let log = DiagnosticsLog.shared.fileURL
        if FileManager.default.fileExists(atPath: log.path) { NSWorkspace.shared.activateFileViewerSelecting([log]) }
        else { NSWorkspace.shared.open(DiagnosticsLog.shared.directory) }
        if let url = mailURL() { NSWorkspace.shared.open(url) }
    }
}
