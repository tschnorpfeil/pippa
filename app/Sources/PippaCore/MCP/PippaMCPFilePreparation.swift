import CryptoKit
import Foundation
import PDFKit

/// Native evidence for a chat result. The model cannot supply paths for this card.
public struct PreparedFilesCard: Codable, Sendable, Equatable {
    public let jobID: UUID
    public let files: [URL]
    public let pageCount: Int
    public let totalBytes: Int64
    public let sizeLimitBytes: Int64?
    public let withinLimit: Bool?
    public let note: String
    public init(jobID: UUID, files: [URL], pageCount: Int, totalBytes: Int64, sizeLimitBytes: Int64?, withinLimit: Bool?, note: String) {
        self.jobID = jobID; self.files = files; self.pageCount = pageCount; self.totalBytes = totalBytes
        self.sizeLimitBytes = sizeLimitBytes; self.withinLimit = withinLimit; self.note = note
    }
}

/// Pi chooses the task and arguments. This adapter invokes the same bounded local conversion and journal as the tray.
public struct PippaMCPFilePreparation: Sendable {
    public typealias Preparation = @Sendable ([FilePreparationSource], FilePreparationPlan) async throws -> ToolOutput
    public static let name = "prepare_files"
    private let host: PippaMCPHost
    private let turn: PippaMCPTurn?
    private let scope: PippaMCPWriteScope
    private let prepare: Preparation

    private struct Execution: Sendable {
        var result: PippaMCPToolResult
        var run: DurableJobRun? = nil
        var artifacts: [DurableJobArtifact] = []
        var undoReceipt: JobReceipt? = nil
    }

    public init(host: PippaMCPHost, turn: PippaMCPTurn?, scope: PippaMCPWriteScope,
                prepare: @escaping Preparation = { try await FilePreparation.run(sources: $0, plan: $1) }) {
        self.host = host; self.turn = turn; self.scope = scope; self.prepare = prepare
    }

    public static func toolList() -> [[String: Any]] {
        [["name": name, "title": "Prepare files",
          "description": "Ordered PDFs/photos to verified PDF; originals kept; no send/upload. size_limit_mb=goal.",
          "inputSchema": ["type": "object", "additionalProperties": false, "required": ["paths"], "properties": [
            "paths": ["type": "array", "items": ["type": "string"], "minItems": 1, "maxItems": 50],
            "quality": ["enum": ["original", "balanced", "compact"]],
            "size_limit_mb": ["enum": [5, 10, 20]],
          ]],
          "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false]]]
    }

    /// Native permission repairs travel outside model-visible JSON, including when no output card exists.
    public static func readNote(for result: PippaMCPToolResult, turnID: UUID?) -> PippaMCPReadNote {
        let done = !result.isError && result.receipt?.outcome == "done"
        var note = PippaMCPReadNote(tool: name, read: done,
            line: done ? L("Ready to send", table: "FilePreparation") : L("Files not prepared", table: "FilePreparation"),
            card: done ? result.card : nil, permissionRepair: result.permissionRepair)
        note.turnID = turnID
        return note
    }

    private struct Request: Codable, Sendable {
        var paths: [String]
        let plan: FilePreparationPlan
        init(_ raw: [String: Any]) throws {
            guard Set(raw.keys).isSubset(of: ["paths", "quality", "size_limit_mb"]),
                  let paths = raw["paths"] as? [String], (1...50).contains(paths.count),
                  paths.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.contains("\0") && !$0.contains(where: \.isNewline) })
            else { throw DurableJobError.invalidRequest }
            let quality: FilePreparationPlan.Quality
            if let rawQuality = raw["quality"] {
                guard let value = rawQuality as? String, let parsed = FilePreparationPlan.Quality(rawValue: value) else { throw DurableJobError.invalidRequest }
                quality = parsed
            } else { quality = .original }
            var goal: FilePreparationPlan.SizeGoal?
            if let rawGoal = raw["size_limit_mb"] {
                guard let number = rawGoal as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      [5.0, 10.0, 20.0].contains(number.doubleValue),
                      let parsed = FilePreparationPlan.SizeGoal(rawValue: number.int64Value * 1_000_000) else { throw DurableJobError.invalidRequest }
                goal = parsed
            }
            self.paths = paths
            self.plan = .init(quality: quality, sizeGoal: goal)
        }
    }

