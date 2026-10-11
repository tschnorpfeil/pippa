import Foundation

// The numbers a question about a table usually needs, computed in code before the model sees the cells: per number
// column the sum, the count and the smallest and largest value with their row, and the sums per category when a text
// column repeats a few values ("Kategorie": Strom, Miete, …). The model takes these instead of adding up in its head.
// Total rows ("Summe", "Gesamt") never count, so the table's own total is not counted twice. Plain code, no model.

public enum SheetFacts {
    /// At most this many number columns get a line.
    static let maxColumns = 4
    /// A text column groups the sums when it has between 2 and this many different values.
    static let maxGroups = 12

    public struct Column: Sendable {
        public var heading: String
        public var sum: Double
        /// Rows with a number in this column (total rows left out).
        public var count: Int
        public var smallest: (row: Int, value: Double, label: String?)
        public var largest: (row: Int, value: Double, label: String?)
        /// Numbers stored as text, counted anyway (Excel's SUM would skip them).
        public var textNumbers: Int
    }

    public struct Groups: Sendable {
        /// Heading of the text column ("Kategorie") and of the number column summed per value.
        public var by: String
        public var of: String
        /// Name, sum, rows; largest sum first.
        public var items: [(name: String, sum: Double, count: Int)]
    }

    public struct Result: Sendable {
        public var columns: [Column]
        public var groups: Groups?
        public var isEmpty: Bool { columns.isEmpty }
    }

    /// Facts of one sheet; empty without a heading row or without a number column.
    public static func compute(_ grid: SheetGrid) -> Result {
        let layout = SheetLayout.detect(grid)
        guard layout.headerRow != nil else { return Result(columns: [], groups: nil) }
        let first = layout.firstDataRow(in: grid)
        let rows = (first <= grid.lastRow ? Array(first...grid.lastRow) : []).filter { r in
            !layout.isTotalRow(r, in: grid) && grid.columnNumbers.contains { !grid[r, $0].value.isEmpty }
        }
        var columns: [Column] = []
        var numberColumns: [Int] = []
        for c in grid.columnNumbers {
            guard columns.count < maxColumns, let heading = layout.heading(column: c, in: grid), !isIdentifier(heading) else { continue }
            let numbers = rows.compactMap { r in grid[r, c].value.anyNumber.map { (row: r, value: $0, text: grid[r, c].value.number == nil) } }
            // Two numbers at least, not a column of years, and mostly numbers (not a text column with a stray number).
            let filled = rows.filter { !grid[$0, c].value.isEmpty }.count
            guard numbers.count >= 2, numbers.count * 2 > filled, !numbers.allSatisfy({ SheetLayout.isYear($0.value) }) else { continue }
            let low = numbers.min { $0.value < $1.value }!, high = numbers.max { $0.value < $1.value }!
            columns.append(Column(heading: heading, sum: numbers.reduce(0) { $0 + $1.value }, count: numbers.count,
                                  smallest: (low.row, low.value, layout.label(row: low.row, before: c, in: grid)),
                                  largest: (high.row, high.value, layout.label(row: high.row, before: c, in: grid)),
                                  textNumbers: numbers.filter { $0.text }.count))
            numberColumns.append(c)
        }
        guard let valueColumn = numberColumns.first else { return Result(columns: [], groups: nil) }

        // The text column that repeats the fewest values (a category), summing the first number column per value.
        var groups: Groups?
        var bestRatio = 1.0
        for c in grid.columnNumbers where !numberColumns.contains(c) {
            guard let heading = layout.heading(column: c, in: grid) else { continue }
            let names = rows.compactMap { r -> String? in
                grid[r, valueColumn].value.anyNumber == nil ? nil : grid[r, c].value.label.map(SheetLayout.clean)
            }
            guard names.count >= 4 else { continue }
            var order: [String] = []
            var sums: [String: Double] = [:], counts: [String: Int] = [:]
            for r in rows {
                guard let n = grid[r, valueColumn].value.anyNumber, let name = grid[r, c].value.label.map(SheetLayout.clean) else { continue }
                if sums[name] == nil { order.append(name) }
                sums[name, default: 0] += n
                counts[name, default: 0] += 1
            }
            let ratio = Double(order.count) / Double(names.count)
            guard (2...maxGroups).contains(order.count), order.count < names.count, ratio < bestRatio else { continue }
            bestRatio = ratio
            let items = order.map { (name: $0, sum: sums[$0] ?? 0, count: counts[$0] ?? 0) }.sorted { $0.sum > $1.sum }
            groups = Groups(by: heading, of: columns[0].heading, items: items)
        }
        return Result(columns: columns, groups: groups)
    }

    /// Headings of numbers that are not amounts ("Nr.", "Rechnungsnummer", "PLZ", "Jahr", "ID").
    public static func isIdentifier(_ heading: String) -> Bool {
        // Percentages, rates and unit prices too: their sum means nothing ("MwSt %", "Steuersatz", "Einzelpreis").
        if heading.contains("%") { return true }
        let words = heading.lowercased().split { !$0.isLetter }.map(String.init)
        let names: Set<String> = ["nr", "no", "nummer", "number", "id", "plz", "postleitzahl", "tel", "telefon", "phone", "jahr", "year",
                                  "monat", "month", "kw", "pos", "iban", "prozent", "percent", "anteil", "satz", "steuersatz", "zinssatz", "mwstsatz", "stk", "einzelpreis",
                                  "stückpreis"]
        return words.contains { names.contains($0) || $0.hasSuffix("nummer") || $0.hasSuffix("nr") }
    }

    /// Lines for the model, fixed German like the rest of what Pippa's reader returns; numbers in `locale`.
    public static func lines(_ result: Result, locale: Locale = .current) -> [String] {
        func n(_ value: Double) -> String { SheetCheck.format(value, locale: locale) }
        func at(_ row: Int, _ label: String?) -> String { label.map { "Zeile \(row), \($0)" } ?? "Zeile \(row)" }
        var lines: [String] = []
        for column in result.columns {
            var line = "„\(column.heading)“: Summe \(n(column.sum)) aus \(column.count) Zeilen; kleinster Wert \(n(column.smallest.value)) "
                + "(\(at(column.smallest.row, column.smallest.label))), größter \(n(column.largest.value)) (\(at(column.largest.row, column.largest.label)))."
            if column.textNumbers > 0 { line += " Davon \(column.textNumbers) als Text gespeichert; Excel zählt sie in SUMME nicht mit." }
            lines.append(line)
        }
        if let groups = result.groups {
            let items = groups.items.map { "\($0.name) \(n($0.sum)) (\($0.count))" }.joined(separator: "; ")
            lines.append("„\(groups.of)“ nach „\(groups.by)“ (Summe, Zeilen): \(items).")
        }
        return lines
    }
}
