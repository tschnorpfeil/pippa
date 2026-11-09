import AppKit

/// Focused AppKit acceptance checks in a cloned app with its own bundle ID and temporary HOME.
/// No setup, updater, single-instance notifications, model server, or account login runs here.
@MainActor
enum WindowLifecycleChecks {
    static func run() async -> Int32 {
        var failures = 0
        var skipped = 0
        var foregroundAvailable = false
        func check(_ name: String, _ result: Bool) {
            print("\(result ? "✓" : "✗") \(name)")
            if !result { failures += 1 }
        }
        func foregroundCheck(_ name: String, _ result: Bool) {
            if foregroundAvailable { check(name, result) }
            else { skipped += 1; print("– \(name): foreground check skipped (isolated app is not active)") }
        }
        func settle() async { try? await Task.sleep(for: .milliseconds(220)) }
        for _ in 0..<10 where !NSRunningApplication.current.isFinishedLaunching { await settle() }
        print("Launch: active=\(NSApp.isActive), finished=\(NSRunningApplication.current.isFinishedLaunching), front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
        let delegate = AppDelegate()
        NSApp.mainMenu = delegate.mainMenu()
        check("Regular app policy enables Dock and Command-Tab", NSApp.activationPolicy() == .regular)
        check("Bundle is a normal app, not a UI agent", Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool != true)
        check("Window and Services menus belong to the application", NSApp.windowsMenu != nil && NSApp.servicesMenu != nil)
        check("Standard Hide action is in the app menu", NSApp.mainMenu?.items.first?.submenu?.items.contains { $0.action == #selector(NSApplication.hide(_:)) } == true)
        check("Closing the last window does not quit", !delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        check("Pippa Island starts on in a fresh preference domain", Island.shared.isShown)

        ChatWindow.shared.show()
        await settle()
        // LaunchServices can leave an isolated command-line test inactive while another app owns the desktop.
        // Visibility, draft retention, mouse handling and drop decoding still run; focus assertions need activation.
        foregroundAvailable = NSApp.isActive
        guard let chat = NSApp.windows.first(where: { $0.title == "Pippa" && !($0 is NSPanel) }) else {
            print("✗ Chat window missing"); return 1
        }
        check("Opening the app presents the chat", chat.isVisible && !chat.isMiniaturized)
        ChatModel.shared.draft = "Unsent lifecycle fixture"
        ChatModel.shared.frontApp = "Retained context fixture"
        await settle()
        chat.miniaturize(nil)
        await settle()
        check("Chat can be minimized", chat.isMiniaturized)
        _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
        await settle()
        check("Dock reopen restores a minimized chat", chat.isVisible && !chat.isMiniaturized)
        print("Reopen: draft=\(ChatModel.shared.draft.debugDescription), context=\(ChatModel.shared.frontApp ?? "nil"), key=\(NSApp.keyWindow?.title ?? "nil")")
        check("Reopen preserves draft and context", ChatModel.shared.draft == "Unsent lifecycle fixture" && ChatModel.shared.frontApp == "Retained context fixture")
        chat.performClose(nil)
        await settle()
        check("Close dismisses the chat window", !chat.isVisible)
        _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        await settle()
        check("Dock reopen restores a closed chat", chat.isVisible)

        SettingsWindow.shared.show()
        await settle()
        let settings = NSApp.windows.first { $0.title == T("Pippa Settings", table: "App") }
        print("Settings: active=\(NSApp.isActive), key=\(NSApp.keyWindow?.title ?? "nil"), settings=\(settings?.isKeyWindow ?? false)")
        foregroundCheck("Settings comes to the front", settings != nil && settings?.isKeyWindow == true)
        settings?.miniaturize(nil)
        await settle()
        SettingsWindow.shared.show()
        await settle()
        check("Settings reopening restores its minimized window", settings?.isVisible == true && settings?.isMiniaturized == false)
        ChatModel.shared.unseen = .answer
        chat.makeKeyAndOrderFront(nil)
        await settle()
        foregroundCheck("Returning to chat clears its unread signal", ChatModel.shared.unseen == nil)

        let priorKey = NSApp.keyWindow
        Island.shared.start()
        await settle()
        let island = Island.shared.presenter?.panel
        check("Pippa Island at rest or as a wing stays a non-key companion",
              island != nil && island?.canBecomeKey == false && island?.canBecomeMain == false)
        foregroundCheck("Showing Pippa Island leaves keyboard focus alone", NSApp.keyWindow === priorKey)
        if let island, let view = Island.shared.presenter?.view {
            check("Pippa Island receives Mail file promises on its wing and its panel", NSFilePromiseReceiver.readableDraggedTypes.allSatisfy {
                view.compact.registeredDraggedTypes.contains(NSPasteboard.PasteboardType($0))
                    && view.panel.registeredDraggedTypes.contains(NSPasteboard.PasteboardType($0))
            })
            ChatWindow.shared.hide()
            Island.shared.reveal()
            await settle()
            check("A question opens Pippa Island by itself", Island.shared.isOpen && island.isVisible)
            foregroundCheck("A question does not take the keyboard", !island.isKeyWindow)
            Island.shared.close()
            await settle()
            view.compact.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                            windowNumber: island.windowNumber, context: nil, eventNumber: 0,
                                                            clickCount: 1, pressure: 1)!)
            await settle()
            check("Clicking the wing opens Pippa Island, not the chat", Island.shared.isOpen && !chat.isVisible)
            check("Only the open island with its question field can become key", island.canBecomeKey)
            Island.shared.close()
            await settle()
            check("Closing Pippa Island makes it a non-key companion again", !island.canBecomeKey && !island.isKeyWindow)
            Island.shared.ask(front: nil)
            await settle()
            check("The shortcut opens Pippa Island for a question", Island.shared.isOpen && Island.shared.focusToken > 0)
            foregroundCheck("The question field takes the keyboard", island.isKeyWindow)
            Island.shared.close()
            await settle()
            check("Closing hands the keyboard back", !island.isKeyWindow)
            ChatWindow.shared.show()
            await settle()
        }
        check("Chat receives Mail file promises", NSFilePromiseReceiver.readableDraggedTypes.allSatisfy {
            chat.contentView?.registeredDraggedTypes.contains(NSPasteboard.PasteboardType($0)) == true
        })
        let pasteboard = NSPasteboard.withUniqueName()
        let mailFile = FileManager.default.temporaryDirectory.appendingPathComponent("Pippa-drop-" + UUID().uuidString + ".eml")
        try? Data("Message-ID: <fixture@pippa.test>\r\n\r\nFixture".utf8).write(to: mailFile)
        defer { try? FileManager.default.removeItem(at: mailFile) }
        pasteboard.writeObjects([mailFile as NSURL])
        var dropped: [URL] = []
        DropReader.read(pasteboard) { dropped = $0?.items ?? [] }
        check("An existing mail file survives drop decoding", dropped == [mailFile])
        pasteboard.releaseGlobally()
        let promiseFolder = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-promises-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: promiseFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: promiseFolder) }
        let duplicate = promiseFolder.appendingPathComponent("same-message.eml")
        let distinct = promiseFolder.appendingPathComponent("different-message.eml")
        try? Data("message-id: <fixture@pippa.test>\nSubject: Same message\n\nAlternate serialization".utf8).write(to: duplicate)
        try? Data("Message-ID: <other@pippa.test>\nSubject: Same message\n\nDifferent message".utf8).write(to: distinct)
        let filtered = MailDropIdentity.attachments([duplicate, distinct, promiseFolder.appendingPathComponent("missing.eml")], excluding: [mailFile])
        check("Mail drops reject temporary placeholders and duplicate Message-IDs, preserving distinct messages", filtered == [distinct])
        var promiseResult: DropReader.Result?
        var promiseCompletions = 0
        DropReader.receivePromises([LegacyPromiseFixture()], into: promiseFolder) {
            promiseResult = $0
            promiseCompletions += 1
        }
        for _ in 0..<100 where promiseCompletions == 0 { try? await Task.sleep(for: .milliseconds(20)) }
        check("One legacy Mail promise delivers all files before completing", promiseCompletions == 1 &&
              Set(promiseResult?.items.map(\.lastPathComponent) ?? []) == Set(["first.eml", "second.eml"]))
        Island.shared.isShown = false
        await settle()
        check("Switching Pippa Island off removes it", Island.shared.presenter?.panel.isVisible != true)
        NSApp.hide(nil)
        await settle()
        check("Command-H can hide Pippa", NSApp.isHidden)
        ChatWindow.shared.show()
        await settle()
        check("Opening Pippa unhides it and restores chat", !NSApp.isHidden && chat.isVisible && !chat.isMiniaturized)
        if skipped > 0 { print("\(skipped) foreground checks require an unlocked interactive desktop.") }
        print(failures == 0 ? "Window lifecycle checks passed." : "Window lifecycle checks failed.")
        return failures == 0 ? 0 : 1
    }
}

/// Emulates a legacy drag containing several files on one pasteboard item. Names appear only when requested.
private final class LegacyPromiseFixture: NSFilePromiseReceiver {
    private var names: [String] = []
    override var fileNames: [String] { names }

    override func receivePromisedFiles(atDestination destinationDir: URL, options: [AnyHashable: Any] = [:],
                                       operationQueue: OperationQueue, reader: @escaping (URL, Error?) -> Void) {
        names = ["first.eml", "second.eml"]
        let callback = PromiseFixtureCallback(reader)
        for name in names {
            let url = destinationDir.appendingPathComponent(name)
            operationQueue.addOperation {
                do { try Data("Subject: Fixture\n\nMail drop fixture".utf8).write(to: url); callback.read(url, nil) }
                catch { callback.read(url, error) }
            }
        }
    }
}

private final class PromiseFixtureCallback: @unchecked Sendable {
    let read: (URL, Error?) -> Void
    init(_ read: @escaping (URL, Error?) -> Void) { self.read = read }
}
