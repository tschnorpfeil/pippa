import AppKit
import PDFKit
import PippaCore

#if DEBUG
/// `PIPPA_DEMO=1 PIPPA_DEMO_MODEL=missing PIPPA_SNAPSHOT_ONLY=nativefirstuse`: real setup chooser handover,
/// file tools, failure recovery and result controls. Synthetic files only; no model, external apps or download.
/// Read this isolated app once with an external accessibility client while it starts (or use VoiceOver): SwiftUI
/// creates its accessibility proxies lazily. The result-action assertions deliberately require the real AX tree.
@MainActor enum NativeFirstUseSnapshot {
    static func run(model: AppModel, shell: ShellController, directory: URL,
                    snapshot: (String) async -> Void) async {
        var lines: [String] = [], failures = 0
        func check(_ ok: Bool, _ description: String) {
            lines.append("\(ok ? "PASS" : "FAIL"): \(description)")
            if !ok { failures += 1 }
        }
        func finish() {
            try? ((failures == 0 ? "PASS" : "FAIL") + ": native first-use flow\n" + lines.joined(separator: "\n") + "\n")
                .write(to: directory.appendingPathComponent("nativefirstuse.txt"), atomically: true, encoding: .utf8)
        }
        guard model.engine is StubEngine, !model.modelReady, DevSnapshot.directory == directory else {
            check(false, "Requires isolated snapshot directory and demo engine with model missing")
            finish(); return
        }
        func waitForTool() async {
            for _ in 0..<600 {
                if !model.tray.isWorking { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
            check(false, "Native tool completed within 30 seconds")
            model.tray.stop()
        }
        func shot(_ name: String) async {
            await snapshot(name)
            check(shell.lastMeasuredHeight <= shell.shellScreenRect.height + 1, "\(name) fits the available height")
        }
        let setup = PiSetupController(flow: nil, state: .askDownload(bytes: 6_716_356_800))
        PiSetupController.shared = setup
        setup.attach(to: model)
        NSApp.activate()
        model.show(.onboarding)
        await shot("native-first-01-welcome")
        let a = directory.appendingPathComponent("Photo one.png"), b = directory.appendingPathComponent("Photo two.png")
        do {
            for (index, url) in [a, b].enumerated() {
                let image = NSImage(size: NSSize(width: 420, height: 560))
                image.lockFocus()
                NSColor.white.setFill()
                NSBezierPath(rect: NSRect(x: 0, y: 0, width: 420, height: 560)).fill()
                ("Pippa fixture \(index + 1)" as NSString).draw(at: NSPoint(x: 40, y: 450), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 26), .foregroundColor: NSColor.black,
                ])
                image.unlockFocus()
                guard let data = image.tiffRepresentation, let rep = NSBitmapImageRep(data: data),
                      let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try png.write(to: url)
            }
            let originals = try [a, b].map { try Data(contentsOf: $0) }
            setup.useNativeFiles([a, b])
            check(model.mode.key == "line" && model.tray.givenItems.map(\.url) == [a, b], "Chooser handover opens native actions with chosen files")
            check(setup.asksDownload && setup.deferred && !model.modelReady, "No download consent or model activation")
            guard let sourceID = model.tray.givenItems.first?.id else {
                check(false, "Native chooser retains at least one source"); finish(); return
            }
            check(model.tray.resultURL(sourceID) == nil, "Result controls reject source-file identity")
            await shot("native-first-02-actions")
            guard let action = model.tray.availableActions.first(where: { $0.id == ToolID.makeOnePDF.rawValue }) else {
                check(false, "Make one PDF is offered"); finish(); return
            }
            let conversionStarted = Date()
            model.tray.choose(action)
            await waitForTool()
            let conversionSeconds = Date().timeIntervalSince(conversionStarted)
            check(conversionSeconds < 10, "Two-photo PDF becomes usable within 10 seconds (\(String(format: "%.2f", conversionSeconds)) s)")
            guard let result = model.tray.items.first(where: { $0.role == .result }) else {
                check(false, "Native PDF result exists"); finish(); return
            }
            check(PDFDocument(url: result.url)?.pageCount == 2, "Result is an actual two-page PDF")
            check(model.tray.resultURL(result.id) == result.url && model.tray.resultURL(UUID()) == nil, "Open, Save and Reveal use the retained result identity")
            await shot("native-first-03-result")
            let labels = accessibilityText(shell.panel)
            try? labels.sorted().joined(separator: "\n").write(to: directory.appendingPathComponent("nativefirstuse-accessibility.txt"), atomically: true, encoding: .utf8)
            for label in [T("Open %@", table: "NativeFlow", result.name), T("Save…", table: "Line"),
                          T("Show in Finder", table: "NativeFlow"), T("Undo", table: "Line")] {
                check(labels.contains(label), "Accessible result action: \(label)")
            }
            model.tray.save(result.id, to: directory.appendingPathComponent("missing-folder/Result.pdf"))
            for _ in 0..<100 {
                if model.tray.resultProblem != nil { break }
                try? await Task.sleep(for: .milliseconds(30))
            }
            check(model.tray.phase == .result(result.id) && model.tray.resultProblem != nil
                  && model.tray.resultURL(result.id) == result.url, "Failed Save retains result, controls and explanation")
            check(model.tray.items.first(where: { $0.id == result.id }) == result, "Failed Save preserves result identity and Undo inputs")
            await shot("native-first-04-save-recovery")
            model.tray.undoResult(result.id)
            for _ in 0..<100 {
                if !model.tray.items.contains(where: { $0.id == result.id }) { break }
                try? await Task.sleep(for: .milliseconds(30))
            }
            check(model.tray.givenItems.count == 2 && !FileManager.default.fileExists(atPath: result.url.path), "Undo after failed Save restores original selection")
            check(try [a, b].map { try Data(contentsOf: $0) } == originals, "Original photos remain byte-for-byte unchanged")
            for item in model.tray.givenItems { model.tray.remove(item.id) }

            // Corrupt input, then a user repair: retry remains deliberate and uses the original selected item.
            let broken = directory.appendingPathComponent("Repairable photo.png")
            try Data("synthetic invalid image".utf8).write(to: broken)
            model.tray.add([broken], origin: nil)
            model.tray.choose(.tool(.asPDF))
            await waitForTool()
            check(model.tray.canRetryTool && model.tray.givenItems.map(\.url) == [broken], "Failed file action retains the request and offers Retry")
            await shot("native-first-05-tool-recovery")
            try originals[0].write(to: broken)
            check(model.tray.canRetryTool && !model.tray.isWorking, "Repairing a source does not automatically replay the action")
            model.tray.retryTool()
            await waitForTool()
            guard let recovered = model.tray.items.first(where: { $0.role == .result }) else {
                check(false, "Explicit retry produces result"); finish(); return
            }
            check(PDFDocument(url: recovered.url)?.pageCount == 1, "Explicit retry produces a valid PDF from repaired source")
            let saved = directory.appendingPathComponent("Saved result.pdf")
            model.tray.save(recovered.id, to: saved)
            for _ in 0..<100 {
                if !model.tray.items.contains(where: { $0.id == recovered.id }) { break }
                try? await Task.sleep(for: .milliseconds(30))
            }
            let exported = try Data(contentsOf: saved), generated = try Data(contentsOf: recovered.url)
            check(!exported.isEmpty && exported == generated, "Save exports the exact generated artifact")
            check(!model.modelReady && !model.conversations.isRunning && setup.asksDownload, "Full result/recovery flow stays independent of model setup")
        } catch { check(false, "Synthetic fixture: \(error.localizedDescription)") }
        finish()
    }

