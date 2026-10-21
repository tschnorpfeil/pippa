import Foundation
import PippaCore

/// Native cancellation checks use invented integrations and the real Apple Events serial queue, never real apps.
func runNativeWriteChecks() async {
    func request(_ name: String = "reminder_add") -> Data {
        let args = name == "calendar_add" ? ["title": "Test appointment", "date": "tomorrow"] : ["title": "Test reminder"]
        return try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                           "params": ["name": name, "arguments": args]])
    }
    func payload(_ data: Data?) -> [String: Any] {
        let reply = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let result = reply?["result"] as? [String: Any]
        let text = ((result?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? "{}"
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
    }
    func host(_ demo: DemoIntegrations, turns: PippaMCPTurns) -> PippaMCPHost {
        var host = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(granted: true), hostData: DemoHostData(integrations: demo))
        host.writer = demo; host.turns = turns; host.requireActiveWriteTurn = true
        return host
    }
    func reached(_ gate: NativeWriteGate) async -> Bool {
        await firstAnswer(within: 2, fallback: false) { await gate.wait(); return true }
    }

    await checkAsync("Native writes: Stop during permission explanation cancels original request even after a new turn begins") {
        let demo = DemoIntegrations(), turns = PippaMCPTurns()
        let old = PippaMCPTurn(), next = PippaMCPTurn()
        turns.begin(old)
        let entered = NativeWriteGate(), release = NativeWriteGate(), observed = NativeReceiptBox()
        old.writes.observeReceipts { observed.append($0) }
        var h = host(demo, turns: turns)
        h.explainAccess = { _, _ in await entered.open(); await release.wait(); return true }
        let tools = PippaMCPTools(host: h), context = PippaMCPTools(host: h).captureRequest(), body = request()
        let work = Task { await tools.handle(body, context: context) }
        let waiting = await reached(entered)
        turns.end(old); turns.begin(next)
        await release.open()
        let result = payload(await work.value)
        // A previously captured request cannot borrow the next answer's live scope either.
        let late = payload(await tools.handle(body, context: context))
        let receipts = old.writes.snapshot.receipts
        return waiting && result["status"] as? String == "cancelled" && late["status"] as? String == "cancelled"
            && demo.createdCount == 0 && receipts.count == 2 && receipts.allSatisfy { $0.turnID == old.id && $0.operationID != nil }
            && observed.receipts == receipts && next.writes.snapshot.receipts.isEmpty && next.writes.snapshot.pending.isEmpty
    }

    await checkAsync("Native writes: no active MCP turn fails closed, direct Save Draft has an independent action scope") {
        let demo = DemoIntegrations(granted: true), turns = PippaMCPTurns()
        let h = host(demo, turns: turns)
        let result = payload(await PippaMCPTools(host: h).handle(request()))
        let source = MailReplySource(messageID: "native-cancel@example.test", replyTo: "person@example.test", subject: "Test")!
        let saved = await PippaMCPWriteTools(host: h).replyDraft(to: source, body: "Thank you.")
        return result["status"] as? String == "cancelled" && demo.createdCount == 0
            && !saved.isError && demo.insertedDrafts.count == 1 && saved.receipt?.turnID == nil && saved.receipt?.operationID != nil
    }

    await checkAsync("Native request origin: late document/front reads keep the captured turn, chip and receipt identity") {
        let demo = DemoIntegrations(granted: true), turns = PippaMCPTurns(), old = PippaMCPTurn(), next = PippaMCPTurn()
        turns.begin(old)
        let reads = NativeReadBox()
        reads.front = FrontApp(name: "Safari", bundleID: FrontApp.safari, pid: 1, title: "Old page")
        var h = host(demo, turns: turns)
        h.front = DemoFrontApp(); h.shownFront = { reads.front }; h.onRead = { reads.append($0) }
        let tools = PippaMCPTools(host: h), captured = tools.captureRequest()
        turns.end(old); turns.begin(next); reads.front = nil
        let file = root.appendingPathComponent("native-request-origin.txt")
        try "Invented document for the original answer.".write(to: file, atomically: true, encoding: .utf8)
        let document = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                      "params": ["name": "read_document", "arguments": ["path": file.path]]])
        let front = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 2, "method": "tools/call",
                      "params": ["name": "front_read", "arguments": [:]]])
        _ = await tools.handle(document, context: captured)
        let shown = payload(await tools.handle(front, context: captured))
        let originalLedger = await old.ledger, laterLedger = await next.ledger
        return originalLedger.readCompletely(file.path) == true && laterLedger.readCompletely(file.path) != true
            && (shown["data"] as? [String: Any])?["app"] as? String == "Safari"
            && reads.notes.first?.turnID == old.id && reads.notes.first?.read == true
    }

    await checkAsync("Native writes: Stop while waiting on Apple Events queue prevents dispatch and records nothing changed") {
        let entered = NativeWriteGate(), requested = NativeWriteGate()
        let releaseQueue = DispatchSemaphore(value: 0), counter = NativeReceiptBox()
        let blocker = Task {
            try await AppleEventsExecutionCheck.perform {
                Task { await entered.open() }
                releaseQueue.wait()
                return true
            }
        }
        let queueOccupied = await reached(entered)
        let demo = DemoIntegrations(granted: true), turns = PippaMCPTurns(), turn = PippaMCPTurn()
        turns.begin(turn)
        var h = host(demo, turns: turns)
        h.writer = NativeTestWriter(mode: .queued, entered: requested, release: NativeWriteGate(), counter: counter)
        let tools = PippaMCPTools(host: h), body = request("calendar_add")
        let work = Task { await tools.handle(body) }
        let queued = await reached(requested)
        let before = turn.writes.snapshot
        turn.cancelWrites()
        releaseQueue.signal()
        _ = try await blocker.value
        let result = payload(await work.value)
        return queueOccupied && queued && before.pending.count == 1 && before.pending.first?.dispatched == false
            && result["status"] as? String == "cancelled" && result["dispatched"] as? Bool == false
            && counter.receipts.isEmpty && turn.writes.snapshot.receipts.first?.reason == "stopped"
    }

    for uncertain in [false, true] {
        await checkAsync("Native writes: dispatched call stopped in flight retains \(uncertain ? "uncertain/no-retry" : "confirmed success") outcome under its origin") {
            let demo = DemoIntegrations(granted: true), turns = PippaMCPTurns(), turn = PippaMCPTurn(), next = PippaMCPTurn()
            turns.begin(turn)
            let entered = NativeWriteGate(), release = NativeWriteGate(), observed = NativeReceiptBox()
            turn.writes.observeReceipts { observed.append($0) }
            var h = host(demo, turns: turns)
            h.writer = NativeTestWriter(mode: uncertain ? .uncertain : .success, entered: entered, release: release, counter: NativeReceiptBox())
            let tools = PippaMCPTools(host: h), body = request("calendar_add")
            let work = Task { await tools.handle(body) }
            let dispatched = await reached(entered)
            turns.end(turn); turns.begin(next)
            let began = ContinuousClock.now
            let pending = await turn.writes.settle(within: 0.03)
            let bounded = ContinuousClock.now - began < .seconds(1)
            await release.open()
            let result = payload(await work.value)
            let final = turn.writes.snapshot
            let receipt = final.receipts.first
            return dispatched && bounded && pending.pending.first?.dispatched == true
                && pending.items.first?.outcome == "unclear" && pending.items.first?.reason == "pending"
                && final.pending.isEmpty && receipt?.outcome == (uncertain ? "unclear" : "done")
                && receipt?.turnID == turn.id && receipt?.operationID == pending.pending.first?.id
                && observed.receipts == final.receipts && next.writes.snapshot.receipts.isEmpty
                && (uncertain ? (result["next"] as? String)?.contains("do not retry") == true : result["done"] as? Bool == true)
        }
    }

    await checkAsync("Native writes: revoking old process endpoint cancels accepted work and rejects old credentials after next turn") {
        let demo = DemoIntegrations(), turns = PippaMCPTurns(), old = PippaMCPTurn(), next = PippaMCPTurn()
        turns.begin(old)
        let entered = NativeWriteGate(), release = NativeWriteGate()
        var h = host(demo, turns: turns)
        h.explainAccess = { _, _ in await entered.open(); await release.wait(); return true }
        let server = try PippaMCPServer(host: h)
        let body = request()
        let request = PippaHTTPRequest(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1:54001",
                                      "authorization": "Bearer \(server.token)", "content-type": "application/json"], body: body)
        let work = Task { await server.respond(to: request, port: 54001) }
        let waiting = await reached(entered)
        server.revoke()
        turns.end(old); turns.begin(next)
        await release.open()
        let accepted = await work.value
        let stale = await server.respond(to: request, port: 54001)
        return waiting && payload(accepted.body)["status"] as? String == "cancelled"
            && stale.status == 403 && demo.createdCount == 0 && old.writes.snapshot.cancelled
            && next.writes.snapshot.receipts.isEmpty
    }
}

