import Foundation

/// "Compare with last year" in code, only if the sheet has two comparable columns: two consecutive
/// years as heading ("2025" and "2026", also "Kosten 2025") or a column "Vorjahr" / "Last year" next to a
/// number column. Otherwise nil, and the question goes to the model with `SheetSnapshot.contextText()`.
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
        let first = layout.firstDataRow(in: grid)
        guard first <= grid.lastRow else { return nil }
        var changes: [Change] = []
        for row in first...grid.lastRow where !layout.isTotalRow(row, in: grid) {
            guard let current = grid[row, pair.current].value.anyNumber, let previous = grid[row, pair.previous].value.anyNumber else { continue }
            let label = layout.label(row: row, before: min(pair.current, pair.previous), in: grid)
            changes.append(Change(row: row, label: label, current: current, previous: previous))
        }
        guard changes.count >= 2,
              let currentHeading = layout.heading(column: pair.current, in: grid),
              let previousHeading = layout.heading(column: pair.previous, in: grid) else { return nil }
        return SheetComparison(currentColumn: pair.current, previousColumn: pair.previous, currentHeading: currentHeading,
                               previousHeading: previousHeading, changes: changes)
    }

    /// The row with the largest change (with label), nil if nothing changed.
    public var biggestChange: Change? {
        changes.filter { $0.label != nil && !SheetCheck.same($0.current, $0.previous) }
            .max { abs($0.difference) < abs($1.difference) }
    }

    /// One sentence: "Compared with last year, “Strom” changed most: 1,020 instead of 840."
    public func line(locale: Locale = .current) -> String {
        guard let change = biggestChange, let label = change.label else {
            return L("Nothing changed compared with last year.", table: "Sheet")
        }
        return L("Compared with last year, “%@” changed most: %@ instead of %@.", table: "Sheet", label,
                 SheetCheck.format(change.current, locale: locale), SheetCheck.format(change.previous, locale: locale))
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
