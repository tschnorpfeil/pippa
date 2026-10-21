import Foundation
import PDFKit
import PippaCore
import SQLite3

private actor PreparationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

func runMCPFilePreparationChecks() async {
    let folder = dir("mcp-file-preparation")
    let priorResults = getenv("PIPPA_RESULTS_DIR").map { String(cString: $0) }
    setenv("PIPPA_RESULTS_DIR", folder.appendingPathComponent("results").path, 1)
    defer { if let priorResults { setenv("PIPPA_RESULTS_DIR", priorResults, 1) } else { unsetenv("PIPPA_RESULTS_DIR") } }
    let first = dir("mcp-file-preparation/first").resolvingSymlinksInPath().appendingPathComponent("Source.pdf")
    let second = dir("mcp-file-preparation/second").resolvingSymlinksInPath().appendingPathComponent("Source.pdf")
    makePDF(["First synthetic page"], at: first); makePDF(["Second synthetic page"], at: second)
    let originalBytes = try? [first, second].map { try Data(contentsOf: $0) }

    func setup(_ name: String, allowsWrites: Bool = true) throws -> (PippaMCPHost, PippaMCPTurn, DurableJobStore) {
        let directory = dir("mcp-file-preparation/" + name)
        let store = try DurableJobStore(baseDirectory: directory)
        var host = PippaMCPHost.demo()
        host.turns = PippaMCPTurns(); host.filePreparationStore = store
        host.reminderJournal = try Executor(baseDirectory: directory)
        let turn = PippaMCPTurn(origin: .init(conversationID: UUID(), requestID: UUID()), allowsNativeWrites: allowsWrites)
        host.turns.begin(turn)
        return (host, turn, store)
    }
    func facts(_ result: PippaMCPToolResult) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any] ?? [:]
    }
    func call(_ tools: PippaMCPTools, paths: [String]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "prepare_files", "arguments": ["paths": paths]]])
        guard let data = await tools.handle(body), let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = reply["result"] as? [String: Any] else { return [:] }
        return result
    }

    check("MCP prepare_files: compact schema offers bounded ordered inputs, no destination, send or password") {
        let tools = PippaMCPFilePreparation.toolList()
        let schema = tools.first?["inputSchema"] as? [String: Any] ?? [:]
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let bytes = try JSONSerialization.data(withJSONObject: tools).count
        return properties.keys.sorted() == ["paths", "quality", "size_limit_mb"]
            && schema["additionalProperties"] as? Bool == false && bytes < 900
            && PippaMCPTools.toolNames.filter { $0 == "prepare_files" }.count == 1
    }

    await checkAsync("MCP prepare_files: invalid arguments, inactive scope and draft-only requests create no jobs") {
        let (host, turn, store) = try setup("invalid")
        let adapter = PippaMCPFilePreparation(host: host, turn: turn, scope: turn.writes)
        let invalid: [[String: Any]] = [[:], ["paths": []], ["paths": [first.path], "output": "/tmp/no.pdf"],
            ["paths": [first.path], "quality": "tiny"], ["paths": [first.path], "quality": NSNull()],
            ["paths": [first.path], "size_limit_mb": true], ["paths": [first.path], "size_limit_mb": 5.1],
            ["paths": [first.path], "size_limit_mb": "5"], ["paths": Array(repeating: first.path, count: 51)],
            ["paths": ["relative.pdf"]], ["paths": [1]], ["paths": ["/tmp/no\n.pdf"]]]
        for request in invalid {
            let result = await adapter.call(request)
            guard result.isError, facts(result)["status"] as? String == "invalid_arguments", result.card == nil else { return false }
        }
        let (_, draft, _) = try setup("draft", allowsWrites: false)
        let denied = await PippaMCPFilePreparation(host: host, turn: draft, scope: draft.writes).call(["paths": [first.path]])
        host.turns.end(turn)
        let inactive = await adapter.call(["paths": [first.path]])
        let absent = await PippaMCPFilePreparation(host: host, turn: nil, scope: .init()).call(["paths": [first.path]])
        let records = try await store.records()
        return denied.receipt?.reason == "draftOnly" && inactive.receipt?.outcome == "cancelled"
            && absent.receipt?.outcome == "cancelled" && records.isEmpty
    }

    await checkAsync("MCP prepare_files: Pi dispatch uses the shared converter, durable tray schema and native card") {
        var (host, turn, store) = try setup("success")
        let notes = LockedBox<[PippaMCPReadNote]>([]), receipts = LockedBox<[PippaMCPWriteReceipt]>([])
        host.onRead = { note in notes.mutate { $0.append(note) } }
        host.onWrite = { receipt in receipts.mutate { $0.append(receipt) } }
        let tools = PippaMCPTools(host: host)
        let response = try await call(tools, paths: [second.path, first.path])
        let duplicate = try await call(tools, paths: [second.path, first.path])
        let records = try await store.records()
        guard response["isError"] as? Bool == false, duplicate["isError"] as? Bool == false,
              records.count == 1, let record = records.first, record.state == .completed, let saved = record.resultData,
              let output = record.artifacts.first?.url, let document = PDFDocument(url: output),
              case .preparedFiles(let card)? = notes.value.first?.card else { return false }
        let draft = try JSONDecoder().decode(FilePreparationDraft.self, from: record.payload)
        let result = try JSONDecoder().decode(FilePreparationSavedResult.self, from: saved)
        let relaunched = try DurableJobStore(baseDirectory: store.baseDirectory)
        let readback = try await relaunched.verifiedArtifacts(id: record.id)
        return document.pageCount == 2 && document.page(at: 0)?.string?.contains("Second synthetic page") == true
            && document.page(at: 1)?.string?.contains("First synthetic page") == true
            && draft.sources.map(\.url) == [second, first] && result.items.first?.receipt != nil
            && result.sources.map(\.id) == draft.items.map(\.id) && result.items.first?.url == output
            && card.files == [output] && card.pageCount == 2 && card.totalBytes == ToolFixtures.size(output)
            && notes.value.allSatisfy { $0.turnID == turn.id && $0.read }
            && receipts.value.allSatisfy { $0.outcome == "done" && $0.operationID == record.id && $0.turnID == turn.id }
            && record.conversationID == turn.writes.origin?.conversationID && readback.count == 1
            && (try? [first, second].map { try Data(contentsOf: $0) }) == originalBytes
    }

    await checkAsync("MCP prepare_files: normalization deduplicates exact requests while input order remains meaningful") {
        let (host, turn, store) = try setup("dedup")
        let adapter = PippaMCPFilePreparation(host: host, turn: turn, scope: turn.writes)
        let a = await adapter.call(["paths": [first.path, second.path]])
        let b = await adapter.call(["paths": [first.deletingLastPathComponent().path + "/./Source.pdf", second.path], "quality": "original"])
        let c = await adapter.call(["paths": [second.path, first.path]])
        let records = try await store.records()
        return !a.isError && !b.isError && !c.isError && a.receipt?.operationID == b.receipt?.operationID
            && c.receipt?.operationID != a.receipt?.operationID && records.count == 2
    }

    await checkAsync("MCP prepare_files: failed locked PDF saves a resumable draft and never a password or success") {
        let (host, turn, store) = try setup("locked")
        let locked = folder.appendingPathComponent("Locked.pdf")
        ToolFixtures.lockedPDF(["Synthetic locked input"], password: "never-persist-this", at: locked)
        let result = await PippaMCPFilePreparation(host: host, turn: turn, scope: turn.writes).call(["paths": [locked.path]])
        let records = try await store.records()
        guard let record = records.first else { return false }
        let draft = try JSONDecoder().decode(FilePreparationDraft.self, from: record.payload)
        return result.isError && result.card == nil && facts(result)["done"] as? Bool == false
            && record.state == .needsAttention && record.artifacts.isEmpty && record.resultData == nil
            && draft.sources.count == 1 && !String(decoding: record.payload, as: UTF8.self).contains("never-persist-this")
    }

    await checkAsync("MCP prepare_files: stopped late conversion cannot publish into a newer Pi turn") {
        let (host, turn, store) = try setup("stopped")
        let gate = PreparationGate()
        let output = try ResultsFolder.fresh().appendingPathComponent("Late.pdf")
        try Data(contentsOf: first).write(to: output)
        let adapter = PippaMCPFilePreparation(host: host, turn: turn, scope: turn.writes, prepare: { sources, _ in
            await gate.wait()
            return ToolOutput(files: [output], consumedInputs: sources.map(\.url), skipped: [], summary: "Synthetic result")
        })
        let task = Task { await adapter.call(["paths": [first.path]]) }
        for _ in 0..<200 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(10)) }
        guard await gate.entered else { task.cancel(); return false }
        let newer = PippaMCPTurn(); host.turns.begin(newer)
        await gate.release()
        let result = await task.value
        let records = try await store.records()
        return result.isError && result.card == nil && result.receipt?.outcome == "cancelled"
            && result.receipt?.turnID == turn.id && records.first?.state == .cancelled
            && !FileManager.default.fileExists(atPath: output.path) && newer.writes.snapshot.receipts.isEmpty
    }

    await checkAsync("MCP prepare_files: a stopped callback cannot cancel or publish over a newer durable retry") {
        let (host, turn, store) = try setup("retry-fence")
        let gate = PreparationGate()
        let output = try ResultsFolder.fresh().appendingPathComponent("Old.pdf")
        try Data(contentsOf: first).write(to: output)
        let adapter = PippaMCPFilePreparation(host: host, turn: turn, scope: turn.writes, prepare: { sources, _ in
            await gate.wait()
            return ToolOutput(files: [output], consumedInputs: sources.map(\.url), skipped: [], summary: "Synthetic old result")
        })
        let task = Task { await adapter.call(["paths": [first.path]]) }
        for _ in 0..<200 { if await gate.entered { break }; try await Task.sleep(for: .milliseconds(10)) }
        guard await gate.entered, let old = try await store.records().first else { task.cancel(); return false }
        let cancelled = try await store.cancel(id: old.id, expectedRevision: old.revision)
        let retry = try await store.retry(id: old.id, expectedRevision: cancelled.revision)
        let newRun = try await store.start(id: old.id, expectedRevision: retry.revision)
        turn.cancelWrites(); await gate.release()
        let result = await task.value
        let current = try await store.record(id: old.id)
        return result.isError && result.card == nil && current.state == .running
            && current.runToken == newRun.token && current.revision == newRun.revision
    }

    await checkAsync("MCP prepare_files: actual bytes expose an unmet size goal and tampered durable output is not reused") {
        let (host, turn, store) = try setup("honest-size")
        let output = try ResultsFolder.fresh().appendingPathComponent("Large.pdf")
        var bytes = try Data(contentsOf: first); bytes.append(Data(repeating: 32, count: 5_000_001))
        try bytes.write(to: output)
        let adapter = PippaMCPFilePreparation(host: host, turn: turn, scope: turn.writes, prepare: { sources, _ in
            ToolOutput(files: [output], consumedInputs: sources.map(\.url), skipped: [], summary: "Synthetic large result")
        })
        let request: [String: Any] = ["paths": [first.path], "size_limit_mb": 5]
        let result = await adapter.call(request)
        guard case .preparedFiles(let card)? = result.card, let file = card.files.first else { return false }
        let data = facts(result)["data"] as? [String: Any] ?? [:]
        try Data("Edited by the person".utf8).write(to: file)
        let repeatResult = await adapter.call(request)
        let records = try await store.records()
        let editedBytes = try Data(contentsOf: file)
        return !result.isError && card.withinLimit == false && card.totalBytes == bytes.count
            && data["within_limit"] as? Bool == false && repeatResult.isError && repeatResult.card == nil
            && records.count == 1 && editedBytes == Data("Edited by the person".utf8)
    }

    await checkAsync("MCP prepare_files: persistence failure fails closed before conversion") {
        let (host, turn, store) = try setup("write-failure")
        var database: OpaquePointer?
        guard sqlite3_open(store.databaseURL.path, &database) == SQLITE_OK else { return false }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "CREATE TRIGGER block_preparation BEFORE INSERT ON durable_jobs BEGIN SELECT RAISE(FAIL,'synthetic write failure'); END", nil, nil, nil) == SQLITE_OK else { return false }
        let invoked = LockedBox(false)
        let adapter = PippaMCPFilePreparation(host: host, turn: turn, scope: turn.writes, prepare: { _, _ in
            invoked.mutate { $0 = true }; throw FilePreparationFailure.verification
        })
        let result = await adapter.call(["paths": [first.path]])
        let records = try await store.records()
        return result.isError && result.card == nil && !invoked.value && records.isEmpty
    }

    await checkAsync("MCP prepare_files: native denial repair survives the failure-note boundary without a success card") {
        let (host, turn, _) = try setup("denied")
        let adapter = PippaMCPFilePreparation(host: host, turn: turn, scope: turn.writes, prepare: { _, _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        })
        var result = await adapter.call(["paths": [first.path]])
        // A synthetic native repair exercises delivery; no real protected folder or macOS prompt is touched.
        result.permissionRepair = .filesAndFolders
        let note = PippaMCPFilePreparation.readNote(for: result, turnID: turn.id)
        return result.isError && facts(result)["status"] as? String == "denied" && facts(result)["dispatched"] as? Bool == false
            && !note.read && note.card == nil && note.permissionRepair == .filesAndFolders && note.turnID == turn.id
    }
}
