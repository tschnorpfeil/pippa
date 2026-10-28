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
        // The day boundaries once per list, not per row: the rail redraws while an answer streams.
        let days = Days(now: now, calendar: calendar)
        var buckets: [ConversationRailGroup: [ConversationSummary]] = [:]
        for summary in history where summary.messageCount > 0 || summary.id == current {
            let bucket: ConversationRailGroup = summary.messageCount == 0 ? .today : days.group(of: summary.updatedAt)
            buckets[bucket, default: []].append(summary)
        }
        return ConversationRailGroup.allCases.compactMap { group -> ConversationRailSection? in
            guard let items = buckets[group] else { return nil }
            return ConversationRailSection(group: group, items: items.filter { $0.messageCount == 0 } + items.filter { $0.messageCount > 0 })
        }
    }

    /// Days in `calendar` (its time zone, summer time included). A date ahead of `now` counts as today.
    public static func group(of date: Date, now: Date, calendar: Calendar) -> ConversationRailGroup {
        Days(now: now, calendar: calendar).group(of: date)
    }

    /// Start of today, yesterday and the day a week ago, by the calendar rather than in 24-hour steps.
    private struct Days {
        let today: Date
        let yesterday: Date?
        let week: Date?

        init(now: Date, calendar: Calendar) {
            let start = calendar.startOfDay(for: now)
            today = start
            yesterday = calendar.date(byAdding: .day, value: -1, to: start)
            week = calendar.date(byAdding: .day, value: -7, to: start)
        }

        func group(of date: Date) -> ConversationRailGroup {
            if date >= today { return .today }
            guard let yesterdayStart = yesterday, let weekStart = week else { return .older }
            if date >= yesterdayStart { return .yesterday }
            if date >= weekStart { return .previousWeek }
            return .older
        }
    }
}
