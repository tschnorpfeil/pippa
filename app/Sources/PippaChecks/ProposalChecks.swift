import Foundation
import PippaCore

func runProposalChecks() async {
    check("Calendar: all-day event ends at the next day's start on 23- and 25-hour days") {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let short = CalendarEntry(target: .calendar, title: "Test", date: DayDate(year: 2026, month: 3, day: 29)!, notes: "", alertDay: DayDate(year: 2026, month: 3, day: 28)!).eventInterval(in: calendar)
        let long = CalendarEntry(target: .calendar, title: "Test", date: DayDate(year: 2026, month: 10, day: 25)!, notes: "", alertDay: DayDate(year: 2026, month: 10, day: 24)!).eventInterval(in: calendar)
        return short.duration == 23 * 3600 && long.duration == 25 * 3600 && calendar.component(.hour, from: long.end) == 0
    }
}