    /// Inspect this app's native accessibility tree without requiring system Accessibility access.
    private static func accessibilityText(_ root: NSObject) -> Set<String> {
        var seen = Set<ObjectIdentifier>(), text = Set<String>()
        func visit(_ object: NSObject, depth: Int) {
            guard depth < 50, seen.insert(ObjectIdentifier(object)).inserted else { return }
            for key in ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"] {
                let selector = NSSelectorFromString(key)
                if object.responds(to: selector), let value = object.perform(selector)?.takeUnretainedValue() as? String { text.insert(value) }
            }
            let selector = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] {
                for child in children { visit(child, depth: depth + 1) }
            }
            // SwiftUI accessibility proxies can implement AppKit's attribute protocol instead of modern getters.
            let attribute = NSSelectorFromString("accessibilityAttributeValue:")
            if object.responds(to: attribute) {
                for key in ["AXTitle", "AXDescription", "AXValue"] {
                    if let value = object.perform(attribute, with: key)?.takeUnretainedValue() as? String { text.insert(value) }
                }
                if let children = object.perform(attribute, with: "AXChildren")?.takeUnretainedValue() as? [NSObject] {
                    for child in children { visit(child, depth: depth + 1) }
                }
            }
            // AppKit containers may be accessibility-ignored; inspect their hosted accessibility roots too.
            if let window = object as? NSWindow, let content = window.contentView { visit(content, depth: depth + 1) }
            if let view = object as? NSView {
                for child in view.subviews where !child.isHidden { visit(child, depth: depth + 1) }
            }
        }
        visit(root, depth: 0)
        return text
    }
}
#endif
