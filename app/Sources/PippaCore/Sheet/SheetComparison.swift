import Foundation

/// "Compare with last year" in code, only if the sheet has two comparable columns: two consecutive
/// years as heading ("2025" and "2026", also "Kosten 2025") or a column "Vorjahr" / "Last year" next to a
/// number column. Otherwise nil, and the line asks which column is last year (`columns`, then `make`).
public struct SheetComparison: Sendable, Hashable {
    public struct Change: Sendable, Hashable {
        public var row: Int
        public var label: String?
        public var current: Double
        public var previous: Double
        public var difference: Double { current - previous }
    }

    public var currentColumn: Int
    public var previousColumn: Int
    public var currentHeading: String
    public var previousHeading: String
    /// Rows with numbers in both columns, without totals rows.
    public var changes: [Change]

    public static func find(in grid: SheetGrid, layout: SheetLayout? = nil) -> SheetComparison? {
        let layout = layout ?? SheetLayout.detect(grid)
        guard layout.headerRow != nil else { return nil }
        let headings = grid.columnNumbers.compactMap { c in layout.heading(column: c, in: grid).map { (column: c, text: $0) } }
        var pair: (current: Int, previous: Int)?
        // Years: the most recent pair of consecutive years.
        let years = headings.compactMap { h in year(in: h.text).map { (column: h.column, year: $0) } }
        for y in years.sorted(by: { $0.year > $1.year }) {
            if let prev = years.first(where: { $0.year == y.year - 1 }) { pair = (y.column, prev.column); break }
        }
        // "Vorjahr" / "Last year": the next number column to its left (otherwise right) is the current year.
        if pair == nil, let previous = headings.first(where: { isPreviousYear($0.text) }) {
            let others = headings.filter { $0.column != previous.column && !isPreviousYear($0.text) && hasNumbers(grid, layout, $0.column) }
            let left = others.filter { $0.column < previous.column }.last
            let right = others.first { $0.column > previous.column }
            if let current = left ?? right { pair = (current.column, previous.column) }
        }
        guard let pair else { return nil }
        return make(in: grid, layout: layout, current: pair.current, previous: pair.previous)
    }

    /// A number column the person can pick when code finds no pair by itself ("Which column is last year?").
    public struct Column: Sendable, Hashable {
        public var column: Int
        public var heading: String
    }

    /// Columns to choose from, left to right: a heading, mostly numbers, not the label column, not years or numbers
    /// like "Nr." or "PLZ". At most `limit`; empty if fewer than two.
    public static func columns(in grid: SheetGrid, layout: SheetLayout? = nil, limit: Int = 4) -> [Column] {
        let layout = layout ?? SheetLayout.detect(grid)
        guard layout.headerRow != nil else { return [] }
        let first = layout.firstDataRow(in: grid)
        guard first <= grid.lastRow else { return [] }
        let rows = (first...grid.lastRow).filter { !layout.isTotalRow($0, in: grid) }
        var found: [Column] = []
        for c in grid.columnNumbers where c != layout.labelColumn {
            guard found.count < limit, let heading = layout.heading(column: c, in: grid), !SheetFacts.isIdentifier(heading) else { continue }
            let numbers = rows.compactMap { grid[$0, c].value.anyNumber }
            let filled = rows.filter { !grid[$0, c].value.isEmpty }.count
            guard numbers.count >= 2, numbers.count * 2 > filled, !numbers.allSatisfy(SheetLayout.isYear) else { continue }
            found.append(Column(column: c, heading: heading))
        }
        return found.count >= 2 ? found : []
    }

    /// The comparison for two columns, found or chosen by the person. Nil with fewer than two rows that have numbers
    /// in both, or without headings.
    public static func make(in grid: SheetGrid, layout: SheetLayout? = nil, current: Int, previous: Int) -> SheetComparison? {
        let layout = layout ?? SheetLayout.detect(grid)
        guard current != previous else { return nil }
        let first = layout.firstDataRow(in: grid)
        guard first <= grid.lastRow else { return nil }
        var changes: [Change] = []
        for row in first...grid.lastRow where !layout.isTotalRow(row, in: grid) {
            guard let now = grid[row, current].value.anyNumber, let before = grid[row, previous].value.anyNumber else { continue }
            let label = layout.label(row: row, before: min(current, previous), in: grid)
            changes.append(Change(row: row, label: label, current: now, previous: before))
        }
        guard changes.count >= 2,
              let currentHeading = layout.heading(column: current, in: grid),
              let previousHeading = layout.heading(column: previous, in: grid) else { return nil }
        return SheetComparison(currentColumn: current, previousColumn: previous, currentHeading: currentHeading,
                               previousHeading: previousHeading, changes: changes)
    }