    public func call(_ raw: [String: Any]) async -> PippaMCPToolResult {
        let lease = scope.lease(action: "create")
        var result: PippaMCPToolResult
        do {
            try lease.check()
            guard let turn, scope.turnID == turn.id, host.turns.active === turn else { throw CancellationError() }
            var request = try Request(raw)
            request.paths = request.paths.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
            let normalized = request
            let worker = Task.detached(priority: .userInitiated) { await execute(normalized, turn: turn, lease: lease) }
            // Ending a Pi turn cancels its native scope even if the HTTP task itself stays alive.
            let monitor = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(30)); try lease.check() }
                    catch { worker.cancel(); return }
                }
            }
            let execution = await withTaskCancellationHandler { await worker.value } onCancel: { lease.cancel(); worker.cancel() }
            monitor.cancel()
            result = execution.result
            if result.receipt?.outcome == "done" {
                do { try lease.check() }
                catch {
                    var retirement: DurableJobRecord?
                    if let run = execution.run, let store = host.filePreparationStore {
                        retirement = try? await store.cancel(run: run)
                        if retirement != nil {
                            let discarded = (try? await store.discardUnpublishedArtifacts(execution.artifacts, run: run)) != nil
                            if discarded, let receipt = execution.undoReceipt { _ = try? await host.reminderJournal?.undo(jobID: receipt.id) }
                        }
                    }
                    let retired = retirement != nil
                    if let retirement {
                        lease.confirmNoMutation()
                        lease.bindOperationID(retirement.id, nativeRevision: retirement.revision)
                    }
                    result = Self.failure(retired ? "not_dispatched" : "unclear", "This request stopped. Review its saved status before continuing.",
                                          reason: "stopped", outcome: retired ? "cancelled" : "unclear", dispatched: !retired)
                }
            }
        } catch is PippaMCPWritePolicyDenied {
            result = Self.failure("not_dispatched", "This request permits text drafts only. Do not retry through another tool.", reason: "draftOnly")
        } catch is CancellationError {
            result = Self.failure("not_dispatched", "This request stopped. Do not continue it through another tool.", reason: "stopped", outcome: "cancelled")
        } catch {
            result = Self.failure("invalid_arguments", "Use paths (1–50 absolute PDF/photo paths), optional quality original/balanced/compact and size_limit_mb 5, 10 or 20. No other arguments are accepted.", reason: "invalid")
        }
        result.receipt = lease.finish(result.receipt)
        return result
    }

    private func execute(_ request: Request, turn: PippaMCPTurn, lease: PippaMCPWriteLease) async -> Execution {
        guard let store = host.filePreparationStore, let journal = host.reminderJournal else {
            return Execution(result: Self.failure("unavailable", "The local job journal is unavailable. No file was prepared.", reason: "journalUnavailable"))
        }
        var run: DurableJobRun?
        var cacheFiles: [URL] = []
        var artifacts: [DurableJobArtifact] = []
        var undoReceipt: JobReceipt?
        var capturingInput: URL?
        do {
            try lease.check()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let key = "pi-prepare-files:" + turn.id.uuidString + ":" + SHA256.hash(data: try encoder.encode(request)).map { String(format: "%02x", $0) }.joined()
            if let existing = try await store.record(requestKey: key) {
                lease.bindOperationID(existing.id, nativeRevision: existing.revision)
                return Execution(result: try await existingResult(existing, store: store, plan: request.plan, lease: lease))
            }
            let urls = request.paths.map { URL(fileURLWithPath: $0) }
            guard FilePreparation.accepts(urls) else { throw DurableJobError.invalidRequest }
            var sources: [FilePreparationSource] = [], inputs: [DurableJobInput] = [], items: [TrayItem] = []
            for url in urls {
                try lease.check()
                capturingInput = url
                sources.append(try FilePreparationSource.capture(url))
                let input = try DurableJobInput.capture(url: url)
                inputs.append(input)
                items.append(TrayItem(role: .given, url: url, bookmark: input.bookmark))
            }
            capturingInput = nil
            let draft = FilePreparationDraft(items: items, sources: sources, grants: inputs, plan: request.plan)
            let record: DurableJobRecord
            do {
                record = try await store.create(kind: .filePreparation, requestKey: key,
                    conversationID: lease.origin?.conversationID, title: L("Ready to send", table: "FilePreparation"),
                    inputs: inputs, payload: encoder.encode(draft))
            } catch DurableJobError.requestConflict {
                guard let existing = try await store.record(requestKey: key) else { throw DurableJobError.unknownJob }
                lease.bindOperationID(existing.id, nativeRevision: existing.revision)
                return Execution(result: try await existingResult(existing, store: store, plan: request.plan, lease: lease))
            }
            lease.bindOperationID(record.id, nativeRevision: record.revision)
            let attempt = try await store.start(id: record.id, expectedRevision: record.revision)
            run = attempt
            lease.bindOperationID(record.id, nativeRevision: attempt.revision)
            try lease.beginDispatch()
            let output = try await prepare(sources, request.plan)
            cacheFiles = output.files
            try lease.check()
            for file in output.files {
                artifacts.append(try await store.retainArtifact(from: file, run: attempt))
                try lease.check()
            }
            guard !artifacts.isEmpty else { throw FilePreparationFailure.verification }
            undoReceipt = try await journal.recordResult(artifacts.map(\.url), summary: output.summary, detail: output.detailSentence ?? "")
            try lease.check()
            let resultItems = artifacts.map { TrayItem(role: .result, url: $0.url, receipt: undoReceipt?.id,
                sources: items.map(\.id), tool: .makeOnePDF, note: output.detailSentence) }
            let saved = FilePreparationSavedResult(items: resultItems, sources: items)
            let completed = try await store.finish(run: attempt, state: .completed, resultData: encoder.encode(saved), artifacts: artifacts)
            try lease.check()
            let result = try await completedResult(completed, store: store, plan: request.plan, lease: lease)
            Self.removeCacheFiles(cacheFiles)
            return Execution(result: result, run: attempt, artifacts: artifacts, undoReceipt: undoReceipt)
        } catch {
            let stopped = error is CancellationError || scope.snapshot.cancelled || Task.isCancelled
            var retirement: DurableJobRecord?
            var discarded = false
            if let run {
                if stopped { retirement = try? await store.cancel(run: run) }
                else { retirement = try? await store.finish(run: run, state: .needsAttention, issue: "file-preparation-needs-review") }
                if retirement != nil { discarded = (try? await store.discardUnpublishedArtifacts(artifacts, run: run)) != nil }
            }
            if discarded, let undoReceipt { _ = try? await journal.undo(jobID: undoReceipt.id) }
            Self.removeCacheFiles(cacheFiles)
            let retired = run == nil || retirement != nil
            if retired { lease.confirmNoMutation() }
            if let retirement { lease.bindOperationID(retirement.id, nativeRevision: retirement.revision) }
            let reason = (error as? LocalizedError)?.errorDescription
            if stopped {
                return Execution(result: Self.failure(retired ? "not_dispatched" : "unclear", retired ? "Stopped. No prepared result was published." : "Stopped while saving the result. Review the saved request before retrying.",
                                    reason: "stopped", outcome: retired ? "cancelled" : "unclear", dispatched: !retired))
            }
            if PermissionRepairTarget.isFileAccessDenied(error as NSError) {
                var failure = Self.failure("denied", "Pippa cannot read one of these files. Review file access; do not try another way.", reason: "denied")
                if let deniedInput = capturingInput ?? (request.paths.count == 1 ? URL(fileURLWithPath: request.paths[0]) : nil) {
                    failure.permissionRepair = PermissionRepairTarget.forDeniedFile(at: deniedInput)
                }
                return Execution(result: failure)
            }
            return Execution(result: Self.failure(retired ? "failed" : "unclear", reason ?? "The files could not be prepared. Originals are unchanged. Review the saved request before trying again.",
                                reason: "preparationFailed", outcome: retired ? "failed" : "unclear", dispatched: !retired))
        }
    }

    private func existingResult(_ record: DurableJobRecord, store: DurableJobStore, plan: FilePreparationPlan,
                                lease: PippaMCPWriteLease) async throws -> PippaMCPToolResult {
        try lease.check()
        if record.state == .completed { return try await completedResult(record, store: store, plan: plan, lease: lease) }
        var result = Self.failure("not_dispatched", "This exact request already exists. Review its saved status; do not repeat the conversion automatically.", reason: "existingRequest", outcome: "blocked")
        result.receipt?.operationID = record.id; result.receipt?.nativeRevision = record.revision
        return result
    }

    private func completedResult(_ record: DurableJobRecord, store: DurableJobStore, plan: FilePreparationPlan,
                                 lease: PippaMCPWriteLease) async throws -> PippaMCPToolResult {
        let artifacts = try await store.verifiedArtifacts(id: record.id)
        let current = try await store.record(id: record.id)
        guard current.state == .completed, current.revision == record.revision else { throw DurableJobError.staleRevision }
        guard artifacts.count == 1, let data = record.resultData,
              let saved = try? JSONDecoder().decode(FilePreparationSavedResult.self, from: data),
              saved.items.map(\.url) == artifacts.map(\.url), let document = PDFDocument(url: artifacts[0].url),
              !document.isLocked, document.pageCount > 0 else { throw FilePreparationFailure.verification }
        let bytes = artifacts.reduce(Int64(0)) { $0 + $1.identity.size }
        let limit = plan.sizeGoal?.rawValue
        let note = saved.items.first?.note ?? ""
        let card = PreparedFilesCard(jobID: record.id, files: artifacts.map(\.url), pageCount: document.pageCount,
            totalBytes: bytes, sizeLimitBytes: limit, withinLimit: limit.map { bytes <= $0 }, note: note)
        try lease.check()
        var receipt = PippaMCPWriteReceipt(action: "create", outcome: "done", name: artifacts[0].url.lastPathComponent, reason: "preparedFiles")
        receipt.operationID = record.id; receipt.nativeRevision = record.revision
        var facts: [String: Any] = ["job_id": record.id.uuidString, "paths": artifacts.map { $0.url.path }, "bytes": bytes, "pages": document.pageCount, "note": note]
        if let limit { facts["size_limit_bytes"] = limit; facts["within_limit"] = bytes <= limit }
        return .init(text: PippaMCPTools.json(["done": true, "dispatched": true, "data": facts,
            "next": "The verified PDF is saved locally and shown as a file card. Originals are unchanged. It has not been sent or uploaded. Report the actual size; if within_limit is false, say the requested size goal was not reached."]),
                     isError: false, receipt: receipt, card: .preparedFiles(card))
    }

    private static func removeCacheFiles(_ files: [URL]) {
        let root = ResultsFolder.directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        for file in files where file.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func failure(_ status: String, _ why: String, reason: String, outcome: String = "failed", dispatched: Bool = false) -> PippaMCPToolResult {
        var facts: [String: Any] = ["done": false, "status": status, "dispatched": dispatched, "error": why]
        if outcome == "unclear" { facts["state"] = "unclear" }
        return PippaMCPToolResult(text: PippaMCPTools.json(facts),
                           isError: true, receipt: .init(action: "create", outcome: outcome, name: L("Ready to send", table: "FilePreparation"), reason: reason))
    }
}
