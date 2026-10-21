import AppKit
import PippaCore
import SwiftUI

#if DEBUG
private actor MorningSnapshotReader: MorningBriefingReading {
    var calls: [String] = []
    var held = false
    var failure: MorningBriefingReadFailure?
    var pending: CheckedContinuation<Void, Never>?
    init(held: Bool = false, failure: MorningBriefingReadFailure? = nil) { self.held = held; self.failure = failure }
    func sources(for kind: MorningBriefingSource.Kind) async throws -> [MorningBriefingSource] { [] }
    func read(_ source: MorningBriefingSource, day: DateInterval, limit: Int) async throws -> MorningBriefingRead {
        calls.append(source.id)
        if held { await withCheckedContinuation { pending = $0 } }
        if let failure { throw failure }
        let title = source.kind == .calendar ? "Design review" : "Book the train"
        return .init(entries: [.init(id: source.id + "-item", source: source, title: title,
            start: day.start.addingTimeInterval(9 * 3600), end: source.kind == .calendar ? day.start.addingTimeInterval(10 * 3600) : nil)], total: 1)
    }
    func release() { held = false; pending?.resume(); pending = nil }
    func count() -> Int { calls.count }
}

/// The real controller with synthetic readers. Demo suppresses OS notification, permission,
/// timer and app-opening effects, while explicit fixture checks exercise the production run path.
@MainActor enum MorningBriefingSnapshot {
    static func run(directory: URL) async -> [String] {
        var checks: [String] = []
        func check(_ value: Bool, _ name: String) { checks.append("\(value ? "PASS" : "FAIL"): morning \(name)") }
        func wait(until predicate: () -> Bool) async -> Bool {
            for _ in 0..<250 {
                if predicate() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return false
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 8))!
        let source = MorningBriefingSource(kind: .calendar, identifier: "synthetic-work", title: "Work")
        let list = MorningBriefingSource(kind: .reminders, identifier: "synthetic-tasks", title: "Personal")
        var configuration = MorningBriefingConfiguration()
        configuration.enabled = true; configuration.sources = [source, list]
        let reader = MorningSnapshotReader()
        let controller = MorningBriefingController(baseDirectory: directory.appendingPathComponent("morning-success"), reader: reader, demo: true)
        controller.checkIfDue(now: now, calendar: calendar)
        check(!controller.configuration.enabled && !controller.running && controller.latest == nil, "is off without explicit opt-in")
        check(await reader.count() == 0, "default off never calls the reader")
        await render(MorningBriefingSettingsView(controller: controller), name: "morning-settings-off", directory: directory, checks: &checks)
        var publications = 0
        controller.onResult = { _ in publications += 1 }
        controller.save(configuration); controller.checkIfDue(now: now, calendar: calendar)
        let finished = await wait { !controller.running }
        check(finished && controller.latest?.entries.count == 2 && controller.latest?.isComplete == true, "real controller publishes selected source facts")
        check(await reader.count() == 2 && publications == 1, "each chosen source is read once and one result is published")
        controller.checkIfDue(now: now, calendar: calendar)
        check(await reader.count() == 2 && publications == 1, "repeated wake cannot duplicate a daily result")
        let restored = MorningBriefingController(baseDirectory: directory.appendingPathComponent("morning-success"), reader: reader, demo: true)
        restored.checkIfDue(now: now, calendar: calendar)
        check(restored.latest == controller.latest && !restored.running && publications == 1, "restart restores the result without new reads")
        if let result = controller.latest {
            await render(MorningBriefingResultView(result: result, controller: controller), name: "morning-result", directory: directory, checks: &checks)
            var travelled = result
            travelled.occurrence.timeZone = TimeZone.current.identifier == "Asia/Tokyo" ? "America/New_York" : "Asia/Tokyo"
            let view = MorningBriefingResultView(result: travelled, controller: controller)
            let expected = DateFormatter()
            expected.locale = .current; expected.timeZone = TimeZone(identifier: travelled.occurrence.timeZone)!
            expected.dateStyle = .full; expected.timeStyle = .short
            check(view.formatted(result.readAt, date: .full, time: .short) == expected.string(from: result.readAt),
                  "saved dates and times keep the occurrence timezone after travel")
        }
        await render(MorningBriefingSettingsView(controller: controller), name: "morning-settings", directory: directory, checks: &checks)
        var narrower = configuration; narrower.sources = [list]
        controller.save(narrower)
        check(controller.latest == nil, "deselecting a source immediately hides its saved facts")
        controller.delete(); controller.save(configuration); controller.checkIfDue(now: now, calendar: calendar)
        check(!controller.running && controller.latest == nil && publications == 1, "remove and re-enable does not replay the same day")

        for action in ["pause", "delete", "edit"] {
            let slow = MorningSnapshotReader(held: true)
            let pending = MorningBriefingController(baseDirectory: directory.appendingPathComponent("morning-" + action), reader: slow, demo: true)
            var published = false; pending.onResult = { _ in published = true }
            pending.save(configuration); pending.checkIfDue(now: now, calendar: calendar)
            for _ in 0..<250 { if await slow.count() > 0 { break }; try? await Task.sleep(for: .milliseconds(20)) }
            check(await slow.count() == 1, action + " fixture begins only the first selected read")
            if action == "pause" { pending.pause() }
            else if action == "delete" { pending.delete() }
            else { pending.save(narrower) }
            await slow.release()
            try? await Task.sleep(for: .milliseconds(100))
            check(await slow.count() == 1 && pending.latest == nil && !published && !pending.running,
                  action + " fences a late callback, the next source and result publication")
        }
        let deniedReader = MorningSnapshotReader(failure: .denied)
        let denied = MorningBriefingController(baseDirectory: directory.appendingPathComponent("morning-denied"), reader: deniedReader, demo: true)
        denied.save(configuration); denied.checkIfDue(now: now, calendar: calendar)
        let denialFinished = await wait { !denied.running }
        check(denialFinished && denied.latest?.isComplete == false && denied.latest?.checkedSources.isEmpty == true
              && denied.latest?.issues.count == 2 && denied.needsAttention, "permission revocation is visible and never reported as an empty day")
        if let result = denied.latest {
            await render(MorningBriefingResultView(result: result, controller: denied), name: "morning-denied", directory: directory, checks: &checks)
        }
        check(!configuration.notify, "notifications stay opt-in and all fixture system effects are suppressed")
        return checks
    }

    private static func render<Content: View>(_ content: Content, name: String, directory: URL, checks: inout [String]) async {
        let host = NSHostingView(rootView: content.padding(12).frame(width: 440, alignment: .topLeading).background(Theme.paper))
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        panel.contentView = host; panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(150))
        let size = host.fittingSize
        let fits = size.width <= 440.5 && size.height > 40 && size.height < 1400
        checks.append("\(fits ? "PASS" : "FAIL"): \(name) fits 440 points")
        host.frame = NSRect(x: 0, y: 0, width: 440, height: ceil(size.height)); panel.setContentSize(host.frame.size)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            checks.append("FAIL: \(name) renders"); return
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            checks.append("FAIL: \(name) capture"); return
        }
        do { try png.write(to: directory.appendingPathComponent(name + ".png")); checks.append("PASS: \(name) captured") }
        catch { checks.append("FAIL: \(name) writes capture") }
    }
}
#endif
