import AppKit
import PippaCore
import Combine

/// Menu bar: PippaMark with the overall state and a short menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let item: NSStatusItem
    private let mark = MarkNSView(size: 18, monochromeIdle: true)
    private var cancellables: Set<AnyCancellable> = []
    var openSettings: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: 26)
        super.init()
        if let button = item.button {
            mark.frame = NSRect(x: 4, y: (button.bounds.height - 18) / 2, width: 18, height: 18)
            mark.autoresizingMask = [.minYMargin, .maxYMargin]
            button.addSubview(mark)
            button.setAccessibilityLabel(model.spokenState)
            button.setAccessibilityHelp(T("Pippa menu", table: "App"))
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.item.button?.setAccessibilityLabel(self.model.spokenState)
                }
            }
            .store(in: &cancellables)
    }

    /// Screen frame of the icon, anchor for the shell when the pill is hidden.
    var anchorRect: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "Pippa · \(stateText)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let learning = model.learningText {
            let l = NSMenuItem(title: learning, action: nil, keyEquivalent: "")
            l.isEnabled = false
            menu.addItem(l)
        }
        if model.needsDownloadConsent {
            let title: String
            if let size = model.downloadSize {
                title = T("Load Pippa’s Knowledge Now (%@)", table: "App", ModelDownloadSize.gigabytes(size.remaining))
            } else {
                title = T("Load Pippa’s Knowledge Now", table: "App")
            }
            menu.addItem(MenuAction.item(title) { [weak self] in self?.model.startModelDownload() })
        } else if model.downloadStalled {
            menu.addItem(MenuAction.item(T("Try Loading Again", table: "App")) { [weak self] in self?.model.retryDownloadNow() })
        } else if case .offer(let bytes)? = PiSetupController.shared?.update {
            // New knowledge after an update; the previous one keeps working until it is loaded.
            menu.addItem(MenuAction.item(T("Load Pippa’s Knowledge Now (%@)", table: "App", ModelDownloadSize.gigabytes(bytes))) {
                PiSetupController.shared?.loadUpdate()
            })
        }
        menu.addItem(.separator())
        let hotkey = Hotkey.current
        menu.addItem(MenuAction.item(T("Ask Pippa…", table: "App"), key: hotkey.menuKey, modifiers: hotkey.menuModifiers) { [weak self] in
            self?.model.openInput()
        })
        menu.addItem(MenuAction.item(T("Look at a Folder…", table: "App")) { [weak self] in self?.model.chooseFolder() })
        menu.addItem(MenuAction.item(T("Look at Selected Mail", table: "App")) { [weak self] in self?.model.readSelectedMail() })
        if model.parked != nil {
            menu.addItem(MenuAction.item(T("Show Result", table: "App")) { [weak self] in self?.model.resumeParked() })
        }
        // The only way to earlier conversations: the chat itself has no history button (Pippa starts new conversations itself).
        let earlier = model.conversations.history.filter { $0.id != model.conversations.current?.id && $0.messageCount > 0 }
        let currentHasMessages = model.conversations.current?.messages.isEmpty == false
        if !earlier.isEmpty || currentHasMessages {
            let sub = NSMenu()
            for conversation in earlier.prefix(10) {
                sub.addItem(MenuAction.item(conversation.title) { [weak self] in
                    self?.model.selectConversation(conversation.id)
                    self?.model.openInput()
                })
            }
            if currentHasMessages {
                if !earlier.isEmpty { sub.addItem(.separator()) }
                sub.addItem(MenuAction.item(T("Delete Current Conversation…", table: "App")) { [weak self] in self?.model.deleteCurrentConversation() })
            }
            let item = NSMenuItem(title: T("Recent Conversations", table: "App"), action: nil, keyEquivalent: "")
            item.submenu = sub
            item.isEnabled = !model.isActiveWork
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let lastJob = model.lastJob ?? T("nothing yet", table: "App")
        let last = NSMenuItem(title: T("Last task: %@", table: "App", lastJob), action: nil, keyEquivalent: "")
        last.isEnabled = false
        menu.addItem(last)
        if !model.recentJobs.isEmpty {
            let sub = NSMenu()
            for r in model.recentJobs.prefix(8) {
                if !r.canUndo { sub.addItem(withTitle: r.summary, action: nil, keyEquivalent: ""); continue }
                sub.addItem(MenuAction.item(T("%@ · Undo…", table: "App", r.summary)) { [weak self] in self?.model.confirmUndo(r) })
            }
            let item = NSMenuItem(title: T("Recent Tasks", table: "App"), action: nil, keyEquivalent: "")
            item.submenu = sub
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let pillTitle = model.pillVisible ? T("Hide Pippa", table: "App") : T("Show Pippa", table: "App")
        menu.addItem(MenuAction.item(pillTitle) { [weak self] in
            guard let self else { return }
            self.model.pillVisible.toggle()
        })
        menu.addItem(MenuAction.item(T("Settings…", table: "App"), key: ",", modifiers: [.command]) { [weak self] in self?.openSettings?() })
        if Updates.available {
            menu.addItem(MenuAction.item(T("Check for Updates…", table: "App")) { Updates.shared.checkNow() })
        }
        let local = NSMenuItem(title: model.inferenceSummary, action: nil, keyEquivalent: "")
        local.isEnabled = false
        menu.addItem(local)
        menu.addItem(.separator())
        menu.addItem(MenuAction.item(T("Quit Pippa", table: "App"), key: "q", modifiers: [.command]) { NSApp.terminate(nil) })
    }

    private var stateText: String {
        switch model.markState {
        case .ruht:
            if model.modelReady { return T("Ready", table: "App") }
            return T("Still learning", table: "App")
        case .arbeitet: return T("Working…", table: "App")
        case .offen: return T("Needs you", table: "App")
        case .fehler: return T("That didn’t work", table: "App")
        }
    }
}
