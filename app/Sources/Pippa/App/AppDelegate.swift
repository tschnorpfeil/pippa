import Combine
import AppKit
import PippaCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    /// The menu bar mark: still and single-colour at rest, turning while Pippa works.
    private let menuMark = MarkNSView(size: 18, monochromeIdle: true)
    /// An answer nobody has looked at yet, after the island's "Your answer is ready" has gone.
    private let unreadDot = NSView()
    private var markWatch: AnyCancellable?
    private var unreadWatch: AnyCancellable?
    private var shuttingDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SingleInstance.acquire() else {
            SingleInstance.signalRunningInstance()
            exit(0)
        }
        SingleInstance.listen { ChatWindow.shared.show() }
        DiagnosticsLog.shared.event("start", ["version": AppVersion.label, "macos": ProcessInfo.processInfo.operatingSystemVersionString])
        NSApp.mainMenu = mainMenu()
        statusItem = makeStatusItem()
        unreadWatch = Publishers.CombineLatest(ChatModel.shared.$unseen, ChatModel.shared.$unseenIDs).sink { [weak self] unseen, conversations in
            // A quiet Dock badge replaces focus stealing when a background answer is ready.
            switch unseen {
            case .failed: NSApp.dockTile.badgeLabel = "!"
            case .answer: NSApp.dockTile.badgeLabel = "•"
            case nil: NSApp.dockTile.badgeLabel = conversations.isEmpty ? nil : "•"
            }
            self?.unreadDot.isHidden = unseen == nil && conversations.isEmpty
        }
        // The shortcut opens the island's question field; with the island switched off, the chat.
        HotkeyCenter.shared.onPress = { Island.shared.isShown ? Island.shared.ask() : AppActions.callPippa() }
        HotkeyCenter.shared.apply(Hotkey.current)
        SetupModel.shared.begin()
        Island.shared.start()
        Updates.shared.start()
        // Ordinary launches show the chat; respect a hidden launch requested by macOS.
        if !NSApp.isHidden { ChatWindow.shared.show() }
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            menuMark.frame = NSRect(x: (button.bounds.width - 18) / 2, y: (button.bounds.height - 18) / 2, width: 18, height: 18)
            menuMark.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            button.addSubview(menuMark)
            unreadDot.frame = NSRect(x: menuMark.frame.maxX - 4, y: menuMark.frame.maxY - 6, width: 6, height: 6)
            unreadDot.autoresizingMask = menuMark.autoresizingMask
            unreadDot.wantsLayer = true
            unreadDot.layer?.cornerRadius = 3
            unreadDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            unreadDot.isHidden = true
            button.addSubview(unreadDot)
            button.setAccessibilityLabel("Pippa")
            // Left click opens the island; right click (or control-click) shows the menu.
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            Island.shared.statusButton = button
        }
        markWatch = Island.shared.$status.sink { [weak self] status in
            self?.menuMark.setState(status.markState)
            self?.statusItem?.button?.setAccessibilityValue(status.label)
        }
        let menu = NSMenu()
        menu.addItem(MenuAction.item(T("Ask Pippa", table: "App")) { AppActions.callPippa() })
        menu.addItem(MenuAction.item(T("New Conversation", table: "App")) { ChatModel.shared.newConversation(); ChatWindow.shared.show() })
        menu.addItem(.separator())
        let island = MenuAction.item(T("Pippa Island", table: "Island")) { Island.shared.isShown.toggle() }
        menu.addItem(island)
        menu.addItem(MenuAction.item(T("Settings…", table: "App")) { SettingsWindow.shared.show() })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item(T("Quit Pippa", table: "App")) { NSApp.terminate(nil) })
        menu.delegate = MenuAction.stateUpdater { island.state = Island.shared.isShown ? .on : .off }
        statusMenu = menu
        return item
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if Island.shared.isShown, !wantsMenu {
            Island.shared.toggle(fromStatusItem: true)
            return
        }
        // Attached only for this click, so the next left click reaches the island again.
        statusItem?.menu = statusMenu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    /// Standard Mac app menus, including responder-chain editing, hiding, and window management.
    func mainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        func edit(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        submenu("Pippa", [
            MenuAction.item(T("About Pippa", table: "App")) { NSApp.orderFrontStandardAboutPanel(nil) },
            .separator(),
            MenuAction.item(T("Settings…", table: "App"), key: ",", modifiers: [.command]) { SettingsWindow.shared.show() },
            MenuAction.item(T("Check for Updates…", table: "App")) { Updates.shared.checkNow() },
            .separator(),
            edit(T("Hide Pippa", table: "App"), #selector(NSApplication.hide(_:)), "h"),
            edit(T("Hide Others", table: "App"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            edit(T("Show All", table: "App"), #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            MenuAction.item(T("Quit Pippa", table: "App"), key: "q", modifiers: [.command]) { NSApp.terminate(nil) },
        ])
        let services = NSMenu(title: T("Services", table: "App"))
        let servicesItem = NSMenuItem(title: services.title, action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        main.items.first?.submenu?.insertItem(servicesItem, at: 5)
        main.items.first?.submenu?.insertItem(.separator(), at: 6)
        NSApp.servicesMenu = services
        submenu(T("File", table: "App"), [
            MenuAction.item(T("New Conversation", table: "App"), key: "n", modifiers: [.command]) { ChatModel.shared.newConversation(); ChatWindow.shared.show() },
            edit(T("Close Window", table: "App"), #selector(NSWindow.performClose(_:)), "w"),
        ])
        submenu(T("Edit", table: "App"), [
            edit(T("Undo", table: "App"), Selector(("undo:")), "z"),
            edit(T("Redo", table: "App"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            edit(T("Cut", table: "App"), #selector(NSText.cut(_:)), "x"),
            edit(T("Copy", table: "App"), #selector(NSText.copy(_:)), "c"),
            edit(T("Paste", table: "App"), #selector(NSText.paste(_:)), "v"),
            edit(T("Select All", table: "App"), #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu(T("Window", table: "App"), [
            MenuAction.item(T("Show Pippa", table: "App")) { ChatWindow.shared.show() },
            .separator(),
            edit(T("Minimize", table: "App"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            edit(T("Zoom", table: "App"), #selector(NSWindow.performZoom(_:)), ""),
            .separator(),
            edit(T("Bring All to Front", table: "App"), #selector(NSApplication.arrangeInFront(_:)), ""),
        ])
        NSApp.windowsMenu = main.items.last?.submenu
        return main
    }

    /// Stop Pi and the local model cleanly, then quit; at most 5 seconds.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !shuttingDown else { return .terminateLater }
        shuttingDown = true
        let server = PiSession.shared.ownedServer
        let reply = TerminateReply()
        Task { @MainActor in await PiSession.shared.shutdown() }
        Task.detached {
            await server?.stop()
            reply.send()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { reply.send() }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Opening Pippa from the Dock must not attach the previously active app to the next question.
        ChatWindow.shared.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// "Open with Pippa" and files dropped on the app icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppActions.attach(urls.filter(\.isFileURL))
    }
}

/// Menu items with closures.
@MainActor
enum MenuAction {
    private final class Target: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func run() { action() }
    }
    private final class Updater: NSObject, NSMenuDelegate {
        let update: () -> Void
        init(_ update: @escaping () -> Void) { self.update = update }
        func menuWillOpen(_ menu: NSMenu) { update() }
    }
    private static var retained: [NSObject] = []

    static func item(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [], _ action: @escaping () -> Void) -> NSMenuItem {
        let target = Target(action)
        retained.append(target)
        let item = NSMenuItem(title: title, action: #selector(Target.run), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    static func stateUpdater(_ update: @escaping () -> Void) -> NSMenuDelegate {
        let updater = Updater(update)
        retained.append(updater)
        return updater
    }
}

/// Only one Pippa at a time: a lock file; a second instance wakes the first and quits.
enum SingleInstance {
    private static let notification = Notification.Name("app.pippa.activate")
    nonisolated(unsafe) private static var lockFD: Int32 = -1

    static func acquire() -> Bool {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pippa", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent("pippa.lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return false }
        lockFD = fd
        return true
    }

    static func signalRunningInstance() {
        DistributedNotificationCenter.default().postNotificationName(notification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    @MainActor
    static func listen(_ action: @escaping @MainActor () -> Void) {
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
    }
}

/// `NSApp.reply(toApplicationShouldTerminate:)` once, whoever comes first.
private final class TerminateReply: @unchecked Sendable {
    private var sent = false
    private let lock = NSLock()
    func send() {
        guard lock.withLock({ defer { sent = true }; return !sent }) else { return }
        RunLoop.main.perform(inModes: [.common, .modalPanel]) {
            MainActor.assumeIsolated { NSApp.reply(toApplicationShouldTerminate: true) }
        }
    }
}
