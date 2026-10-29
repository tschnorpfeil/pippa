import AppKit
import PDFKit
import PippaCore
import SwiftUI

#if DEBUG
/// Real controllers with synthetic documents and isolated journals. No model or private account is accessed.
@MainActor enum EverydayHelpSnapshot {
    static func run(model: AppModel, shell: ShellController, directory: URL,
                    snapshot: (String) async -> Void) async {
        var assertions: [String] = []
        func check(_ value: Bool, _ description: String) {
            assertions.append("\(value ? "PASS" : "FAIL"): \(description)")
        }
        defer {
            let success = !assertions.contains { $0.hasPrefix("FAIL:") }
            try? ((success ? "PASS" : "FAIL") + ": everyday help\n" + assertions.joined(separator: "\n") + "\n")
                .write(to: directory.appendingPathComponent("everydayhelp.txt"), atomically: true, encoding: .utf8)
        }
        guard model.engine is StubEngine, !model.modelReady, DevSnapshot.directory == directory else {
            check(false, "Requires isolated demo engine with no model"); return
        }
        func wait(_ description: String, until condition: () -> Bool) async {
            for _ in 0..<600 {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            check(false, description + " completed within 30 seconds")
        }
        func shot(_ name: String) async {
            await snapshot(name)
            check(shell.lastMeasuredHeight <= shell.shellScreenRect.height + 1, name + " fits available height")
        }
        do {
            let first = directory.appendingPathComponent("First/Document.pdf")
            let second = directory.appendingPathComponent("Second/Document.pdf")
            try makePDF("FIRST SOURCE", at: first)
            try makePDF("SECOND SOURCE", at: second)
            let originals = try [first, second].map { try Data(contentsOf: $0) }
            let tray = model.tray
            tray.add([first, second], origin: nil)
            model.openLine()
            check(tray.canPrepareFiles && !model.modelReady, "Preparation is available without downloading a model")
            tray.prepareFiles()
            await wait("Source preview") { !tray.isWorking }
            guard let preview = tray.preparation else { check(false, "Saved preview exists"); return }
            check(preview.items.map(\.url) == [first, second], "Duplicate names retain distinct identities and input order")
            check(preview.grants.count == 2 && preview.sources.count == 2, "Preview keeps source grants and content identities")
            await shot("everyday-01-preview")
            tray.movePreparationInput(preview.items[1].id, by: -1)
            await wait("Reorder save") { !tray.isWorking }
            check(tray.preparation?.items.map(\.url) == [second, first], "Move earlier changes the reviewed order")
            tray.setPreparationSizeGoal(.fiveMB)
            await wait("Size goal save") { !tray.isWorking }
            check(tray.preparation?.plan.sizeGoal == .fiveMB, "Chosen size goal is part of the saved request")
            let beforeRun = try await tray.retainedPreparationInputs()
            check(Set(beforeRun) == Set([first, second]), "Inbox cleanup retains all saved request inputs")
            tray.runPreparation()
            await wait("PDF preparation") { !tray.isWorking }
            guard let result = tray.items.first(where: { $0.role == .result }) else {
                check(false, "Verified result exists"); return
            }
            let pdf = PDFDocument(url: result.url)
            check(pdf?.pageCount == 2 && pdf?.page(at: 0)?.string?.contains("SECOND SOURCE") == true
                  && pdf?.page(at: 1)?.string?.contains("FIRST SOURCE") == true, "Saved PDF has the reviewed page order")
            check(!result.url.path.hasPrefix(ResultsFolder.directory.path + "/")
                  && result.url.path.hasPrefix(PippaCore.Pippa.supportDirectory.path + "/"),
                  "Completed artifact lives outside the expiring results cache")
            check(tray.resultURL(result.id) == result.url && tray.resultURL(UUID()) == nil, "Result controls require the retained artifact identity")
            await shot("everyday-02-result")
            let generated = try Data(contentsOf: result.url)
            tray.save(result.id, to: directory.appendingPathComponent("missing-parent/Export.pdf"))
            await wait("Failed Save") { tray.resultProblem != nil }
            check(tray.resultURL(result.id) == result.url && tray.phase == .result(result.id), "Failed Save keeps result and controls")
            check(try Data(contentsOf: result.url) == generated, "Failed Save preserves verified artifact bytes")
            await shot("everyday-03-save-failure")

            let restored = TrayController()
            restored.load()
            await wait("Restored result") { restored.items.contains { $0.id == result.id } }
            check(restored.resultURL(result.id) == result.url && !restored.isWorking,
                  "A new controller restores the result without running a tool")
            check(try [first, second].map { try Data(contentsOf: $0) } == originals, "All original files remain byte-for-byte unchanged")

            let exported = directory.appendingPathComponent("Exported.pdf")
            tray.save(result.id, to: exported)
            await wait("Successful Save") { !tray.items.contains { $0.id == result.id } }
            check(try Data(contentsOf: exported) == generated, "Successful Save exports the exact verified result")

            let isolatedStore = TrayStore(directory: directory.appendingPathComponent("pending-request"))
            let pending = TrayController(store: isolatedStore)
            pending.add([first, second], origin: nil)
            pending.prepareFiles()
            await wait("Pending preview") { !pending.isWorking }
            pending.closePreparation()
            await wait("Saved task listing") { pending.hasPendingPreparationJobs }
            let reopened = TrayController(store: isolatedStore)
            reopened.load()
            await wait("Restored pending task") { reopened.hasPendingPreparationJobs }
            check(!reopened.isWorking && reopened.items.allSatisfy { $0.role != .result },
                  "Restored queued work waits for deliberate review")
            guard let job = reopened.preparationJobs.first else { check(false, "Pending request remains discoverable"); return }
            reopened.resumePreparation(job)
            await wait("Restored preview") { !reopened.isWorking }
            check(reopened.preparation?.sources.map(\.url) == [first, second], "Review restores the saved source order")
            reopened.runPreparation()
            reopened.stop()
            try? await Task.sleep(for: .milliseconds(500))
            check(!reopened.isWorking && reopened.items.allSatisfy { $0.role != .result },
                  "Stop during admission rejects late work and completion")
            let stoppedCapture = TrayController(store: TrayStore(directory: directory.appendingPathComponent("stopped-capture")))
            stoppedCapture.add([first, second], origin: nil)
            stoppedCapture.prepareFiles(); stoppedCapture.stop()
            try? await Task.sleep(for: .milliseconds(300))
            check(!stoppedCapture.isWorking && stoppedCapture.preparation == nil,
                  "Stop during source capture rejects late preview publication")
            check(!model.modelReady && !model.conversations.isRunning, "Every file step remains independent of Pi and model setup")
            assertions += await PreparedFilesCardSnapshot.run(directory: directory, source: first)
        } catch { check(false, "Controller fixture: \(error)") }
        assertions += await MorningBriefingSnapshot.run(directory: directory)
        assertions += await ChartCardSnapshot.run(directory: directory)
        assertions += await FilledFormCardSnapshot.run(directory: directory)
    }

    private static func makePDF(_ text: String, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var box = CGRect(x: 0, y: 0, width: 400, height: 500)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor); context.fill(box)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (text as NSString).draw(at: NSPoint(x: 30, y: 400), withAttributes: [
            .font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black,
        ])
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage(); context.closePDF()
    }
}
#endif
