// The other app in scripts/check-island-drop.sh: a small window whose content starts a file drag, and real mouse
// events that drag from it onto Pippa Island and then click it once. Usage: island-drop-source <log> <file>
import AppKit

let log = CommandLine.arguments[1], file = URL(fileURLWithPath: CommandLine.arguments[2])

final class Source: NSView, NSDraggingSource {
    override func draw(_ dirtyRect: NSRect) { NSColor.systemBlue.setFill(); bounds.fill() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        item.setDraggingFrame(NSRect(x: 0, y: 0, width: 32, height: 32), contents: NSWorkspace.shared.icon(forFile: file.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

func lines() -> [String] { ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
func post(_ type: CGEventType, _ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}
func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let screen = NSScreen.screens[0].frame
let window = NSWindow(contentRect: NSRect(x: 240, y: screen.maxY - 560, width: 160, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = Source()
window.level = .floating
window.makeKeyAndOrderFront(nil)
app.activate()
let from = CGPoint(x: 320, y: 480)

Thread.detachNewThread {
    var island: CGPoint?
    for _ in 0..<150 where island == nil {
        if let line = lines().first(where: { $0.hasPrefix("ISLAND_OPEN ") }) {
            let parts = line.split(separator: " ").compactMap { Double($0) }
            if parts.count == 2 { island = CGPoint(x: parts[0], y: parts[1]) }
        }
        pause(0.2)
    }
    guard let island else { print("FAIL: the island never opened"); exit(1) }
    let home = CGEvent(source: nil)?.location ?? from
    // A file dragged from this window onto the open island.
    post(.mouseMoved, from); pause(0.3)
    post(.leftMouseDown, from); pause(0.3)
    for step in 1...25 {
        let t = Double(step) / 25
        post(.leftMouseDragged, CGPoint(x: from.x + (island.x - from.x) * t, y: from.y + (island.y - from.y) * t)); pause(0.04)
    }
    pause(0.6)
    post(.leftMouseUp, island); pause(1.5)
    let afterDrop = lines().last { $0.hasPrefix("STATE ") } ?? ""
    let closedMeanwhile = lines().drop { !$0.hasPrefix("ISLAND_OPEN") }.contains { $0.hasPrefix("STATE open=false") }
    // A plain click outside closes it.
    post(.mouseMoved, from); pause(0.3)
    post(.leftMouseDown, from); pause(0.1); post(.leftMouseUp, from); pause(1.2)
    let afterClick = lines().last { $0.hasPrefix("STATE ") } ?? ""
    post(.mouseMoved, home)
    // The default shortcut, as a real key press.
    for down in [true, false] {
        let key = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: down) // Space
        key?.flags = .maskAlternate
        key?.post(tap: .cghidEventTap)
    }
    pause(1)
    let hotkey = lines().contains("HOTKEY optionSpace")
    print("\(hotkey ? "✓" : "✗") Pressing ⌥ Space calls Pippa (default shortcut)")
    let dropped = afterDrop == "STATE open=true files=1" && !closedMeanwhile
    let closed = afterClick.hasPrefix("STATE open=false")
    print("\(dropped ? "✓" : "✗") A file dragged from another app lands on the open island, which stays open (\(afterDrop), closed meanwhile: \(closedMeanwhile))")
    print("\(closed ? "✓" : "✗") A click in another app closes the island (\(afterClick))")
    exit(dropped && closed && hotkey ? 0 : 1)
}
app.run()
