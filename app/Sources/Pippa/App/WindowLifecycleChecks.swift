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
        check("Pill starts off in a fresh preference domain", !Pill.shared.isShown)

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
        Pill.shared.isShown = true
        await settle()
        let pill = NSApp.windows.first { $0 is NSPanel && $0.styleMask.contains(.nonactivatingPanel) }
        check("Optional pill stays a non-key companion", pill != nil && pill?.canBecomeKey == false && pill?.canBecomeMain == false)
        foregroundCheck("Showing the pill leaves keyboard focus alone", NSApp.keyWindow === priorKey)
        if let pill, let surface = pill.contentView {
            check("Pill receives Mail file promises", NSFilePromiseReceiver.readableDraggedTypes.allSatisfy {
                surface.registeredDraggedTypes.contains(NSPasteboard.PasteboardType($0))
            })
            pill.center()
            let start = pill.frame.origin
            func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                   windowNumber: pill.windowNumber, context: nil, eventNumber: 0,
                                   clickCount: 1, pressure: 1)!
            }
            ChatWindow.shared.hide()
            surface.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 20, y: 20)))
            surface.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 60, y: 40)))
            surface.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 20, y: 20)))
            check("Dragging the pill moves its window", abs(pill.frame.minX - start.x - 40) < 1 && abs(pill.frame.minY - start.y - 20) < 1)
            check("Moving the pill does not open chat", !chat.isVisible)
            surface.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 20, y: 20)))
            surface.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 20, y: 20)))
            check("Clicking the pill still opens chat", chat.isVisible)
            surface.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 20, y: 20)))
            surface.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 100_000, y: 100_000)))
            surface.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 20, y: 20)))
            check("Moving the pill beyond an edge brings it back on screen", NSScreen.screens.contains { $0.visibleFrame.contains(pill.frame) })
            pill.setFrameOrigin(start)
        }
        check("Chat receives Mail file promises", NSFilePromiseReceiver.readableDraggedTypes.allSatisfy {
            chat.contentView?.registeredDraggedTypes.contains(NSPasteboard.PasteboardType($0)) == true
        })
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/Pippa-drop-fixture.eml") as NSURL])
        var dropped: [URL] = []
        DropReader.read(pasteboard) { dropped = $0?.items ?? [] }
        check("An existing mail file survives drop decoding", dropped.map(\.path) == ["/tmp/Pippa-drop-fixture.eml"])
        pasteboard.releaseGlobally()
        let promiseFolder = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-promises-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: promiseFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: promiseFolder) }
        var promiseResult: DropReader.Result?
        var promiseCompletions = 0
        DropReader.receivePromises([LegacyPromiseFixture()], into: promiseFolder) {
            promiseResult = $0
            promiseCompletions += 1
        }
        for _ in 0..<100 where promiseCompletions == 0 { try? await Task.sleep(for: .milliseconds(20)) }
        check("One legacy Mail promise delivers all files before completing", promiseCompletions == 1 &&
              Set(promiseResult?.items.map(\.lastPathComponent) ?? []) == Set(["first.eml", "second.eml"]))
        Pill.shared.isShown = false
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