private actor NativeWriteGate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() { opened = true; let found = waiting; waiting = []; found.forEach { $0.resume() } }
}

private final class NativeReceiptBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PippaMCPWriteReceipt] = []
    func append(_ value: PippaMCPWriteReceipt) { lock.withLock { values.append(value) } }
    var receipts: [PippaMCPWriteReceipt] { lock.withLock { values } }
}

private final class NativeReadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFront: FrontApp?
    private var values: [PippaMCPReadNote] = []
    var front: FrontApp? {
        get { lock.withLock { storedFront } }
        set { lock.withLock { storedFront = newValue } }
    }
    func append(_ value: PippaMCPReadNote) { lock.withLock { values.append(value) } }
    var notes: [PippaMCPReadNote] { lock.withLock { values } }
}

private struct NativeTestWriter: HostWriting {
    enum Mode: Sendable { case queued, success, uncertain }
    let mode: Mode
    let entered: NativeWriteGate
    let release: NativeWriteGate
    let counter: NativeReceiptBox
    func addEvent(_ event: NewCalendarEvent) async throws -> HostWrite {
        let value = HostWrite(item: CreatedItem(integration: .calendar, identifier: "invented", modified: nil), container: "Test")
        if mode == .queued {
            await entered.open()
            return try await AppleEventsExecutionCheck.perform(mutation: true) {
                counter.append(.init(action: "calendarAdd", outcome: "done", name: "Test"))
                return value
            }
        }
        try PippaMCPWriteLease.current?.beginDispatch()
        await entered.open()
        await release.wait()
        if mode == .uncertain { throw PippaError.notAvailable }
        return value
    }
    func addReminder(_ reminder: NewReminder) async throws -> HostWrite { throw PippaError.notAvailable }
}
