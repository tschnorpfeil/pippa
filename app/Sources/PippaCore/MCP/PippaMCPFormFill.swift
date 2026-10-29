import Foundation
import PDFKit

/// A filled copy of a PDF form in Pippa's results folder, made by `fill_pdf`. Native evidence: the model cannot supply
/// the path for this card.
public struct FilledFormCard: Codable, Sendable, Equatable {
    public let file: URL
    /// The original's file name; the original itself stays unchanged.
    public let source: String
    public let pageCount: Int
    public let filled: Int
    /// Labels of blanks on the filled pages that got no answer.
    public let stillEmpty: [String]
    public init(file: URL, source: String, pageCount: Int, filled: Int, stillEmpty: [String]) {
        self.file = file; self.source = source; self.pageCount = pageCount; self.filled = filled; self.stillEmpty = stillEmpty
    }
}

/// `fill_pdf`: writes the answers Pi collected into a copy of a PDF form (PDFForm); the original stays unchanged and
/// nothing is sent. Answers go to the ids read_document lists, never to places the model names. Not registered with
/// the MCP server yet: read_document does not list blanks until this has been tried on real forms.
public struct PippaMCPFormFill: Sendable {
    public static let name = "fill_pdf"
    static let maxAnswers = 150
    static let maxFileBytes = 100_000_000
    let host: PippaMCPHost
    let turn: PippaMCPTurn?
    let scope: PippaMCPWriteScope

    public init(host: PippaMCPHost, turn: PippaMCPTurn?, scope: PippaMCPWriteScope) { self.host = host; self.turn = turn; self.scope = scope }

