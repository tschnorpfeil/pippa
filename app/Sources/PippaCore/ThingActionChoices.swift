import Foundation

/// A small set of suggestions never removes a supported action from the menu.
/// Habits order the buttons; remaining suggestions lead the overflow, followed by other applicable actions.
public struct ThingActionChoices: Sendable, Equatable {
    public let suggestions: [ThingAction]
    public let overflow: [ThingAction]
    public var all: [ThingAction] { suggestions + overflow }

    public init(offered: [ThingAction], candidates: [ThingAction]) {
        var seen = Set<String>()
        let ranked = offered.filter { candidates.contains($0) && seen.insert($0.id).inserted }
        suggestions = Array(ranked.prefix(2))
        overflow = Array(ranked.dropFirst(2)) + candidates.filter { seen.insert($0.id).inserted }
    }
}
