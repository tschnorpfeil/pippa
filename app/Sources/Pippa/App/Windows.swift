import AppKit
import Combine
import PippaCore
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

/// The pill: Pippa's living mark and one short line, floating at the edge of the screen. It opens the chat, takes
/// dropped files and says what Pippa is doing ("Reading Lease.pdf"), and that an answer is ready.
@MainActor
final class Pill: ObservableObject {
    static let shared = Pill()
    private var panel: NSPanel?
    @Published var isShown = UserDefaults.standard.object(forKey: "showsPill") as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(isShown, forKey: "showsPill")
            isShown ? show() : panel?.orderOut(nil)
        }
    }

    func show() {
        guard isShown else { return }
        if panel == nil {
            let size = NSSize(width: 140, height: 64)
            let panel = PillPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.nonactivatingPanel, .borderless],
                                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.isMovableByWindowBackground = true
            // Only fit(_:) sizes the panel. The hosting view's own sizing grows it from the left edge, so a longer line
            // pushed the right edge off the screen before fit(_:) saw a difference.
            let host = PillHostingView(rootView: PillView(chat: .shared, setup: .shared))
            host.feedback = .pill
            host.sizingOptions = []
            panel.contentView = host
            if let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 16, y: screen.minY + 16))
            }
            panel.setFrameAutosaveName("PippaPill")
            self.panel = panel
        }
        if let panel { panel.setFrame(onScreen(panel.frame), display: false) }
        panel?.orderFrontRegardless()
    }

    /// The line grows and shrinks; the pill keeps its right edge where the person put it, and stays on the screen.
    func fit(_ size: CGSize) {
        guard let panel, size.width > 0, abs(panel.frame.width - size.width) > 0.5 || abs(panel.frame.height - size.height) > 0.5 else { return }
        let frame = panel.frame
        panel.setFrame(onScreen(NSRect(x: frame.maxX - size.width, y: frame.minY, width: size.width, height: size.height)), display: true)
    }

    /// Moves a frame inside the visible part of its screen (a saved position, another display, a longer line).
    private func onScreen(_ frame: NSRect) -> NSRect {
        guard let visible = (NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? NSScreen.main)?.visibleFrame
        else { return frame }
        var frame = frame
        frame.origin.x = max(visible.minX, min(frame.origin.x, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
        return frame
    }

    /// Hovering, dragging, or updating this companion must never take keyboard focus from another window.
    private final class PillPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
}

struct PillView: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var setup: SetupModel
    @ObservedObject private var feedback = DropFeedback.pill

    private enum Tone { case rest, working, needsYou, done, failed }

    var body: some View {
        HStack(spacing: 8) {
            // 28 in a 44 capsule with 8 leading: the mark sits concentric in the round end.
            PippaMark(size: 28, state: markState, hovered: feedback.hovered)
            Text(label)
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(labelColor)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 240, alignment: .leading)
                .contentTransition(.opacity)
            if let symbol {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(tint)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.leading, 8).padding(.trailing, symbol == nil ? 18 : 14)
        .frame(height: 44)
        .fixedSize()
        .background { Glass().clipShape(Capsule()) }
        .overlay { if let wash { Capsule().fill(wash).allowsHitTesting(false) } }
        // A circular capsule stroked inside its edge: `strokeBorder` on the default capsule left 1 pt slivers where the
        // round ends meet the frame.
        .overlay { Capsule(style: .circular).inset(by: rimWidth / 2).stroke(rim, lineWidth: rimWidth).allowsHitTesting(false) }
        .compositingGroup()
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
        .scaleEffect(feedback.targeted ? 1.06 : 1)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: label)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: feedback.targeted)
        .padding(10)
        .contentShape(Capsule())
        .onGeometryChange(for: CGSize.self) { $0.size } action: { Pill.shared.fit($0) }
    }

    private var tone: Tone {
        if chat.isAnswering { return .working }
        if !setup.usesOnlineAI {
            switch setup.state {
            case .preparing, .downloading: return .working
            case .askDownload, .failed: return .needsYou
            case .ready: break
            }
        }
        switch chat.unseen {
        case .answer: return .done
        case .failed: return .failed
        case nil: return .rest
        }
    }

    private var label: String {
        if feedback.targeted { return T("Drop something on me!", table: "App") }
        if chat.isAnswering {
            let last = chat.answering?.messages.last
            if let step = last?.steps.last(where: { !$0.done }) { return step.label }
            if let text = last?.text, !text.isEmpty { return T("Writing…", table: "App") }
            return T("Thinking…", table: "App")
        }
        if !setup.usesOnlineAI {
            switch setup.state {
            case .preparing: return T("Getting ready…", table: "App")
            case .downloading(let progress, _): return T("Loading my AI · %lld %%", table: "App", Int(progress * 100))
            case .askDownload, .failed: return T("Set up my AI", table: "App")
            case .ready: break
            }
        }
        switch chat.unseen {
        case .answer: return T("Your answer is ready", table: "App")
        case .failed: return T("That didn’t work", table: "App")
        case nil: return "Pippa"
        }
    }

    private var markState: MarkState {
        switch tone {
        case .rest, .done: return .ruht
        case .working: return .arbeitet
        case .needsYou: return .offen
        case .failed: return .fehler
        }
    }

    private var tint: Color {
        switch tone {
        case .done: return Theme.ok
        case .failed: return Theme.bad
        default: return Theme.accent
        }
    }

    private var wash: Color? {
        switch tone {
        case .done: return Theme.okTint
        case .failed: return Theme.badTint
        case .needsYou: return Theme.accentTint
        default: return nil
        }
    }

    /// Only "needs you" speaks in the accent colour; a working step reads quieter than the name at rest.
    private var labelColor: Color {
        switch tone {
        case .needsYou: return Theme.accent
        case .working: return Theme.ink2
        default: return Theme.ink
        }
    }

    private var rim: Color {
        if feedback.targeted { return Theme.accent }
        switch tone {
        case .rest, .working: return Theme.hairline
        default: return tint.opacity(0.6)
        }
    }

    private var rimWidth: CGFloat {
        if feedback.targeted { return 1.5 }
        return tone == .rest || tone == .working ? 0.5 : 1
    }

    /// A small sign after the words, so the state does not depend on colour alone.
    private var symbol: String? {
        switch tone {
        case .rest, .working: return nil
        case .needsYou: return "questionmark"
        case .done: return "checkmark"
        case .failed: return "exclamationmark"
        }
    }
}

/// Behind-window glass for the floating pill.
private struct Glass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// What the shortcut, the pill, the menu and the Dock icon do.
@MainActor
enum AppActions {
    /// Opens the chat; the app that was in front becomes a chip the person can keep or remove.
    static func callPippa(front: NSRunningApplication? = NSWorkspace.shared.frontmostApplication) {
        if let front, front.bundleIdentifier != Bundle.main.bundleIdentifier, let name = front.localizedName,
           ChatModel.shared.draft.isEmpty {
            ChatModel.shared.frontApp = name
        }
        ChatWindow.shared.show()
    }

    static func attach(_ urls: [URL]) {
        for url in urls where url.isFileURL && !ChatModel.shared.attachments.contains(url) { ChatModel.shared.attachments.append(url) }
        ChatWindow.shared.show()
    }
}
