import AppKit
import PiRPC
import WebKit

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
        if let first = WKBrowserSession.makeOnline(), let next = WKBrowserSession.makeOnline() {
            let firstStore = first.webView.configuration.websiteDataStore
            let nextStore = next.webView.configuration.websiteDataStore
            let cookie = HTTPCookie(properties: [.domain: "fixture.invalid", .path: "/", .name: "isolated", .value: "first"])!
            await firstStore.httpCookieStore.setCookie(cookie)
            let firstCookies = await firstStore.httpCookieStore.allCookies()
            let nextCookies = await nextStore.httpCookieStore.allCookies()
            check("Separate online answers have separate, nonpersistent WebKit cookies",
                  !firstStore.isPersistent && !nextStore.isPersistent && firstCookies.contains { $0.name == "isolated" }
                  && !nextCookies.contains { $0.name == "isolated" })
            let protectionSpace = URLProtectionSpace(host: "fixture.invalid", port: 443, protocol: "https", realm: "fixture",
                                                     authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
            let challenge = URLAuthenticationChallenge(protectionSpace: protectionSpace, proposedCredential: nil,
                                                       previousFailureCount: 0, failureResponse: nil, error: nil,
                                                       sender: FixtureChallengeSender())
            let (result, credential) = await first.webView(first.webView, didReceive: challenge)
            check("Online WebKit declines HTTP Basic authentication", result == .cancelAuthenticationChallenge && credential == nil)
        } else {
            print("– This WebKit cannot disable managed sign-in, so online browsing is unavailable")
            skipped += 1
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
        // The default shortcut is ⌥ Space, and a real ⌥ Space press reaches Pippa.
        check("The default shortcut in a fresh preference domain is ⌥ Space", Hotkey.current == .optionSpace)
        var pressed = false
        let previous = HotkeyCenter.shared.onPress
        HotkeyCenter.shared.onPress = { pressed = true }
        let registered = HotkeyCenter.shared.apply(Hotkey.current)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(Hotkey.optionSpace.keyCode ?? 0), keyDown: down)
            event?.flags = .maskAlternate
            event?.post(tap: .cghidEventTap)
        }
        for _ in 0..<10 where !pressed { await settle() }
        HotkeyCenter.shared.onPress = previous
        print("Shortcut: registered=\(registered), posting allowed=\(CGPreflightPostEventAccess()), pressed=\(pressed)")
        check("⌥ Space registers with macOS", registered)
        // Posting a key needs the Accessibility grant, which this cloned app does not have.
        if CGPreflightPostEventAccess() { check("A real ⌥ Space press calls Pippa", pressed) }

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

        // One live mark at a time while she works: beside a notch the island carries it and the menu bar symbol rests;
        // under the symbol, or with the island off, the symbol shows it. Switching the island must update the symbol.
        ChatModel.shared.showSample([], current: nil, answering: true)
        Island.shared.isShown = false
        await settle()
        check("Island off while she works: the menu bar symbol shows it", Island.shared.menuMark == .arbeitet)
        Island.shared.isShown = true
        await settle()
        let notch = Island.shared.presenter?.placement?.isNotch == true
        check("Island on while she works: \(notch ? "the symbol rests, the island beside the notch shows it" : "the symbol shows it")",
              Island.shared.menuMark == (notch ? .ruht : .arbeitet) && !Island.shared.menuWriting)
        ChatModel.shared.showSample([], current: nil, answering: true, writing: true)
        Island.shared.isShown = false
        await settle()
        check("Island off while she writes: the menu bar symbol shows Scribble", Island.shared.menuWriting)
        Island.shared.isShown = true
        await settle()
        check("Island on while she writes: \(notch ? "the symbol rests, the island beside the notch writes" : "the menu bar symbol shows Scribble")",
              Island.shared.menuWriting == !notch)
        check("⌘H leaves Pippa Island on screen", Island.shared.presenter?.panel.canHide == false)
        ChatModel.shared.showSample([], current: nil, answering: false)
        Island.shared.refresh()

        SettingsWindow.shared.show()
        await settle()
        let settings = SettingsWindow.shared.window
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
            if foregroundAvailable {
                await checkIslandQuestionKeys(island, check: check)
            }
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
        let first = LegacyPromiseFixture()
        first.files = ["same.eml": "<a@pippa.test>"]
        let second = LegacyPromiseFixture()
        second.files = ["same.eml": "<b@pippa.test>"]
        promiseCompletions = 0
        promiseResult = nil
        DropReader.receivePromises([first, second], into: promiseFolder) {
            promiseResult = $0
            promiseCompletions += 1
        }
        for _ in 0..<100 where promiseCompletions == 0 { try? await Task.sleep(for: .milliseconds(20)) }
        let delivered = MailDropIdentity.attachments(promiseResult?.items ?? [], excluding: [])
        check("Two promises with the same filename deliver both distinct messages", promiseCompletions == 1 &&
              Set(delivered.compactMap(MailDropIdentity.key(for:))) == Set(["<a@pippa.test>", "<b@pippa.test>"]))
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

    private static func checkIslandQuestionKeys(_ panel: NSPanel, check: (String, Bool) -> Void) async {
        let chat = ChatModel.shared
        let approvals = Approvals.shared
        let answer = ChatMessage(role: .assistant, text: "Synthetic answer")
        let a = Conversation(id: "A", title: "A", updated: Date(), messages: [answer])
        let b = Conversation(id: "B", title: "B", updated: Date().addingTimeInterval(-3600), messages: [])
        chat.draft = "Unsent island fixture"
        func settle() async { try? await Task.sleep(for: .milliseconds(350)) }
        func ask(_ id: String) -> Task<PiUIResponse, Never> {
            Task { await approvals.ask(.init(id: id, method: "confirm", title: id, message: "Synthetic question")) }
        }
        func key(_ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = [], repeating: Bool = false) {
            NSApp.postEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                            context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                            isARepeat: repeating, keyCode: code)!, atStart: false)
        }

        SetupModel.shared.showForSnapshot(.ready(adoptedFrom: nil))
        chat.showSample([a, b], current: b.id, answering: false)
        Island.shared.ask(front: nil)
        Island.shared.showForSnapshot(Island.shared.status, fresh: answer.id)
        await settle()
        key(36, "\r", modifiers: .command)
        await settle()
        check("Command-Return from a result opens its conversation with the draft",
              chat.currentID == a.id && chat.draft == "Unsent island fixture" && !Island.shared.isOpen)
        Island.shared.close()
        await settle()

        chat.showSample([a, b], current: a.id, answering: true)
        chat.select(b.id)
        let first = ask("first")
        await settle()
        panel.makeKey()
        key(36, "\r", modifiers: .command)
        await settle()
        check("Command-Return from a question opens its conversation with the draft",
              chat.currentID == a.id && chat.draft == "Unsent island fixture" && !Island.shared.isOpen)
        approvals.cancelAll()
        _ = await first.value
        await settle()

        let aQuestion = ask("escape-A")
        await settle()
        let bQuestion = ask("escape-B")
        await settle()
        panel.makeKey()
        key(53, "\u{1b}")
        await settle()
        check("Escape declines the visible question", approvals.questions.map(\.id) == ["escape-B"])
        key(53, "\u{1b}", repeating: true)
        await settle()
        check("Held Escape leaves the next question waiting", approvals.questions.map(\.id) == ["escape-B"])
        key(53, "\u{1b}")
        await settle()
        check("A new Escape declines the next question", approvals.questions.isEmpty)
        approvals.cancelAll()
        let responses = [await aQuestion.value, await bQuestion.value]
        check("Both questions receive a deliberate decline", responses == [.confirmed(false), .confirmed(false)])
        chat.showSample([], current: nil, answering: false)
    }
}

/// Emulates a legacy drag containing several files on one pasteboard item. Names appear only when requested.
private final class LegacyPromiseFixture: NSFilePromiseReceiver {
    var files = ["first.eml": "<first@pippa.test>", "second.eml": "<second@pippa.test>"]
    private var names: [String] = []
    override var fileNames: [String] { names }

    override func receivePromisedFiles(atDestination destinationDir: URL, options: [AnyHashable: Any] = [:],
                                       operationQueue: OperationQueue, reader: @escaping (URL, Error?) -> Void) {
        names = Array(files.keys)
        let callback = PromiseFixtureCallback(reader)
        for (name, id) in files {
            let url = destinationDir.appendingPathComponent(name)
            let data = Data("Message-ID: \(id)\r\n\r\nMail drop fixture".utf8)
            operationQueue.addOperation {
                do { try data.write(to: url, options: .withoutOverwriting); callback.read(url, nil) }
                catch { callback.read(url, error) }
            }
        }
    }
}

private final class PromiseFixtureCallback: @unchecked Sendable {
    let read: (URL, Error?) -> Void
    init(_ read: @escaping (URL, Error?) -> Void) { self.read = read }
}


private final class FixtureChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
