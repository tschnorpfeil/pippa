import AppKit
import PippaCore

// Read calendar: Pippa answers questions about the person's own appointments in code, without a model and without attachment:
// time range in code (CalendarIntent), reading via EventKit in the host, answer by day with source and exact time range.
// Without access, first a sentence with the benefit and a button, then the system prompt. Explicitly requested
// reading needs no further confirmation card; writing stays preview → confirm → undo.
extension AppModel {

    /// Does the message ask about the person's own appointments? Follow-ups count only directly after a calendar answer in the same conversation.
    func calendarIntent(for text: String, now: Date = Date()) -> CalendarIntent? {
        let messages = conversations.current?.messages ?? []
        return CalendarIntent.parse(text, now: now, calendar: .autoupdatingCurrent, recentCalendarTurn: CalendarConversation.recentTurn(in: messages))
    }

    /// Why sending is not possible right now. Calendar questions and tidying also work without loaded knowledge: they need
    /// no model (when tidying, unclear items are then left in place).
    func sendBlockedReason(for text: String) -> String? {
        guard let reason = chatBlockedReason, !startupBridgeAnswers else { return nil }
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return calendarIntent(for: q) == nil && tidyIntent(for: q) == nil ? reason : nil
    }

    /// Native answer from the calendar. `question` is already in the field or is now added to the history.
    func answerCalendar(_ question: String, range: CalendarRange) {
        conversations.append(.user, question)
        readCalendar(question: question, range: range)
    }

    /// "Allow calendar" on the access request: now the system prompt, then read and answer directly.
    func allowCalendarAccess(_ message: ConversationMessage) {
        guard !isActiveWork, let offer = message.calendar, offer.state == .needsAccess,
              CalendarConversation.pendingAccessOffer(in: conversations.current?.messages ?? [])?.id == message.id else { return }
        busy = true
        let engine = self.engine
        Task { [weak self] in
            let access = await engine.requestIntegrationAccess(.calendar)
            guard let self else { return }
            self.busy = false
            DiagnosticsLog.shared.event("kalender-freigabe", ["ergebnis": access == .granted ? "erlaubt" : "nicht-erlaubt"])
            switch access {
            case .granted:
                // The time range applies from now ("from now until the weekend"), not from the earlier question.
                let range = CalendarIntent.parse(offer.question, now: Date(), calendar: .autoupdatingCurrent, recentCalendarTurn: true)?.range ?? offer.range
                self.readCalendar(question: offer.question, range: range)
            case .denied:
                self.appendCalendar(.denied, question: offer.question, range: offer.range)
            case .notDetermined:
                // System prompt closed without a decision: the request stays, and so does the button.
                break
            case .unavailable(let why):
                self.appendCalendar(.failed(why), question: offer.question, range: offer.range)
            }
        }
    }

    func openCalendarPrivacySettings() {
        NSWorkspace.shared.open(Integration.calendar.settingsURL)
    }

    private func readCalendar(question: String, range: CalendarRange) {
        busy = true
        let engine = self.engine
        let conversation = conversations.current?.id
        Task { [weak self] in
            let result = await engine.readCalendar(range)
            guard let self else { return }
            self.busy = false
            guard self.conversations.current?.id == conversation else { return }
            self.appendCalendar(result, question: question, range: range)
        }
    }

    private func appendCalendar(_ result: CalendarReadResult, question: String, range: CalendarRange) {
        let answer = CalendarConversation.answer(for: result, question: question, range: range)
        conversations.append(.assistant, answer.text, calendar: answer.calendar)
        NSAccessibility.post(element: NSApp.keyWindow ?? NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Pippa: " + answer.text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}

