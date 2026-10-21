import AppKit
import PDFKit
import PiRPC
import PippaCore
import SwiftUI

#if DEBUG
/// Native journal and actual card actions with owned fixture files. No viewer, save panel,
/// model or personal directory is opened.
@MainActor enum PreparedFilesCardSnapshot {
    static func run(directory: URL, source: URL) async -> [String] {
        var checks: [String] = []
        func check(_ value: Bool, _ name: String) { checks.append("\(value ? "PASS" : "FAIL"): prepared card \(name)") }
        do {
            let base = directory.appendingPathComponent("prepared-card")
            let jobs = try DurableJobStore(baseDirectory: base)
            let tray = TrayController(store: TrayStore(directory: base))
            let original = TrayItem(role: .given, url: source)
            let before = try Data(contentsOf: source)
            let draft = FilePreparationDraft(items: [original], sources: [try FilePreparationSource.capture(source)],
                grants: [try DurableJobInput.capture(url: source)], plan: .init(sizeGoal: .fiveMB))

            func make(_ name: String) async throws -> (PreparedFilesCard, TrayItem) {
                let job = try await jobs.create(kind: .filePreparation, requestKey: "card-fixture:" + name,
                    title: "Synthetic prepared PDF", inputs: draft.grants, payload: JSONEncoder().encode(draft))
                let run = try await jobs.start(id: job.id, expectedRevision: job.revision)
                let artifact = try await jobs.retainArtifact(from: source, run: run)
                let item = TrayItem(role: .result, url: artifact.url, sources: [original.id], tool: .makeOnePDF)
                let saved = FilePreparationSavedResult(items: [item], sources: [original])
                _ = try await jobs.finish(run: run, state: .completed, resultData: JSONEncoder().encode(saved), artifacts: [artifact])
                return (.init(jobID: job.id, files: [artifact.url], pageCount: PDFDocument(url: artifact.url)?.pageCount ?? 0,
                    totalBytes: artifact.identity.size, sizeLimitBytes: 5_000_000, withinLimit: artifact.identity.size <= 5_000_000,
                    note: "Synthetic verification details: page order checked; original files retained."), item)
            }
            let (card, item) = try await make("ready")
            tray.refreshSavedPreparations()
            let access = await tray.preparedFileAccess(card, file: item.url)
            check(access.canUse && tray.resultURL(item.id) == item.url, "native evidence restores a usable retained result")
            check(tray.phase == .idle, "refresh and result verification do not take over the chat")
            check(card.pageCount == 1 && card.totalBytes == Int64(before.count) && card.withinLimit == true,
                  "card facts match the verified file and requested size")
            var receipt = PiTurnReceipt()
            receipt.observe(.toolStarted(id: "prepare-fixture", name: "mcp__pippa__prepare_files", arguments: "{}"))
            receipt.observe(.toolEnded(id: "prepare-fixture", name: "mcp__pippa__prepare_files", isError: false, result: "Prepared"))
            let native = ActionReceipt.Item(action: "create", outcome: "done", name: item.name, reason: "preparedFiles",
                                            operationID: card.jobID, nativeRevision: 2)
            let mapped = PiRPCChat.actions(receipt, reads: [.init(tool: "prepare_files", read: true, line: "", card: .preparedFiles(card))],
                                           writes: [native])
            check(mapped?.cards == [.preparedFiles(card)] && mapped?.items.filter { $0 == native }.count == 1,
                  "Pi receipt and native card survive the production chat mapping")
            await render(card, tray: tray, name: "prepared-files-card", directory: directory, checks: &checks)
            let forged = PreparedFilesCard(jobID: card.jobID, files: [source], pageCount: 1,
                totalBytes: Int64(before.count), sizeLimitBytes: nil, withinLimit: nil, note: "")
            check(await tray.preparedFileAccess(forged, file: source) == .unavailable,
                  "a card cannot turn an original or arbitrary path into a result action")
            tray.undoResult(item.id)
            check(try Data(contentsOf: item.url) == before && tray.resultProblem != nil,
                  "Undo without a journal receipt retains the durable file and explains why")
            try Data("Edited synthetic result".utf8).write(to: item.url)
            let changed = await tray.preparedFileAccess(card, file: item.url)
            check(changed == .changed, "changed output loses Open and Save authority")
            var changedSaveCompleted = false
            let blockedExport = base.appendingPathComponent("must-not-exist.pdf")
            await tray.savePreparedFile(card, file: item.url, to: blockedExport) { message in
                changedSaveCompleted = message != nil
            }
            check(changedSaveCompleted && !FileManager.default.fileExists(atPath: blockedExport.path),
                  "changed output cannot be exported through a stale card")
            await render(card, tray: tray, name: "prepared-files-changed", directory: directory, checks: &checks)
            let (missingCard, missingItem) = try await make("missing")
            _ = await tray.preparedFileAccess(missingCard, file: missingItem.url)
            try FileManager.default.removeItem(at: missingItem.url)
            check(await tray.preparedFileAccess(missingCard, file: missingItem.url) == .unavailable,
                  "removed output is unavailable, never a stale path to open")
            let (saveCard, saveItem) = try await make("save")
            var failureFinished = false
            var failureMessage: String?
            await tray.savePreparedFile(saveCard, file: saveItem.url, to: base.appendingPathComponent("missing-parent/copy.pdf")) {
                failureMessage = $0; failureFinished = true
            }
            for _ in 0..<250 where !failureFinished { try? await Task.sleep(for: .milliseconds(20)) }
            let retainedAfterFailure = await tray.preparedFileAccess(saveCard, file: saveItem.url)
            check(failureFinished && failureMessage != nil && retainedAfterFailure.canUse,
                  "failed Save retains the verified result with a useful message")
            var saved = false
            var saveMessage: String?
            let exported = base.appendingPathComponent("Exported.pdf")
            await tray.savePreparedFile(saveCard, file: saveItem.url, to: exported) { saveMessage = $0; saved = true }
            for _ in 0..<250 where !saved { try? await Task.sleep(for: .milliseconds(20)) }
            let exportedBytes = try Data(contentsOf: exported)
            check(saved && saveMessage == nil && exportedBytes == before,
                  "Save exports the exact verified bytes")
            for _ in 0..<250 {
                if await tray.preparedFileAccess(saveCard, file: saveItem.url) == .retired { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            check(await tray.preparedFileAccess(saveCard, file: saveItem.url) == .retired,
                  "saved or dismissed result is explained honestly in historical chat cards")
            check(try Data(contentsOf: source) == before, "all source bytes remain unchanged")
        } catch { check(false, "fixture: \(error)") }
        return checks
    }

    private static func render(_ card: PreparedFilesCard, tray: TrayController, name: String, directory: URL,
                               checks: inout [String]) async {
        let host = NSHostingView(rootView: PreparedFilesCardView(card: card, tray: tray).padding(12).frame(width: 400).background(Theme.paper))
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        panel.contentView = host; panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(200))
        let size = host.fittingSize
        checks.append("\(size.width <= 400.5 && size.height < 700 ? "PASS" : "FAIL"): \(name) fits 400 points")
        host.frame = NSRect(x: 0, y: 0, width: 400, height: ceil(size.height)); panel.setContentSize(host.frame.size)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { checks.append("FAIL: \(name) renders"); return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { checks.append("FAIL: \(name) capture"); return }
        do { try png.write(to: directory.appendingPathComponent(name + ".png")); checks.append("PASS: \(name) captured") }
        catch { checks.append("FAIL: \(name) capture file") }
    }
}
#endif
