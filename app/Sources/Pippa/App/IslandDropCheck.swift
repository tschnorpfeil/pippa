import AppKit
import PippaCore

/// `Pippa --check-island-drop`, run by scripts/check-island-drop.sh in a cloned app: writes where Pippa Island is and a
/// line whenever it opens, closes, shows its drop zone or receives files, while the script drags files onto it and
/// presses the default shortcut with real mouse and key events.
@MainActor
enum IslandDropCheck {
    static func run() async -> Int32 {
        func settle(_ ms: Int = 250) async { try? await Task.sleep(for: .milliseconds(ms)) }
        for _ in 0..<10 where !NSRunningApplication.current.isFinishedLaunching { await settle() }
        Island.shared.start()
        // The default shortcut, as the app registers it: the script presses it at the end.
        // As in the app: the shortcut opens the island for a quick question, and the keyboard must land in its field.
        HotkeyCenter.shared.onPress = {
            print("HOTKEY \(Hotkey.current.rawValue)")
            Island.shared.ask()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                let panel = Island.shared.presenter?.panel
                print("FOCUS open=\(Island.shared.isOpen) key=\(panel?.isKeyWindow == true) field=\(panel?.firstResponder is NSTextView)")
            }
        }
        print("HOTKEY_REGISTERED \(HotkeyCenter.shared.apply(Hotkey.current))")
        await settle(600)
        guard let presenter = Island.shared.presenter, let placement = presenter.placement, let screen = NSScreen.screens.first else {
            print("ISLAND_MISSING"); return 1
        }
        // Where the closed island shows its drop zone: under the menu bar symbol, or left of the notch.
        let zone = IslandGeometry.compact(placement, width: placement.isNotch ? 120 : 160)
        print("ISLAND_REST \(Int(zone.midX)) \(Int(screen.frame.maxY - zone.midY))")
        var last = "", wasOpen = false
        for _ in 0..<400 {
            let open = Island.shared.isOpen
            if open && !wasOpen {
                await settle(500)
                // The middle of the open island's content, in the top-left coordinates mouse events use.
                let content = presenter.panel.convertToScreen(presenter.view.panel.convert(presenter.view.panel.bounds, to: nil))
                print("ISLAND_OPEN \(Int(content.midX)) \(Int(screen.frame.maxY - content.midY))")
            }
            wasOpen = open
            let state = "open=\(open) files=\(ChatModel.shared.attachments.count) zone=\(Island.shared.dropMode) field=\(presenter.panel.isKeyWindow && presenter.panel.firstResponder is NSTextView)"
            if state != last { print("STATE \(state)"); last = state }
            await settle(50)
        }
        return 0
    }
}
