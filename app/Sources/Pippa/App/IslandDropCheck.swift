import AppKit

/// `Pippa --check-island-drop`, run by scripts/check-island-drop.sh in a cloned app: opens Pippa Island and writes a
/// line whenever it opens, closes or receives files, while the script drags a file onto it with real mouse events.
@MainActor
enum IslandDropCheck {
    static func run() async -> Int32 {
        func settle(_ ms: Int = 250) async { try? await Task.sleep(for: .milliseconds(ms)) }
        for _ in 0..<10 where !NSRunningApplication.current.isFinishedLaunching { await settle() }
        Island.shared.start()
        await settle()
        Island.shared.toggle()
        await settle(900)
        guard Island.shared.isOpen, let presenter = Island.shared.presenter, let screen = NSScreen.screens.first else {
            print("ISLAND_MISSING"); return 1
        }
        // The middle of the open island's content, in the top-left coordinates mouse events use.
        let content = presenter.view.panel.convert(presenter.view.panel.bounds, to: nil)
        let onScreen = presenter.panel.convertToScreen(content)
        print("ISLAND_OPEN \(Int(onScreen.midX)) \(Int(screen.frame.maxY - onScreen.midY))")
        var last = ""
        for _ in 0..<300 {
            let state = "open=\(Island.shared.isOpen) files=\(ChatModel.shared.attachments.count)"
            if state != last { print("STATE \(state)"); last = state }
            await settle(100)
        }
        return 0
    }
}
