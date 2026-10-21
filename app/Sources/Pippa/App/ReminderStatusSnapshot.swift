import AppKit
import PippaCore
import SwiftUI

#if DEBUG
private actor SnapshotReminderLookup {
    var calls = 0
    var result: [NativeReminderRecord]?
    func read() async -> [NativeReminderRecord] {
        calls += 1
        for _ in 0..<500 {
            if let result { return result }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return []
    }
    func finish(_ records: [NativeReminderRecord]) { result = records }
}

@MainActor private final class ReminderSnapshotChat: ConversationChat {
    var started = false
    var finish = false
    func answer(_ text: String, taskID: String, context: ChatContext, newFiles: [URL], skill: PippaSkill?, draftOnly: Bool,
                onDelta: @escaping @Sendable (String) -> Void, onSteered: @escaping @Sendable (String) -> Void,
                onReset: (@Sendable (String) -> Void)?) async throws -> PiRPCChat.ShownAnswer {
        started = true
        onDelta("New answer in progress")
        for _ in 0..<500 {
            if finish { return .init(text: "New answer complete", reviewed: false) }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CancellationError()
    }
    func steer(_ text: String) async -> Bool { false }
    func cancel() async { finish = true }
    func forget(_ keys: [String]) async {}
    func takeShownActions() -> ActionReceipt? { nil }
}

/// Real controller and 400-point receipt layout with synthetic journal evidence. No native apps or permissions.
@MainActor enum ReminderStatusSnapshot {
    static func run(model: AppModel, directory: URL) async {
        var checks: [String] = []
        func check(_ value: Bool, _ name: String) { checks.append("\(value ? "PASS" : "FAIL"): \(name)") }
        defer {
            let ok = !checks.contains { $0.hasPrefix("FAIL:") }
            try? ((ok ? "PASS" : "FAIL") + ": reminder status\n" + checks.joined(separator: "\n") + "\n")
                .write(to: directory.appendingPathComponent("reminderstatus.txt"), atomically: true, encoding: .utf8)
        }
        guard model.engine is StubEngine, DevSnapshot.directory == directory else {
            check(false, "Requires isolated demo history"); return
        }
        let chat = model.conversations
        model.newConversation()
        do {
            guard let question = chat.append(.user, "Create a synthetic reminder"), let conversation = chat.current?.id else {
                check(false, "Creates isolated conversation"); return
            }
            let journal = try Executor(baseDirectory: directory.appendingPathComponent("reminder-journal"))
            guard case .execute(let planned) = try await journal.beginNativeReminder(id: UUID(),
                origin: .init(conversationID: conversation, requestID: question), turnID: UUID(), requestHash: "snapshot",
                reminder: NewReminder(title: "Synthetic reminder"), label: "Synthetic reminder") else {
                check(false, "Creates synthetic operation"); return
            }
            _ = try await journal.prepareNativeReminder(id: planned.id, target: .init(identifier: "fixture-list", title: "Fixture list"))
            let pending = try await journal.dispatchNativeReminder(id: planned.id)
            guard let message = chat.append(.system, "Unconfirmed reminder", notice: true, actions: .init(items: [pending.receipt.item])) else {
                check(false, "Persists synthetic receipt"); return
            }
            let lookup = SnapshotReminderLookup()
            chat.reminderLookupForSnapshot = { _, _ in await lookup.read() }
            defer { chat.reminderLookupForSnapshot = nil }
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 220),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            panel.title = "Pippa reminder status fixture"
            defer { panel.orderOut(nil) }
            func render(_ item: ActionReceipt.Item, _ state: ReminderStatusCheck.State?, _ name: String) async {
                let content = ActionReceiptView(receipt: .init(items: [item]),
                    onOpenReminders: {}, onCheckReminder: { _ in }, onOpenPermissionSettings: { _ in },
                    reminderCheckDisabled: state?.phase == .checking,
                    reminderCheckState: state)
                let host = NSHostingView(rootView: content.padding(12).frame(width: 400, height: 220, alignment: .topLeading))
                panel.contentView = host
                panel.center(); panel.makeKeyAndOrderFront(nil)
                NSApp.activate()
                try? await Task.sleep(for: .milliseconds(500))
                host.layoutSubtreeIfNeeded()
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    check(false, "Renders \(name)"); return
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: directory.appendingPathComponent(name + ".png"))
                }
                check(host.bounds.width == 400 && bitmap.pixelsWide > 0, "\(name) renders at 400 points")
            }
            await render(pending.receipt.item, nil, "reminder-status-idle")
            await render(.init(action: "reminderAdd", outcome: "failed", name: "Synthetic reminder", reason: "denied"),
                         nil, "reminder-status-denied")
            chat.checkReminderStatus(messageID: message, operationID: pending.id)
            chat.checkReminderStatus(messageID: message, operationID: pending.id)
            check(chat.reminderCheckState?.phase == .checking && !chat.canCheckReminderStatus,
                  "Repeated click is blocked while status is checking")
            await render(pending.receipt.item, chat.reminderCheckState, "reminder-status-checking")
            let answer = ReminderSnapshotChat()
            chat.send("Keep this new question and answer", chat: answer)
            for _ in 0..<100 where !answer.started { try? await Task.sleep(for: .milliseconds(20)) }
            check(answer.started && chat.isRunning, "A new conversational turn can start while readback is pending")
            var completed = pending
            completed.phase = .completed; completed.revision += 1; completed.recovered = true
            completed.result = .init(item: .init(integration: .reminders, identifier: "fixture-reminder", modified: nil, fingerprint: "fixture-content"),
                                     container: "Fixture list", containerIdentifier: "fixture-list")
            await lookup.finish([completed])
            for _ in 0..<100 where chat.reminderCheckState?.phase == .checking { try? await Task.sleep(for: .milliseconds(20)) }
            check(chat.reminderCheckState?.phase == .confirmed, "Readback updates the original reminder receipt")
            check(chat.current?.messages.contains(where: { $0.text == "Keep this new question and answer" }) == true,
                  "Readback retains the new persisted user message")
            check(chat.isRunning && chat.streamingText == "New answer in progress", "Readback preserves the active streamed answer")
            check(await lookup.calls == 1, "Double click performs one lookup")
            answer.finish = true
            for _ in 0..<100 where chat.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
            check(chat.current?.messages.last?.text == "New answer complete", "The new answer completes normally after readback")
            check(chat.current?.messages.first(where: { $0.id == message })?.actions?.items.first?.outcome == "done",
                  "The confirmed original receipt survives the later answer")
        } catch { check(false, "Synthetic fixture: \(error.localizedDescription)") }
    }
}
#endif
