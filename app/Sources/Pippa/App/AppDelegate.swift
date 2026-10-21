import AppKit
import PippaCore
@preconcurrency import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let model = AppModel.shared
    private var shell: ShellController?
    private var toasts: ToastController?
    private var status: StatusItemController?
    private var settings: SettingsWindowController?
    private var morningOverview: MorningBriefingWindowController?
    private let services = ServiceProvider()
    private var shuttingDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard SingleInstance.acquire() else {
            SingleInstance.signalRunningInstance()
            exit(0)
        }
        if DevSnapshot.directory == nil {
            SingleInstance.listen { [weak self] in self?.model.openInput() }
        }

        FrontmostTracker.shared.start()
        DisplayFont.register()
        DiagnosticsLog.shared.event("start", ["version": AppVersion.label, "macos": ProcessInfo.processInfo.operatingSystemVersionString])
        let settings = SettingsWindowController(model: model)
        self.settings = settings

        let morningOverview = MorningBriefingWindowController(controller: model.morningBriefing)
        self.morningOverview = morningOverview

        let status = StatusItemController(model: model)
        status.openSettings = { settings.show() }
        status.openMorningOverview = { morningOverview.show() }
        self.status = status

        let shell = ShellController(model: model)
        shell.statusAnchor = { [weak status] in status?.anchorRect }
        model.shell = shell
        self.shell = shell

        let toasts = ToastController(model: model)
        model.toasts = toasts
        self.toasts = toasts

        NSApp.mainMenu = mainMenu(settings: settings)
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()

        HotkeyCenter.shared.onPress = { [weak self] in
            // First record which app was in front (Mail → call in Mail), before Pippa itself comes to the front.
            let front = FrontmostTracker.shared.capture()
            self?.shell?.triggerTime = CACurrentMediaTime()
            self?.model.call(.shortcut, front: front)
        }
        // Scripted QA snapshots run beside the installed Pippa: never take its global shortcut.
        if DevSnapshot.directory == nil { HotkeyCenter.shared.apply(Hotkey.current) }

        shell.showInitially()
        if DevSnapshot.directory != nil {
            DevSnapshot.run(model: model, shell: shell)
            return
        }
        model.start()
        UNUserNotificationCenter.current().delegate = self
        Updates.shared.start()
        Updates.shared.announceIfUpdated(toasts)
        // Warm up text recognition in the background, shortly after launch.
        let engine = model.engine
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Task(priority: .background) { await engine.warmUp() }
        }
    }

    /// Invisible main menu: without it, in a menu bar app neither ⌘C/⌘V/⌘A/⌘Z/⌘X
    /// in text fields nor ⌘N, ⌘W and ⌘, work.
    private func mainMenu(settings: SettingsWindowController) -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        submenu("Pippa", [
            MenuAction.item(T("Settings…", table: "App"), key: ",", modifiers: [.command]) { settings.show() },
            MenuAction.item(T("Check for Updates…", table: "App")) { Updates.shared.checkNow() },
            .separator(),
            MenuAction.item(T("Quit Pippa", table: "App"), key: "q", modifiers: [.command]) { NSApp.terminate(nil) },
        ])
        submenu(T("File", table: "App"), [
            MenuAction.item(T("New Conversation", table: "App"), key: "n", modifiers: [.command]) { [weak self] in self?.model.newConversation() },
            MenuAction.item(T("Show Attachments", table: "Shelf"), key: "a", modifiers: [.command, .shift]) { [weak self] in
                if self?.model.shell?.focusAttachments() != true { NSSound.beep() }
            },
            MenuAction.item(T("Close Window", table: "App"), key: "w", modifiers: [.command]) { [weak self] in
                guard let self else { return }
                if let key = NSApp.keyWindow, key !== self.shell?.panel { key.performClose(nil) } else { self.model.collapse() }
            },
        ])
        // Edit commands go to the field with focus (target nil = responder chain).
        func edit(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        // The main menu stays invisible (menu bar app); "Undo" therefore shares its key with the Undo button.
        submenu(T("Edit", table: "App"), [
            edit(T("Undo", table: "App"), Selector(("undo:")), "z"),
            edit(T("Redo", table: "App"), Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            edit(T("Cut", table: "App"), #selector(NSText.cut(_:)), "x"),
            edit(T("Copy", table: "App"), #selector(NSText.copy(_:)), "c"),
            // Files and pictures on the clipboard become attachments; everything else pastes as text.
            MenuAction.item(T("Paste", table: "App"), key: "v", modifiers: [.command]) { [weak self] in
                if self?.shell?.pasteAsAttachment() == true { return }
                NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
            },
            edit(T("Select All", table: "App"), #selector(NSText.selectAll(_:)), "a"),
        ])
        submenu(T("Help", table: "App"), [
            MenuAction.item(T("Report a Problem…", table: "App"), key: "", modifiers: []) { ProblemReport.open() },
        ])
        return main
    }

    /// Quit the engine cleanly (local server), only then the app.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !shuttingDown else { return .terminateLater }
        shuttingDown = true
        let engine = model.engine
        // Take along only the server actor: PiRPCChat lives on the MainActor, which is blocked here until the reply.
        let piServer = PiRPCChat.shared.ownedServer
        // Reply exactly once: after a clean shutdown, or after 5 s at the latest. Saving the prompt cache of a 16k
        // conversation takes about a second; a slow disk, a stuck download or a hanging Apple Events check must not
        // hold the quit. The timer runs on the main run loop, not in Swift's shared pool: blocked work there cannot
        // delay it, and nothing waits for a shutdown that never returns (a task group would).
        let reply = TerminateReply()
        Task.detached {
            await engine.shutdown(); await piServer?.stopSavingConversation()
            reply.send()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { reply.send() }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.openInput()
        return false
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        guard response.notification.request.identifier == "pippa.morning-briefing",
              response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
            completionHandler(); return
        }
        Task { @MainActor [weak self] in
            self?.morningOverview?.show()
        }
        completionHandler()
    }

    /// "Open with Pippa" / files dropped onto the app icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        model.receive(.files(files), items: files)
    }
}

/// Only one Pippa at a time: lock file; a second instance wakes the first and quits.
enum SingleInstance {
    private static let notification = Notification.Name("app.pippa.activate")
    nonisolated(unsafe) private static var lockFD: Int32 = -1

    static func acquire() -> Bool {
        #if DEBUG
        // Synthetic controller fixtures have isolated storage and must not activate or take the installed app's lock.
        if ProcessInfo.processInfo.environment["PIPPA_SNAPSHOT"]?.isEmpty == false { return true }
        #endif
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pippa", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("pippa.lock").path
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
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

/// Services menu entry "Look at with Pippa" (NSMessage `pippaService` in Info.plist).
final class ServiceProvider: NSObject {
    @MainActor @objc func pippaService(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        DropReader.read(pboard) { result in
            guard let result else { return }
            AppModel.shared.receive(result.payload, items: result.items)
        }
    }
}

/// `NSApp.reply(toApplicationShouldTerminate:)` once, whoever comes first.
private final class TerminateReply: @unchecked Sendable {
    private var sent = false
    private let lock = NSLock()
    func send() {
        guard lock.withLock({ defer { sent = true }; return !sent }) else { return }
        // Via the run loop instead of the main queue: this way the reply also arrives when quitting
        // was triggered from a running MainActor task.
        RunLoop.main.perform(inModes: [.common, .modalPanel]) {
            MainActor.assumeIsolated { NSApp.reply(toApplicationShouldTerminate: true) }
        }
    }
}
