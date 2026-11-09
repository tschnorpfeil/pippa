import AppKit
import SwiftUI

/// The chat window: a normal, resizable window that remembers its frame.
@MainActor
final class ChatWindow: NSObject, NSWindowDelegate {
    static let shared = ChatWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            // Leave space around a new window on smaller MacBooks. Saved user frames still take precedence.
            let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 900)
            let size = NSSize(width: min(1200, max(640, available.width - 64)),
                              height: min(800, max(460, available.height - 80)))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Pippa"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.minSize = NSSize(width: 640, height: 460)
            // One calm bar: toolbar and title in one row, no line between bar and conversation.
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
            let host = DropHostingView(rootView: ChatView(chat: .shared, setup: .shared))
            host.feedback = .chat
            window.contentView = host
            window.center()
            window.setFrameAutosaveName("PippaChat")
            self.window = window
        }
        NSApp.unhide(nil)
        NSApp.activate()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        ChatModel.shared.unseen = nil
    }

    var isKey: Bool { window?.isKeyWindow == true }
    func hide() { window?.orderOut(nil) }
    func windowDidBecomeKey(_ notification: Notification) { ChatModel.shared.unseen = nil }
}

/// What the shortcut, the island, the menu and the Dock icon do.
@MainActor
enum AppActions {
    /// Opens the chat; the app that was in front becomes a chip the person can keep or remove.
    static func callPippa(front: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) {
        noteFrontApp(front)
        ChatWindow.shared.show()
    }

    /// Remembers the app in front for the next question ("this mail"), unless a question is already being written.
    static func noteFrontApp(_ front: NSRunningApplication?) {
        if let front, front.bundleIdentifier != Bundle.main.bundleIdentifier, let name = front.localizedName,
           ChatModel.shared.draft.isEmpty {
            ChatModel.shared.frontApp = name
        }
    }

    static func attach(_ urls: [URL]) {
        ChatModel.shared.attachments += MailDropIdentity.attachments(urls, excluding: ChatModel.shared.attachments)
        ChatWindow.shared.show()
    }
}
