import Foundation

/// Notes on an answer in the conversation that it came from the calendar (or asked for access), which period it was
/// and which question was behind it. This lets follow-ups ("und morgen?", "and tomorrow?") and "Freigeben" (give access) work without retyping.
/// Missing in older histories.
public struct ConversationCalendarRead: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case read, needsAccess, denied, failed }
    public var state: State
    public var question: String
    public var range: CalendarRange
    public init(state: State, question: String, range: CalendarRange) {
        self.state = state; self.question = String(question.prefix(500)); self.range = range
    }
}

/// How a calendar result appears in the conversation, and what follow-up questions may know about it. Without UI, checked in PippaChecks.
public enum CalendarConversation {
    /// A short time reference still counts as a follow-up to the calendar up to this many messages back.
    public static let followUpWindow = 6

    /// The one sentence before the system prompt: what Pippa reads, and when.
    public static var accessBenefit: String {
        L("To answer this, I need to read your calendar on this Mac – only the period you ask about, and only when you ask.", table: "Calendar")
    }

    public static var deniedText: String {
        L("I’m not allowed to read your calendar, so I haven’t looked at any appointments. You can allow it in System Settings under Privacy & Security → Calendars.", table: "Calendar")
    }

    /// Text and marker for the answer. Each state has its own wording; only a real read can say „nothing in your calendar“.
    public static func answer(for result: CalendarReadResult, question: String, range: CalendarRange) -> (text: String, calendar: ConversationCalendarRead) {
        switch result {
        case .read(let digest): (digest.markdown, ConversationCalendarRead(state: .read, question: question, range: range))
        case .needsAccess: (accessBenefit, ConversationCalendarRead(state: .needsAccess, question: question, range: range))
        case .denied: (deniedText, ConversationCalendarRead(state: .denied, question: question, range: range))
        case .failed(let why): (why, ConversationCalendarRead(state: .failed, question: question, range: range))
        }
    }

    /// Was the calendar read (or asked for) a moment ago in this conversation?
    public static func recentTurn(in messages: [ConversationMessage]) -> Bool {
        messages.suffix(followUpWindow).contains { $0.calendar != nil }
    }

    /// The newest access offer still waiting for a click: only the last calendar message of the conversation can carry the button.
    public static func pendingAccessOffer(in messages: [ConversationMessage]) -> ConversationMessage? {
        guard let last = messages.last(where: { $0.calendar != nil }), last.calendar?.state == .needsAccess else { return nil }
        return last
    }
}
