import AppKit
import PiRPC
import PippaCore
import SwiftUI

#if DEBUG
@MainActor private final class PermissionRepairFixtureChat: ConversationChat {
    var calls = 0
    let actions: ActionReceipt
    init(_ actions: ActionReceipt) { self.actions = actions }
    func answer(_ text: String, taskID: String, context: ChatContext, newFiles: [URL], skill: PippaSkill?, draftOnly: Bool,
                onDelta: @escaping @Sendable (String) -> Void, onSteered: @escaping @Sendable (String) -> Void,
                onReset: (@Sendable (String) -> Void)?) async throws -> PiRPCChat.ShownAnswer {
        calls += 1
        throw AnswerFailure.runtime("Synthetic permission repair fixture")
    }
    func steer(_ text: String) async -> Bool { false }
    func cancel() async {}
    func forget(_ keys: [String]) async {}
    func takeShownActions() -> ActionReceipt? { actions }
}

/// Real conversation/controller, exact repair-button action and 400-point rendering. The URL opener is replaced
/// only inside this isolated demo fixture: no system privacy panel, native app, model or replay is invoked.
@MainActor enum PermissionRepairSnapshot {
    static func run(model: AppModel, directory: URL) async {
        var checks: [String] = []
        func check(_ value: Bool, _ name: String) { checks.append("\(value ? "PASS" : "FAIL"): \(name)") }
        defer {
            let ok = !checks.contains { $0.hasPrefix("FAIL:") }
            try? ((ok ? "PASS" : "FAIL") + ": permission repair\n" + checks.joined(separator: "\n") + "\n")
                .write(to: directory.appendingPathComponent("permissionrepair.txt"), atomically: true, encoding: .utf8)
        }
        guard model.engine is StubEngine, DevSnapshot.directory?.standardizedFileURL == directory.standardizedFileURL else {
            check(false, "Requires isolated demo history"); return
        }
        var repeatedReads = PiTurnReceipt()
        for (id, failed) in [("first-document", false), ("second-document", true)] {
            repeatedReads.observe(.toolStarted(id: id, name: "mcp__pippa__read_document", arguments: "{}"))
            repeatedReads.observe(.toolEnded(id: id, name: "mcp__pippa__read_document", isError: failed, result: failed ? "Denied" : "Read"))
        }
        let mappedReads = PiRPCChat.actions(repeatedReads, reads: [
            .init(tool: "read_document", read: true, line: "Read first fixture"),
            .init(tool: "read_document", read: false, line: "Denied second fixture", permissionRepair: .filesAndFolders)
        ])?.items ?? []
        check(mappedReads.count == 2 && mappedReads[0].happened && mappedReads[0].permissionRepairTarget == nil
              && mappedReads[1].outcome == "failed" && mappedReads[1].name == "Denied second fixture"
              && mappedReads[1].permissionRepairTarget == .filesAndFolders,
              "Repeated document-read notes attach repair only to the denied call")
        let deniedPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/pippa-permission-fixture").path
        let failure = PiFileAccessFailure.decode(tool: "list_folder", isError: true,
            result: ["details": ["pippaFileAccess": ["schema": 1, "code": "EACCES", "path": deniedPath]]])
        var folderRead = PiTurnReceipt()
        folderRead.observe(.toolStarted(id: "folder", name: "list_folder", arguments: "{}"))
        folderRead.observe(.toolEnded(id: "folder", name: "list_folder", isError: true, result: "Denied",
                                     outcome: .failed, fileAccessFailure: failure))
        let mappedFolder = PiRPCChat.actions(folderRead)?.items ?? []
        check(failure != nil && mappedFolder.count == 1 && mappedFolder[0].permissionRepairTarget == .filesAndFolders,
              "Structured runtime folder denial survives Pi receipt and app mapping to Files & Folders")
        let denied: [(String, ActionReceipt.Item, PermissionRepairTarget, String)] = [
            ("files", .init(action: "read", outcome: "failed", name: "Fixture.pdf", permissionRepair: .filesAndFolders), .filesAndFolders, "Privacy_FilesAndFolders"),
            ("drive", .init(action: "read", outcome: "failed", name: "Fixture drive", permissionRepair: .removableVolumes), .removableVolumes, "Privacy_RemovableVolume"),
            ("photos", .init(action: "read", outcome: "failed", name: "Photos", permissionRepair: .photos), .photos, "Privacy_Photos"),
            ("photo-previews", .init(action: "read", outcome: "done", name: "Photos · 3", permissionRepair: .photos), .photos, "Privacy_Photos"),
            ("mail", .init(action: "mailDraft", outcome: "failed", name: "Fixture reply", reason: "denied"), .automation, "Privacy_Automation"),
            ("calendar", .init(action: "calendarAdd", outcome: "failed", name: "Fixture appointment", reason: "denied"), .calendar, "Privacy_Calendars"),
            ("reminders", .init(action: "reminderAdd", outcome: "failed", name: "Fixture reminder", reason: "denied"), .reminders, "Privacy_Reminders")
        ]
        let completed = ActionReceipt.Item(action: "reminderAdd", outcome: "done", name: "Earlier confirmed fixture",
                                           operationID: UUID(), nativeRevision: 3)
        do {
            let source = directory.appendingPathComponent("permission-source.txt")
            try "Unchanged synthetic source".write(to: source, atomically: true, encoding: .utf8)
            let originalBytes = try Data(contentsOf: source)
            model.newConversation()
            model.attach(.files([source]), items: [source], startsFresh: false, open: true)
            let chat = model.conversations
            let fixture = PermissionRepairFixtureChat(.init(items: denied.map { $0.1 } + [completed]))
            chat.send("Use this synthetic source", chat: fixture)
            for _ in 0..<200 where chat.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
            guard !chat.isRunning, let before = chat.current, let failed = chat.failed else {
                check(false, "Controller retains the failed request"); chat.stop(); return
            }
            check(before.context?.files == [source] && before.messages.contains(where: { $0.role == .user }),
                  "Original source and user request are persisted")
            check(before.messages.flatMap { $0.actions?.items ?? [] }.contains(completed),
                  "Completed effects remain alongside the denied operations")
            let mode = model.mode.key
            var opened: [URL] = []
            PermissionSettingsSnapshotRouting.open = { opened.append($0) }
            defer { PermissionSettingsSnapshotRouting.open = nil }
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            panel.title = "Pippa permission repair fixture"
            defer { panel.orderOut(nil) }
            for (name, item, expected, anchor) in denied {
                guard let target = item.permissionRepairTarget else { check(false, "\(name) offers repair"); continue }
                let control = PermissionRepairControl(item: item, target: target, onOpen: { model.openPermissionSettings(for: $0) })
                control.openSettings()
                check(target == expected && opened.last?.absoluteString == "x-apple.systempreferences:com.apple.preference.security?" + anchor,
                      "\(name) button routes to the matching privacy pane")
                check(chat.current == before && chat.failed?.notice == failed.notice && chat.failed?.question == failed.question
                      && !chat.isRunning && fixture.calls == 1 && model.mode.key == mode,
                      "\(name) Settings visit preserves source, history, failed intent and completed effects without replay")
                let content = ActionReceiptView(receipt: .init(items: [item]),
                    onOpenPermissionSettings: { model.openPermissionSettings(for: $0) })
                let host = NSHostingView(rootView: content.padding(12).frame(width: 400, alignment: .topLeading))
                let size = host.fittingSize
                check(size.width <= 400.5 && size.height > 80 && size.height <= 400, "\(name) text and controls fit at 400 points")
                host.frame = NSRect(x: 0, y: 0, width: 400, height: ceil(size.height))
                panel.contentView = host; panel.setContentSize(host.frame.size)
                panel.center(); panel.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .milliseconds(250))
                host.layoutSubtreeIfNeeded()
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try png.write(to: directory.appendingPathComponent("permission-repair-" + name + ".png"))
                    } else { check(false, "\(name) capture exists") }
                } else { check(false, "\(name) renders") }
                if name == "photo-previews" {
                    check(item.happened && !item.isQuiet && control.explanation == T("The photo search worked, but previews need Photos access. You can change that in System Settings.", table: "Views"),
                          "Partial photo success stays visible and explains only the denied previews")
                }
            }
            let unavailable: [ActionReceipt.Item] = [
                .init(action: "read", outcome: "failed", reason: "not_found"),
                .init(action: "read", outcome: "failed", reason: "unavailable"),
                .init(action: "read", outcome: "cancelled", permissionRepair: .photos),
                .init(action: "read", outcome: "unclear", permissionRepair: .filesAndFolders),
                .init(action: "reminderAdd", outcome: "unclear", reason: "denied"),
                .init(action: "mailDraft", outcome: "done", reason: "denied"),
                .init(action: "read", outcome: "done", permissionRepair: .filesAndFolders)
            ]
            check(unavailable.allSatisfy { $0.permissionRepairTarget == nil },
                  "Missing, unavailable, cancelled, unclear and completed actions do not suggest false permission repair")
            check(opened.count == denied.count && fixture.calls == 1, "Each explicit button action opens once and never starts a new answer")
            check(try Data(contentsOf: source) == originalBytes, "Settings visits leave the source bytes unchanged")
            // Reload through the actual controller to prove the repair did not merely preserve a UI snapshot.
            chat.select(before.id)
            check(chat.current == before, "Persisted request, attachments and action history remain unchanged after reload")
        } catch { check(false, "Synthetic fixture: \(error.localizedDescription)") }
    }
}
#endif
