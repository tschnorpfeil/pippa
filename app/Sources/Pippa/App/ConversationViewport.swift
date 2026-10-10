import Foundation

/// Presentation state belongs to its topic, independently of the shell's size.
/// Kept in memory: scrolling must not rewrite the persisted conversation on every frame.
struct ConversationViewport {
    var offsetY: CGFloat
    var followsLatest: Bool
}

struct ConversationScrollMetrics: Equatable {
    var offsetY: CGFloat
    var atBottom: Bool
}

/// Heights only: following the latest line cares about growth, not about where the view is scrolled.
struct ConversationScrollExtent: Equatable {
    var content: CGFloat
    var container: CGFloat
}
