import Foundation

extension PippaMCPTools {
    // MARK: Calendar

    func calendarRead(_ input: ToolInput) async -> PippaMCPToolResult {
        guard let period = input.period else { return invalid("period is required.") }
        if case .blocked(let reply) = await ensure(.calendar) { return reply }
        let request = CalendarToolRequest(period: period, start: input.start, end: input.end, days: input.days)
        let reply = await CalendarReader.toolReply(request, from: host.integrations, now: host.now(), calendar: host.calendar)
        switch reply.status {
        case .ok:
            guard let payload = reply.payload, var digest = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                return blocked("failed", CalendarReadResult.failureText)
            }
            let source = digest.removeValue(forKey: "source") as? String ?? "Calendar on this Mac"
            var result = Self.bounded(source: source, data: digest,
                                      next: "The person sees these appointments as a card under your answer. Do not list them again; answer the question in one or two sentences. Copy any day, time or state you mention exactly; do not compute them. If days is empty, nothing is in the calendar for this period.")
            result.card = reply.card.map(ResultCard.calendar)
            return result
        case .invalidRange:
            return invalid("This period cannot be read. Use a period from the list, or dates (YYYY-MM-DD) with at most 31 days.")
        case .needsAccess: return blocked("needs_access", Self.notYet(.calendar))
        case .denied: return blocked("denied", Self.denied(.calendar), repair: .calendar)
        case .failed: return blocked("failed", CalendarReadResult.failureText)
        }
    }

    // MARK: Reminders

    func remindersRead(_ input: ToolInput) async -> PippaMCPToolResult {
        if let days = input.days, !(1...CalendarRange.maxDays).contains(days) { return invalid("days must be 1 to 31.") }
        if case .blocked(let reply) = await ensure(.reminders) { return reply }
        let now = host.now(), cal = host.calendar
        let end = input.days.flatMap { cal.date(byAdding: .day, value: $0, to: cal.startOfDay(for: now)) }
        do {
            let fetch = try await host.hostData.openReminders(dueBefore: end, limit: 40)
            let items = fetch.items.map { item -> [String: Any] in
                var value: [String: Any] = ["title": item.title, "list": item.list]
                if let due = item.due {
                    value["due"] = Self.dateLabel(due, time: item.dueHasTime, calendar: cal)
                    if due < (item.dueHasTime ? now : cal.startOfDay(for: now)) { value["overdue"] = true }
                }
                return value
            }
            var result = Self.bounded(source: "Reminders on this Mac", data: ["reminders": items, "shown": items.count, "total": fetch.total,
                                                                               "truncated": fetch.total > items.count],
                                      next: "If reminders is not empty, the person sees them as a card under your answer: do not list them again; answer in one or two sentences, copying any due date you mention exactly. If the list is empty, there are no open reminders for this period.")
            if !fetch.items.isEmpty {
                result.card = .reminders(ReminderCard(days: input.days, reminders: fetch.items, total: fetch.total, now: now, calendar: cal))
            }
            return result
        } catch {
            return failure(error, .reminders)
        }
    }
}
