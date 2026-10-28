import Foundation

/// Where a conversation sits in the conversation rail: by the calendar day of its last change.
public enum ConversationRailGroup: String, Sendable, CaseIterable {
    case today, yesterday, previousWeek, older
}

public struct ConversationRailSection: Equatable, Sendable, Identifiable {
    public var group: ConversationRailGroup
    public var items: [ConversationSummary]
    public var id: ConversationRailGroup { group }
    public init(group: ConversationRailGroup, items: [ConversationSummary]) { self.group = group; self.items = items }
}

/// The conversation rail's list: conversations with messages, plus the open one even while it is empty (the next
/// message goes there), grouped Today / Yesterday / Previous 7 Days / Older. Within a group the history's order
/// (newest change first) stays; an empty open conversation leads Today.
public enum ConversationRailGroups {
    public static func sections(_ history: [ConversationSummary], current: UUID?, now: Date, calendar: Calendar) -> [ConversationRailSection] {
        var buckets: [ConversationRailGroup: [ConversationSummary]] = [:]
        for summary in history where summary.messageCount > 0 || summary.id == current {
            let bucket: ConversationRailGroup = summary.messageCount == 0 ? .today : Self.group(of: summary.updatedAt, now: now, calendar: calendar)
            buckets[bucket, default: []].append(summary)
        }
        return ConversationRailGroup.allCases.compactMap { group -> ConversationRailSection? in
            guard let items = buckets[group] else { return nil }
            return ConversationRailSection(group: group, items: items.filter { $0.messageCount == 0 } + items.filter { $0.messageCount > 0 })
        }
    }

    /// Days in `calendar` (its time zone, summer time included). A date ahead of `now` counts as today.
    public static func group(of date: Date, now: Date, calendar: Calendar) -> ConversationRailGroup {
        let today = calendar.startOfDay(for: now)
        if date >= today { return .today }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              let week = calendar.date(byAdding: .day, value: -7, to: today) else { return .older }
        if date >= yesterday { return .yesterday }
        if date >= week { return .previousWeek }
        return .older
    }
}
