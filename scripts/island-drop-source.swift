// The other app in scripts/check-island-drop.sh: a small window whose content starts a file drag, and real mouse and
// key events. 1: drag a file onto the closed island (the drop zone appears on the way). 2: a click outside closes it.
// 3: ⌥ Space opens it with the keyboard in its field. 4: a second file dragged onto the open island lands there.
// Usage: island-drop-source <log> <file> <second file>
import AppKit

let log = CommandLine.arguments[1]
var file = URL(fileURLWithPath: CommandLine.arguments[2])
let second = URL(fileURLWithPath: CommandLine.arguments[3])

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
func state() -> String { lines().last { $0.hasPrefix("STATE ") } ?? "" }
func point(_ prefix: String, after count: Int = 0) -> CGPoint? {
    for _ in 0..<100 {
        if let line = lines().dropFirst(count).last(where: { $0.hasPrefix(prefix + " ") }) {
            let p = line.split(separator: " ").compactMap { Double($0) }
            if p.count == 2 { return CGPoint(x: p[0], y: p[1]) }
        }
        pause(0.1)
    }
    return nil
}
func post(_ type: CGEventType, _ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}
func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
var failures = 0
func report(_ ok: Bool, _ text: String) { print("\(ok ? "✓" : "✗") \(text)"); if !ok { failures += 1 } }

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let screen = NSScreen.screens[0].frame
let window = NSWindow(contentRect: NSRect(x: 240, y: screen.maxY - 560, width: 160, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = Source()
window.level = .floating
window.makeKeyAndOrderFront(nil)
app.activate()
let from = CGPoint(x: 320, y: 480)

/// Drags the file from the window to `to`; `midway` runs while the pointer rests there before the drop.
func drag(to target: CGPoint, midway: () -> Void = {}) {
    post(.mouseMoved, from); pause(0.3)
    post(.leftMouseDown, from); pause(0.3)
    for step in 1...30 {
        let t = Double(step) / 30
        post(.leftMouseDragged, CGPoint(x: from.x + (target.x - from.x) * t, y: from.y + (target.y - from.y) * t)); pause(0.04)
    }
    // A hand never holds perfectly still: a few small moves while the island takes shape under the pointer.
    for dx in [2.0, -2.0, 1.0, -1.0, 0.0] {
        pause(0.15)
        post(.leftMouseDragged, CGPoint(x: target.x + dx, y: target.y))
    }
    pause(0.3)
    midway()
    post(.leftMouseUp, target); pause(1.5)
}
func clickOutside() {
    post(.mouseMoved, from); pause(0.3)
    post(.leftMouseDown, from); pause(0.1); post(.leftMouseUp, from); pause(1.2)
}

Thread.detachNewThread {
    let home = CGEvent(source: nil)?.location ?? from
    guard let zone = point("ISLAND_REST") else { print("FAIL: the island never reported its place"); exit(1) }
    // 1. Onto the closed island.
    var zoneShown = false
    drag(to: zone) { zoneShown = state().contains("zone=true") }
    report(zoneShown, "Dragging a file toward the top of the screen opens the island as a drop tray")
    report(state() == "STATE open=true files=1 zone=false field=true", "The file dropped there lands on the island, which stays open with the keyboard in its field (\(state()))")
    // 2. A plain click outside closes it.
    clickOutside()
    report(state().hasPrefix("STATE open=false"), "A click in another app closes the island (\(state()))")
    // 3. The default shortcut, as a real key press.
    let before = lines().count
    for down in [true, false] {
        let key = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: down) // Space
        key?.flags = .maskAlternate
        key?.post(tap: .cghidEventTap)
    }
    pause(1.5)
    report(lines().contains("HOTKEY optionSpace"), "Pressing ⌥ Space calls Pippa (default shortcut)")
    let focus = lines().last { $0.hasPrefix("FOCUS ") } ?? "FOCUS missing"
    report(focus == "FOCUS open=true key=true field=true", "The shortcut opens the island with the keyboard in its question field (\(focus))")
    // 4. Onto the open island.
    if let open = point("ISLAND_OPEN", after: before) {
        file = second
        drag(to: open)
        report(state().hasPrefix("STATE open=true files=2"), "A file dragged onto the open island lands there and it stays open (\(state()))")
    } else {
        report(false, "The open island reported its place")
    }
    clickOutside()
    post(.mouseMoved, home)
    exit(failures == 0 ? 0 : 1)
}
app.run()
