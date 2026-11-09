import AppKit
import SwiftUI
import Combine

@MainActor
final class DropFeedback: ObservableObject {
    static let island = DropFeedback()
    static let chat = DropFeedback()
    @Published var targeted = false
}

/// AppKit receives file promises directly: Mail has not written an .eml file when the drag starts.
@MainActor
class DropHostingView<Content: View>: NSHostingView<Content> {
    var feedback: DropFeedback?
    /// Where dropped files go: the chat by default, the island's question for the island.
    var onDrop: ([URL]) -> Void = { AppActions.attach($0) }

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
            self.onDrop(result.items)
        }
        return true
    }
}
