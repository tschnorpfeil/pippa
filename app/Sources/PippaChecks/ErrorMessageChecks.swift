import Foundation
import PippaCore

/// Error texts and log: every error code has a German sentence, none contains technical terms, the log stays small and free of personal data.
func runErrorMessageChecks() {
    let banned = ["http", "econn", "exit code", "exit-code", "stack", "exception", "traceback", "errno", "nserror", "localizeddescription",
                  "optional(", "token", "json", "timeout", "endpunkt", "socket", "stderr", "stdout", "null", "undefined", "pi-runtime", "node"]
    func clean(_ text: String) -> Bool {
        let lower = text.replacingOccurrences(of: "API-Schlüssel", with: "Schlüssel").replacingOccurrences(of: "https://", with: "").lowercased()
        return !text.isEmpty && !banned.contains { lower.contains($0) }
    }
    func offender(_ texts: [String]) -> String? { texts.first { !clean($0) } }

    // All texts a person can see.
    let receipt = JobReceipt(id: UUID(), summary: "3 Dateien geordnet", detail: "", revealURL: nil, undoDetail: nil)
    let pippa: [PippaError] = [
        .scopeMissing, .outsideScope, .unknownJob, .undoIncomplete(restored: 2, conflicts: 1), .modelUnavailable, .modelFailed,
        .downloadFailed("intern"), .checksumMismatch, .serverMissing, .notEnoughSpace(bytes: 3_000_000_000), .writeFailed(""), .nothingToExport,
        .accessDenied("Kalender"), .appNotOpen("Mail"), .entryFailed(""), .notAvailable, .partial(receipt: receipt, why: "Abgebrochen."),
    ]
    let pippaTexts = pippa.map { $0.errorDescription ?? "" }
    check("Error texts: every PippaError has a clean German sentence") { offender(pippaTexts) == nil }

    let inference: [InferenceError] = [.invalidConnection("Bitte eine gültige Modell-ID angeben."), .missingCredential, .busy, .credentialStorage(-25300), .invalidResponse]
    check("Error texts: connection errors are clean") { offender(inference.map { $0.errorDescription ?? "" }) == nil }

    let failures: [AnswerFailure] = [.runtime("Es kam zu lange keine Antwort."), .stopped(partial: "")]
    check("Error texts: answer failures are clean") {
        offender(failures.map { $0.errorDescription ?? "" }) == nil
    }

    check("Error texts: every connection error code has a sentence in the core") {
        AnswerFailureCode.allCases.allSatisfy { clean($0.fallbackText) }
    }

    check("Error texts: history, network and system errors are clean") {
        var texts: [String] = [ConversationStoreError.corrupted, .unsupportedVersion, .unknownConversation, .changedExternally].compactMap { $0.errorDescription }
        texts += [UserMessage.generic]
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost, .badServerResponse, .secureConnectionFailed] {
            texts.append(UserMessage.network(URLError(code)))
        }
        for e in [EPERM, ENOENT, EEXIST, EXDEV, ENOSPC, 999] { texts.append(SystemError.reason(errno: e)) }
        return offender(texts) == nil
    }

    check("Error texts: foreign errors never show the English system text") {
        struct Odd: Error {}
        let texts = [UserMessage.text(for: Odd(), context: "check"),
                     UserMessage.text(for: NSError(domain: "WeirdDomain", code: 42, userInfo: [NSLocalizedDescriptionKey: "The operation couldn’t be completed. (HTTP 500)"])),
                     UserMessage.text(for: URLError(.notConnectedToInternet)),
                     UserMessage.text(for: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)))]
        return offender(texts) == nil && !texts[1].contains("operation") && texts[3].contains(L("There’s no space left.", table: "Core"))
    }

    // Log
    check("Log: paths, addresses, mail and keys are removed, fields shortened") {
        let raw = "Datei /Users/anna/Dokumente/Steuer 2025.pdf an anna@example.com über https://api.example.com/v1 mit sk-abcdef1234567890 und Bearer abc.def-123456"
        let out = DiagnosticsLog.redact(raw)
        let long = DiagnosticsLog.redact(String(repeating: "x", count: 500))
        return !out.contains("anna") && !out.contains("/Users") && !out.contains("example.com") && !out.contains("abcdef1234567890") && !out.contains("abc.def-123456")
            && long.count <= DiagnosticsLog.maxFieldLength + 1
            && !DiagnosticsLog.redact("a\nb").contains("\n")
    }
    check("Log: file stays under the size cap (2 files), newest lines stay") {
        let folder = dir("diagnostics")
        let log = DiagnosticsLog(directory: folder, maxFileBytes: 4_000)
        for i in 0..<400 { log.event("probe", ["nummer": String(i), "pfad": "/Users/anna/geheim/\(i).pdf"]) }
        log.flush()
        let size = { (name: String) -> Int in (try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.size] as? Int) ?? 0 }
        let current = (try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? ""
        let files = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        return size("pippa.log") <= 4_000 && size("pippa.1.log") <= 4_000 && files == ["pippa.1.log", "pippa.log"]
            && current.contains("nummer=399") && !current.contains("geheim") && !current.contains("anna")
    }
    check("Log: errors reach the log without a description") {
        let folder = dir("diagnostics-error")
        let log = DiagnosticsLog.shared
        _ = folder
        let before = (try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? ""
        _ = UserMessage.text(for: NSError(domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "Inhalt von Rechnung Müller"]), context: "pruefung")
        log.flush()
        let added = ((try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? "").dropFirst(before.count)
        return added.contains("bereich=Test") && added.contains("code=7") && !added.contains("Müller")
    }
    check("Log: version and build are never empty") { !AppVersion.label.isEmpty && !AppVersion.build.isEmpty }
}
