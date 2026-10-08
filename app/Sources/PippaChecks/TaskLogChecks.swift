import Foundation
import PippaCore

func runTaskLogChecks() async {
    let now = Date(timeIntervalSince1970: 1_790_000_000) // autumn 2026
    func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    await checkAsync("Task log: a row with offer, choice, target and outcome is kept, without content") {
        let log = try TaskLog(path: ":memory:", now: now)
        let id = try await log.record(TaskRecord(at: daysAgo(1), kind: .invoices, sourceLabel: "Stadtwerke",
                                                 offered: ["sort", "invoiceTable"], chosen: "invoiceTable"))
        try await log.setTarget(TaskTarget(kind: .table, label: "Rechnungen 2026"), for: id)
        try await log.setOutcome(.kept, for: id)
        let rows = try await log.records()
        guard let r = rows.first, rows.count == 1 else { return false }
        return r.id == id && r.kind == .invoices && r.sourceLabel == "Stadtwerke" && r.offered == ["sort", "invoiceTable"]
            && r.chosen == "invoiceTable" && r.target == TaskTarget(kind: .table, label: "Rechnungen 2026") && r.outcome == .kept && !r.isPrivate
    }
    await checkAsync("Task log: \"don't remember\" stores no names of source and target") {
        let log = try TaskLog(path: ":memory:", now: now)
        let id = try await log.record(TaskRecord(at: now, kind: .letter, sourceLabel: "Finanzamt", offered: ["a"], chosen: "a",
                                                 target: TaskTarget(kind: .folder, label: "Steuer"), isPrivate: true))
        try await log.setTarget(TaskTarget(kind: .folder, label: "Steuer"), for: id)
        let r = try await log.records().first
        return r?.isPrivate == true && r?.sourceLabel == nil && r?.target == TaskTarget(kind: .folder, label: nil) && r?.kind == .letter
    }
    await checkAsync("Task log: file in Application Support form, entries older than twelve months drop out on open") {
        let base = dir("tasklog")
        do {
            let log = try TaskLog(baseDirectory: base, now: now)
            try await log.record(TaskRecord(at: now.addingTimeInterval(-400 * 86_400), kind: .folder, offered: ["sort"], chosen: "sort"))
            try await log.record(TaskRecord(at: daysAgo(300), kind: .folder, offered: ["sort"], chosen: "sort"))
            try await log.log(.permissionAsked, at: now.addingTimeInterval(-400 * 86_400))
            try await log.log(.granted, at: daysAgo(2))
        }
        guard FileManager.default.fileExists(atPath: base.appendingPathComponent(TaskLog.fileName).path) else { return false }
        let reopened = try TaskLog(baseDirectory: base, now: now)
        let rows = try await reopened.records()
        let asked = try await reopened.count(.permissionAsked), granted = try await reopened.count(.granted)
        return rows.count == 1 && rows[0].at == daysAgo(300) && asked == 0 && granted == 1
    }
    await checkAsync("Task log: \"forget everything\" clears actions and events") {
        let log = try TaskLog(path: ":memory:", now: now)
        try await log.record(TaskRecord(at: now, kind: .text, offered: ["kuerzer"], chosen: "kuerzer"))
        try await log.log(.resultLeft, at: now)
        try await log.forgetEverything()
        let rows = try await log.records(), left = try await log.count(.resultLeft)
        return rows.isEmpty && left == 0
    }
    check("Task log: kind from item and place") {
        TaskKind.guess(for: .folder) == .folder && TaskKind.guess(for: .pdf, count: 3) == .scans && TaskKind.guess(for: .pdf) == .letter
            && TaskKind.guess(for: .office, fileExtension: "XLSX") == .table && TaskKind.guess(for: .text, fileExtension: "csv") == .table
            && TaskKind.guess(for: .link) == nil && TaskKind(place: .brief) == .letter && TaskKind(place: .immer) == nil
    }

    // MARK: Habits (pure)

    func row(_ chosen: String?, kind: TaskKind = .invoices, offered: [String] = ["sort", "invoiceTable", "deadlines"], days: Double,
             source: String? = "Stadtwerke", target: TaskTarget? = nil, outcome: TaskOutcome? = .kept, id: Int64? = nil) -> TaskRecord {
        TaskRecord(id: id, at: daysAgo(days), kind: kind, sourceLabel: source, offered: offered, chosen: chosen, target: target, outcome: outcome)
    }
    check("Habits: recent counts double, undone −1, a tie keeps the type order") {
        let records = [
            row("deadlines", days: 2),                      // 2 × 2 (same source) = 4
            row("sort", days: 90), row("sort", days: 100), row("sort", days: 110), // 3 × 1 × 2 = 6
            row("invoiceTable", days: 1, outcome: .undone), // −1
        ]
        let order = Habits.order(["sort", "invoiceTable", "deadlines"], kind: .invoices, source: "Stadtwerke", in: records, now: now)
        let otherKind = Habits.order(["sort", "invoiceTable"], kind: .folder, in: records, now: now)
        return order == ["sort", "deadlines", "invoiceTable"] && otherKind == ["sort", "invoiceTable"]
            && Habits.weight(of: row("x", days: 40, source: nil), source: "Stadtwerke", now: now) == 1
    }
    check("Habits: offered five times, never chosen → steps back, at most three") {
        let offered = ["a", "b", "c", "d"]
        let ignored = (0..<5).map { row(nil, kind: .text, offered: offered, days: Double($0)) }
        let chosenB = row("b", kind: .text, offered: offered, days: 10)
        let faded = Habits.faded(kind: .text, in: ignored + [chosenB])
        let fourTimes = Habits.faded(kind: .text, in: Array(ignored.prefix(4)))
        let arranged = Habits.arrange(offered + ["e"], kind: .text, in: ignored + [chosenB], now: now)
        return faded == ["a", "c", "d"] && fourTimes.isEmpty && arranged == ["b", "e"]
    }
    check("Habits: \"as usual\" after the same target three times, not after an undo or a different target") {
        let target = TaskTarget(kind: .folder, label: "Rechnungen 2026")
        let three = (1...3).map { row("sort", days: Double($0), target: target, id: Int64(10 - $0)) }
        let usual = Habits.asUsual(kind: .invoices, source: "Stadtwerke", in: three)
        let undone = Habits.asUsual(kind: .invoices, source: "Stadtwerke", in: [row("sort", days: 0.5, target: target, outcome: .undone)] + three)
        let other = Habits.asUsual(kind: .invoices, source: "Stadtwerke",
                                   in: [row("sort", days: 0.5, target: TaskTarget(kind: .folder, label: "Ablage"))] + three)
        let otherSource = Habits.asUsual(kind: .invoices, source: "Telekom", in: three)
        let two = Habits.asUsual(kind: .invoices, source: "Stadtwerke", in: Array(three.prefix(2)))
        return usual?.action == "sort" && usual?.target == target && undone == nil && other == nil && otherSource == nil && two == nil
    }
}
