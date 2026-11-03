import AppKit
import SwiftUI
import Combine

@MainActor
final class DropFeedback: ObservableObject {
    static let pill = DropFeedback()
    static let chat = DropFeedback()
    @Published var targeted = false
    @Published var hovered = false
}

/// AppKit receives file promises directly: Mail has not written an .eml file when the drag starts.
@MainActor
class DropHostingView<Content: View>: NSHostingView<Content> {
    var feedback: DropFeedback?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes(DropReader.types)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepts = sender.draggingPasteboard.availableType(from: DropReader.types) != nil
        feedback?.targeted = accepts
        return accepts ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { feedback?.targeted = false }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { feedback?.targeted = false }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { !draggingEntered(sender).isEmpty }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard prepareForDragOperation(sender) else { return false }
        feedback?.targeted = false
        DropReader.read(sender.draggingPasteboard) { result in
            guard let result, !result.items.isEmpty else { return }
            AppActions.attach(result.items)
        }
        return true
    }
}

/// A click opens chat; movement beyond the drag threshold moves the companion without activating it.
@MainActor
final class PillHostingView<Content: View>: DropHostingView<Content> {
    private var down: NSPoint?
    private var origin: NSPoint?
    private var moved = false
    private var hoverTracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) { feedback?.hovered = true }
    override func mouseExited(with event: NSEvent) { feedback?.hovered = false }

    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        down = window?.convertPoint(toScreen: event.locationInWindow)
        origin = window?.frame.origin
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down, let origin, let window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let delta = NSPoint(x: point.x - down.x, y: point.y - down.y)
        guard moved || hypot(delta.x, delta.y) >= 4 else { return }
        moved = true
        window.setFrameOrigin(NSPoint(x: origin.x + delta.x, y: origin.y + delta.y))
    }

    override func mouseUp(with event: NSEvent) {
        guard down != nil else { return }
        defer { down = nil; origin = nil }
        if moved {
            if let window { window.saveFrame(usingName: "PippaPill") }
        } else { AppActions.callPippa() }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(MenuAction.item(T("Ask Pippa", table: "App")) { AppActions.callPippa() })
        menu.addItem(MenuAction.item(T("Settings…", table: "App")) { SettingsWindow.shared.show() })
        menu.addItem(.separator())
        menu.addItem(MenuAction.item(T("Hide Pill", table: "App")) { Pill.shared.isShown = false })
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}