    public static func toolList() -> [[String: Any]] {
        [["name": name, "title": "PDF ausfüllen",
          "description": "Filled copy of a PDF form; original kept. answers={id from read_document: text or yes}.",
          "inputSchema": ["type": "object", "additionalProperties": false, "required": ["path", "answers"], "properties": [
              "path": ["type": "string"], "answers": ["type": "object", "additionalProperties": ["type": "string"]]]],
          "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false, "title": "PDF ausfüllen"]]]
    }

    /// Like PippaMCPFilePreparation.readNote: the card only for a done result; permission repairs travel outside the JSON.
    public static func readNote(for result: PippaMCPToolResult, turnID: UUID?) -> PippaMCPReadNote {
        let done = !result.isError && result.receipt?.outcome == "done"
        var note = PippaMCPReadNote(tool: name, read: done,
                                    line: done ? L("Form filled in", table: "MCP") : L("Form not filled in", table: "MCP"),
                                    card: done ? result.card : nil, permissionRepair: result.permissionRepair)
        note.turnID = turnID
        return note
    }

    public func call(_ raw: [String: Any]) async -> PippaMCPToolResult {
        let started = ContinuousClock.now
        let lease = scope.lease(action: "create")
        let output = Self.outputName(raw["path"] as? String)
        var result: PippaMCPToolResult
        do {
            try lease.check()
            guard let turn, scope.turnID == turn.id, host.turns.active === turn else { throw CancellationError() }
            result = await fill(raw, lease: lease)
        } catch is PippaMCPWritePolicyDenied {
            result = Self.draftOnly(output)
        } catch {
            result = Self.stopped(output)
        }
        result.receipt = lease.finish(result.receipt)
        let elapsed = (ContinuousClock.now - started).components
        var fields = ["name": Self.name, "fehler": String(result.isError),
                      "ms": String(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)]
        // Why it failed (status only, never the path or answers).
        if result.isError, let status = (try? JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])?["status"] as? String {
            fields["status"] = status
        }
        DiagnosticsLog.shared.event("mcp-werkzeug", fields)
        return result
    }

    private struct Request: Sendable {
        var path: String
        var answers: [String: String]
    }

    /// Only the declared arguments with their declared types.
    private static func request(_ raw: [String: Any]) -> Request? {
        guard Set(raw.keys).isSubset(of: ["path", "answers"]),
              let path = (raw["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
              path.utf8.count <= 4096, !path.contains("\0"),
              let answers = raw["answers"] as? [String: String], answers.count <= maxAnswers,
              answers.keys.allSatisfy({ $0.count <= 120 }) else { return nil }
        return Request(path: path, answers: answers)
    }

    private func fill(_ raw: [String: Any], lease: PippaMCPWriteLease) async -> PippaMCPToolResult {
        guard let request = Self.request(raw) else {
            return Self.failure("invalid_arguments", "Use path (the absolute .pdf path from the message) and answers {id from read_document: text, or \"yes\" for a box}, at most 150 answers. No other arguments are accepted.",
                                reason: "invalid", outcome: "blocked", name: Self.outputName(nil))
        }
        let path = PippaMCPChart.normalize(request.path)
        let name = Self.outputName(path)
        guard path.hasPrefix("/") else {
            return Self.failure("invalid_arguments", "Use the exact absolute path from the message.", reason: "invalid", outcome: "blocked", name: name)
        }
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension.lowercased() == "pdf" else {
            return Self.failure("invalid_arguments", "fill_pdf fills PDF forms only. Use the exact path of the .pdf file.", reason: "invalid", outcome: "blocked", name: name)
        }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as NSError where PermissionRepairTarget.isFileAccessDenied(error) {
            return Self.denied(url, name: name)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
            || error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return Self.failure("not_found", "There is no file at this path. Use the exact path from the message.", reason: "notFound", outcome: "blocked", name: name)
        } catch {
            return Self.failure("failed", "Pippa could not open this file just now. Nothing was filled in.", reason: "unreadable", outcome: "blocked", name: name)
        }
        if attributes[.type] as? FileAttributeType == .typeDirectory {
            return Self.failure("invalid_arguments", "This is a folder, not a PDF. Use the exact path of the .pdf file.", reason: "invalid", outcome: "blocked", name: name)
        }
        // Privacy settings (Downloads, Desktop, Documents) can deny reading while the file exists.
        do { try FileHandle(forReadingFrom: url).close() } catch let error as NSError where PermissionRepairTarget.isFileAccessDenied(error) {
            return Self.denied(url, name: name)
        } catch {}
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maxFileBytes else {
            return Self.failure("invalid_arguments", "This PDF is larger than 100 MB; Pippa does not fill it in.", reason: "invalid", outcome: "blocked", name: name)
        }

        let range = Self.pages(for: Array(request.answers.keys))
        guard let analysis = await Task.detached(priority: .userInitiated, operation: { PDFForm.analyze(url, pages: range) }).value else {
            return Self.failure("failed", "This PDF cannot be opened or is locked. Nothing was filled in.", reason: "unreadable", outcome: "blocked", name: name)
        }
        let plan: PDFForm.FillPlan
        switch PDFForm.plan(PDFForm.spreadLines(request.answers, blanks: analysis.blanks), analysis: analysis) {
        case .success(let value): plan = value
        case .failure(let problem):
            return Self.failure("invalid_arguments", Self.sentence(problem, file: url.lastPathComponent), reason: "invalid", outcome: "blocked", name: name)
        }

        let folder: URL
        do { folder = try ResultsFolder.fresh() } catch {
            return Self.failure("failed", "The filled copy could not be saved. The original is unchanged.", reason: "saveFailed", name: name)
        }
        let destination = folder.appendingPathComponent(name)
        func discard() {
            try? FileManager.default.removeItem(at: folder)
            lease.confirmNoMutation()
        }
        do { try lease.beginDispatch() } catch {
            discard()
            return error is PippaMCPWritePolicyDenied ? Self.draftOnly(name) : Self.stopped(name)
        }
        let count: Int
        do {
            count = try await Task.detached(priority: .userInitiated, operation: { try PDFForm.write(plan, source: url, to: destination) }).value
        } catch {
            discard()
            return Self.failure("failed", "The filled copy could not be saved. The original is unchanged.", reason: "saveFailed", name: name)
        }
        guard PDFDocument(url: destination)?.pageCount == analysis.pageCount else {
            discard()
            return Self.failure("failed", "The filled copy could not be checked, so it was removed. The original is unchanged.", reason: "saveFailed", name: name)
        }
        // Stopped while writing: the copy goes again, so nothing is left that the answer does not report.
        do { try lease.check() } catch {
            discard()
            return error is PippaMCPWritePolicyDenied ? Self.draftOnly(name) : Self.stopped(name)
        }
        return PippaMCPToolResult(text: PippaMCPTools.json(["done": true, "dispatched": true,
            "data": ["path": destination.path, "filled": plan.done, "still_empty": plan.stillEmpty],
            "next": "The filled copy is saved and shown as a card; the original is unchanged and nothing was sent. Say what is still empty. Answers are text boxes the person can move or edit in Preview; they must check and sign it themselves."]),
            isError: false, receipt: .init(action: "create", outcome: "done", name: destination.lastPathComponent, reason: "filledForm"),
            card: .filledForm(FilledFormCard(file: destination, source: url.lastPathComponent, pageCount: analysis.pageCount,
                                             filled: count, stillEmpty: plan.stillEmpty)))
    }

    /// The pages the answers name ("p3:…"); every page when a form field ("f:…") or an id of another shape is among them.
    static func pages(for ids: [String]) -> ClosedRange<Int> {
        var numbers: [Int] = []
        for raw in ids {
            let id = PDFForm.key(raw)
            guard id.hasPrefix("p"), let colon = id.firstIndex(of: ":"),
                  let number = Int(id[id.index(after: id.startIndex)..<colon]), number >= 1 else { return 1...Int.max }
            numbers.append(number)
        }
        guard let low = numbers.min(), let high = numbers.max() else { return 1...Int.max }
        return low...high
    }

    /// "Antrag.pdf" → "Antrag (ausgefüllt).pdf"; filling a filled copy again does not add the suffix twice.
    static func outputName(_ path: String?) -> String {
        var stem = path.map { URL(fileURLWithPath: PippaMCPChart.normalize($0)).deletingPathExtension().lastPathComponent } ?? ""
        let suffix = L("%@ (filled in)", table: "MCP", "")
        if !suffix.isEmpty, stem.hasSuffix(suffix) { stem = String(stem.dropLast(suffix.count)) }
        let name = Naming.sanitize(L("%@ (filled in)", table: "MCP", stem.isEmpty ? "PDF" : stem))
        return (name.isEmpty ? "PDF" : name) + ".pdf"
    }

    /// For the model, English like the other tool errors; lists the real ids so the call can be fixed without reading again.
    static func sentence(_ problem: PDFForm.FillProblem, file: String) -> String {
        switch problem {
        case .unknownIDs(let ids, let valid):
            let listed = valid.prefix(80).joined(separator: ", ") + (valid.count > 80 ? ", …" : "")
            return "Nothing saved: these ids are not blanks of \(file): \(ids.prefix(20).joined(separator: ", ")). "
                + (valid.isEmpty ? "Pippa found no blanks to fill in this PDF; tell the person." : "The blanks are: \(listed). Call fill_pdf again with these ids and all the answers.")
        case .wrongKind(let ids):
            return "Nothing saved: \(ids.joined(separator: ", ")) need the actual answer (a date, a name) or one of their options, not yes or no. Write the answer there or leave it out."
        case .signature(let ids):
            return "Nothing saved: \(ids.joined(separator: ", ")) are for a signature. Leave them out; the person signs the form themselves."
        case .nothingToFill:
            return "Nothing to fill in: every answer was empty, or no for a box. Leave out what you do not know."
        }
    }

    private static func denied(_ url: URL, name: String) -> PippaMCPToolResult {
        failure("denied", "Pippa is not allowed to open this file. Tell the person in one sentence; do not try other ways.",
                reason: "denied", outcome: "blocked", name: name, repair: PermissionRepairTarget.forDeniedFile(at: url))
    }

    private static func draftOnly(_ name: String) -> PippaMCPToolResult {
        failure("not_dispatched", "This request permits text drafts only. Do not retry through another tool.", reason: "draftOnly", outcome: "blocked", name: name)
    }

    private static func stopped(_ name: String) -> PippaMCPToolResult {
        failure("not_dispatched", "This request stopped. Do not continue it through another tool.", reason: "stopped", outcome: "cancelled", name: name)
    }

    /// Every status here is one the receipts read as "no effect" (PiActionReceipt.nativeNoEffect, NATIVE_NO_EFFECT).
    private static func failure(_ status: String, _ why: String, reason: String, outcome: String = "failed", name: String,
                                repair: PermissionRepairTarget? = nil) -> PippaMCPToolResult {
        PippaMCPToolResult(text: PippaMCPTools.json(["done": false, "status": status, "dispatched": false, "error": why]), isError: true,
                           receipt: .init(action: "create", outcome: outcome, name: name, reason: reason), permissionRepair: repair)
    }
}
