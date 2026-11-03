import AppKit

/// Focused AppKit acceptance checks in a cloned app with its own bundle ID and temporary HOME.
/// No setup, updater, single-instance notifications, model server, or account login runs here.
@MainActor
enum WindowLifecycleChecks {
    static func run() async -> Int32 {
        var failures = 0
        var skipped = 0
        let foregroundAvailable = NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow"
        func check(_ name: String, _ result: Bool) {
            print("\(result ? "✓" : "✗") \(name)")
            if !result { failures += 1 }
        }
        func foregroundCheck(_ name: String, _ result: Bool) {
            if foregroundAvailable { check(name, result) }
            else { skipped += 1; print("– \(name): foreground check skipped (macOS reports loginwindow)") }
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
        guard let chat = NSApp.windows.first(where: { $0.title == "Pippa" && !($0 is NSPanel) }) else {
            print("✗ Chat window missing"); return 1
        }
        check("Opening the app presents the chat", chat.isVisible && !chat.isMiniaturized)
        ChatModel.shared.draft = "Unsent lifecycle fixture"
        ChatModel.shared.frontApp = "Retained context fixture"
        chat.miniaturize(nil)
        await settle()
        check("Chat can be minimized", chat.isMiniaturized)
        _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
        await settle()
        check("Dock reopen restores a minimized chat", chat.isVisible && !chat.isMiniaturized)
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
