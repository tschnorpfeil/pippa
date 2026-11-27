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
        .downloadFailed("intern"), .checksumMismatch, .serverMissing, .notEnoughSpace(bytes: 3_000_000_000), .notEnoughMemory, .writeFailed(""), .nothingToExport,
        .accessDenied("Kalender"), .appNotOpen("Mail"), .entryFailed(""), .notAvailable, .partial(receipt: receipt, why: "Abgebrochen."),
    ]
    let pippaTexts = pippa.map { $0.errorDescription ?? "" }
    check("Error texts: every PippaError has a clean German sentence") { offender(pippaTexts) == nil }
    check("Error texts: the low-memory sentence is translated") {
        let key = "Your Mac is short on memory right now. Close a few apps or browser windows, then try again."
        return L(key, table: "Core", language: "en") == key
            && L(key, table: "Core", language: "de") == "Dein Mac hat gerade zu wenig Arbeitsspeicher frei. Schließ ein paar Apps oder Browserfenster und versuch es dann noch einmal."
    }

    // The local AI refuses a model that does not fit in memory (HTTP 507); Pi passes oMLX's text through.
    let memoryText = #"507: {"message":"Model 'ornith-1.5-9b-mlx-4bit' (4.93GB) does not fit under the dynamic memory ceiling (4.46GB). Close other apps to free RAM (macOS and other apps leave oMLX 4.46GB of the 21.00GB static cap, and oMLX already uses all but 4.29GB of it), raise memory_guard_tier (safe → balanced → aggressive), or use a smaller model.","type":"server_error","param":null,"code":null}"#
    check("Local AI: oMLX's out-of-memory refusal reads as the short-on-memory sentence, without the raw text") {
        let plain = OMLXServer.plainFailure(memoryText, online: false)
        return plain == PippaError.notEnoughMemory.errorDescription && plain?.contains("507") == false
    }
    check("Local AI: a request the memory guard ended mid-answer reads as the short-on-memory sentence too") {
        let aborted = "oMLX memory guard aborted this request mid-prefill: Request aborted: process memory limit exceeded (usage 6.4 GB, abort threshold (hard watermark) 6.4 GB, dynamic ceiling 6.7 GB). Close other apps to free RAM, raise memory_guard_tier (safe → balanced → aggressive), or reduce context length."
        return OMLXServer.plainFailure(aborted, online: false) == PippaError.notEnoughMemory.errorDescription
            && OMLXServer.plainFailure(aborted, online: true) == nil
    }
    check("Local AI: the status 507 or the memory ceiling alone is enough, in any case") {
        OMLXServer.isOutOfMemory("HTTP 507 Insufficient Storage") && OMLXServer.isOutOfMemory("Does Not Fit Under The Dynamic Memory Ceiling")
    }
    check("Local AI: any other local error stays as it was; an online error is never read this way") {
        OMLXServer.plainFailure("500: {\"message\":\"internal error\"}", online: false) == nil
            && OMLXServer.plainFailure("connection refused, 5070 files", online: false) == nil
            && OMLXServer.plainFailure("400: the request has 40,507 tokens, more than the context of 32,768", online: false) == nil
            && OMLXServer.isOutOfMemory("507 status code (no body)") && OMLXServer.isOutOfMemory("Status code: 507")
            && OMLXServer.plainFailure(memoryText, online: true) == nil
            && PiProviderClient.problem(in: "401 Unauthorized") == .signedOut && PiProviderClient.problem(in: memoryText) == nil
    }

    let inference: [InferenceError] = [.invalidConnection("Bitte eine gültige Modell-ID angeben."), .missingCredential, .busy, .credentialStorage(-25300), .invalidResponse]
    check("Error texts: connection errors are clean") { offender(inference.map { $0.errorDescription ?? "" }) == nil }

    let failures: [AnswerFailure] = [.runtime("Es kam zu lange keine Antwort."), .stopped(partial: "")]
    check("Error texts: answer failures are clean") {
        offender(failures.map { $0.errorDescription ?? "" }) == nil
    }

    check("Error texts: every connection error code has a sentence in the core") {
        AnswerFailureCode.allCases.allSatisfy { clean($0.fallbackText) }
    }

    check("Error texts: network and system errors are clean") {
        var texts: [String] = [UserMessage.generic]
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
        let raw = "Datei /Users/anna/Dokumente/Steuer 2025.pdf an anna@example.com über https://api.example.com/v1 mit sk-abcdef1234567890, Bearer abc.def-123456, token=short99, password=geheim und ghp_12345678"
        let out = DiagnosticsLog.redact(raw)
        let long = DiagnosticsLog.redact(String(repeating: "x", count: 500))
        return !out.contains("anna") && !out.contains("/Users") && !out.contains("example.com") && !out.contains("abcdef1234567890") && !out.contains("abc.def-123456")
            && !out.contains("short99") && !out.contains("geheim") && !out.contains("ghp_12345678")
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
    // A failed Pi tool (not Pippa's MCP server, which logs itself): its kind reaches the log, never its text.
    check("Log: a failed Pi tool's kind is told apart, and named without Pi's MCP prefix") {
        let cases: [(String, PiToolFailure)] = [("Tool web_fetch_content not found", .notFound),
                                               ("Validation failed for tool read", .invalidArguments),
                                               ("Not done: the person said no.", .blocked),
                                               ("Not read: blocked", .blocked),
                                               ("Tool execution was blocked", .blocked),
                                               ("boom", .other)]
        let fields = PiToolFailure.fields(tool: "web_fetch_content", isError: true, result: cases[0].0)
        let long = PiToolFailure.fields(tool: String(repeating: "a", count: 80), isError: true, result: "boom")?["name"] ?? ""
        return cases.allSatisfy { PiToolFailure.classify($0.0) == $0.1 }
            && fields == ["name": "web_fetch_content", "fehler": "true", "art": "not_found"]
            && PiToolFailure.bareName("mcp__pippa__read_document") == "read_document"
            && long.count == 60
    }
    check("Log: a failed Pi tool leaves a pi-werkzeug line; Pippa's MCP tools and successes leave none") {
        let log = DiagnosticsLog.shared
        let before = (try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? ""
        for (tool, isError, result) in [("web_fetch_content", true, "Tool web_fetch_content not found"),
                                        ("mcp__pippa__read_document", true, "Not read: blocked"),
                                        ("read", false, "")] {
            if let fields = PiToolFailure.fields(tool: tool, isError: isError, result: result) { log.event("pi-werkzeug", fields) }
        }
        log.flush()
        let added = ((try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? "").dropFirst(before.count)
        return added.contains("pi-werkzeug art=not_found fehler=true name=web_fetch_content") && !added.contains("not found")
    }
    check("Online AI failures: every class has a clean sentence, and a raw error with a key and an address logs its class only") {
        let raw = #"401 {"error":{"message":"Incorrect API key provided: sk-proj-abcdef1234567890XYZ for anna@example.com","type":"invalid_request_error","stack":"at /Users/anna/app.js:12"}}"#
        let texts = ModelFailureClass.allCases.compactMap { ModelFailure(failureClass: $0).onlineText }
        guard texts.count == ModelFailureClass.allCases.count - 3, offender(texts) == nil,
              ModelFailure(failureClass: .unknown).onlineText == UserMessage.generic else { return false }
        let failure = PiProviderClient.classify(errorText: raw)
        let log = DiagnosticsLog(directory: dir("diagnostics-model-failure"))
        failure.record(online: true, to: log)
        ModelFailure(failureClass: .unknown).record(online: false, to: log)
        log.flush()
        let lines = ((try? String(contentsOf: log.fileURL, encoding: .utf8)) ?? "").split(separator: "\n")
        let leaks = ["sk-proj", "abcdef", "anna", "example.com", "Users", "Incorrect", "stack", "{"]
        return failure == ModelFailure(failureClass: .authentication, httpStatus: 401) && lines.count == 2
            && lines[0].hasSuffix(" ki-fehler klasse=authentication online=true status=401")
            && lines[1].hasSuffix(" ki-fehler klasse=unknown online=false")
            && !leaks.contains { word in lines.contains { $0.contains(word) } }
    }
    check("Log: version and build are never empty") { !AppVersion.label.isEmpty && !AppVersion.build.isEmpty }
}