    /// The row with the largest change (with label), nil if nothing changed.
    public var biggestChange: Change? { biggestChanges(1).first }

    /// The rows with the largest changes (with label), largest first.
    public func biggestChanges(_ count: Int) -> [Change] {
        Array(changes.filter { $0.label != nil && !SheetCheck.same($0.current, $0.previous) }
            .sorted { abs($0.difference) > abs($1.difference) }.prefix(count))
    }

    /// Sums of both columns over the compared rows (totals rows left out).
    public var totals: (current: Double, previous: Double) {
        (changes.reduce(0) { $0 + $1.current }, changes.reduce(0) { $0 + $1.previous })
    }

    /// Two lines, all numbers from code: "In total 1,034 instead of 970 (+6.6 %)." and
    /// "Changed most: Miete +50 (950 instead of 900), Strom +14 (84 instead of 70)."
    public func line(locale: Locale = .current) -> String {
        let top = biggestChanges(3)
        guard !top.isEmpty else { return L("Nothing changed compared with last year.", table: "Sheet") }
        func n(_ value: Double) -> String { SheetCheck.format(value, locale: locale) }
        let sum = totals
        var change = Self.signed(sum.current - sum.previous, locale: locale)
        if !SheetCheck.same(sum.previous, 0) {
            change = Self.percent((sum.current - sum.previous) / abs(sum.previous), locale: locale)
        }
        let total = L("In total %@ instead of %@ (%@).", table: "Sheet", n(sum.current), n(sum.previous), change)
        let items = top.map { c in
            L("%@ %@ (%@ instead of %@)", table: "Sheet", c.label ?? "", Self.signed(c.difference, locale: locale), n(c.current), n(c.previous))
        }
        return total + "\n" + L("Changed most: %@.", table: "Sheet", ListFormatter.localizedString(byJoining: items))
    }

    /// "+50", "−14" (a real minus sign), "±0".
    public static func signed(_ value: Double, locale: Locale) -> String {
        let sign = SheetCheck.same(value, 0) ? "±" : value > 0 ? "+" : "−"
        return sign + SheetCheck.format(abs(value), locale: locale)
    }

    /// "+6.6 %", "−12 %": one decimal below 10 %, whole numbers above.
    public static func percent(_ ratio: Double, locale: Locale) -> String {
        let value = abs(ratio * 100)
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.maximumFractionDigits = value < 10 ? 1 : 0
        f.minimumFractionDigits = 0
        let sign = value < 0.05 ? "±" : ratio > 0 ? "+" : "−"
        return sign + (f.string(from: NSNumber(value: value)) ?? String(value)) + " %"
    }

    static func year(in text: String) -> Int? {
        let digits = text.split(whereSeparator: { !$0.isNumber }).filter { $0.count == 4 }.compactMap { Int($0) }
        let years = digits.filter { (1900...2100).contains($0) }
        return years.count == 1 ? years[0] : nil
    }

    static func isPreviousYear(_ text: String) -> Bool {
        let s = text.lowercased()
        return ["vorjahr", "last year", "previous year", "prior year"].contains { s.contains($0) }
    }

    private static func hasNumbers(_ grid: SheetGrid, _ layout: SheetLayout, _ column: Int) -> Bool {
        let first = layout.firstDataRow(in: grid)
        guard first <= grid.lastRow else { return false }
        return (first...grid.lastRow).contains { grid[$0, column].value.anyNumber != nil }
    }
}

/// Lines the person sees about the sheet: name of the sheet and column heading, never an address.
public enum SheetLine {
    /// During the call: "Looking at your table: Kosten 2026, column Betrag".
    public static func calling(_ snapshot: SheetSnapshot?) -> String {
        guard let snapshot, !snapshot.tableName.isEmpty else { return L("Looking at your table …", table: "Sheet") }
        let layout = SheetLayout.detect(snapshot.grid)
        if let selection = snapshot.selection, selection.left == selection.right,
           let heading = layout.heading(column: selection.left, in: snapshot.grid) {
            return L("Looking at your table: %@, column %@", table: "Sheet", snapshot.tableName, heading)
        }
        return L("Looking at your table: %@", table: "Sheet", snapshot.tableName)
    }
}
