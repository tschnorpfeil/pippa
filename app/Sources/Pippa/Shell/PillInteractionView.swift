import AppKit
import PippaCore

/// Menu item with a closure.
final class MenuAction: NSObject {
    let action: @MainActor () -> Void
    init(_ action: @escaping @MainActor () -> Void) { self.action = action }
    @MainActor @objc func run() { action() }

    @MainActor
    static func item(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [], enabled: Bool = true,
                     _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let target = MenuAction(action)
        let item = NSMenuItem(title: title, action: enabled ? #selector(run) : nil, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        item.representedObject = target   // keeps the target alive
        item.isEnabled = enabled
        return item
    }
}

/// Invisible surface over the pill: move, click, right-click, hover, VoiceOver.
final class PillInteractionView: ShellDropView {
    var mode: ShellMode.Shape = .pill
    private var downPoint: NSPoint?
    private var downFrame: NSRect = .zero
    private var moved = false
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        if mode == .pill {
            controller?.pulseMark()
            controller?.pillHover(true)
        }
    }

    override func mouseExited(with event: NSEvent) {
        controller?.pillHover(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard mode == .pill, let controller else { return }
        controller.pillHover(false)
        downPoint = NSEvent.mouseLocation
        downFrame = controller.shellScreenRect
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, let controller else { return }
        let p = NSEvent.mouseLocation
        let dx = p.x - start.x, dy = p.y - start.y
        if !moved && hypot(dx, dy) < 4 { return }
        if !moved { NSCursor.closedHand.push() }
        moved = true
        controller.isDraggingPill = true
        var f = downFrame
        f.origin.x += dx
        f.origin.y += dy
        controller.movePill(to: controller.magnetized(f))
    }

    override func mouseUp(with event: NSEvent) {
        guard downPoint != nil else { return }
        downPoint = nil
        if moved {
            NSCursor.pop()
            if let controller {
                controller.savePill(controller.shellScreenRect)
                controller.isDraggingPill = false
                controller.layout(animated: false, force: true)
            }
        } else {
            controller?.pillClicked()
        }
        moved = false
    }

    override func rightMouseDown(with event: NSEvent) {
        guard mode == .pill else { return }
        controller?.showPillMenu(with: event, in: self)
    }

    // VoiceOver
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { MainActor.assumeIsolated { AppModel.shared.spokenState } }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard controller?.model.tray.peek.isEmpty == false else { return nil }
        return [NSAccessibilityCustomAction(name: T("Show Attachments", table: "Shelf")) { [weak self] in
            MainActor.assumeIsolated { self?.controller?.focusAttachments() ?? false }
        }]
    }
    override func accessibilityHelp() -> String? { T("Click to ask. Drag files here to hand them over.", table: "App") }
    override func accessibilityPerformPress() -> Bool {
        controller?.pillClicked()
        return true
    }

}
