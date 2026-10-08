import Foundation

/// Where in a grid the headings and the row labels are. Pure code, no assumption about the language
/// except the words for total rows (German and English).
public struct SheetLayout: Sendable, Hashable {
    /// Row with the column headings ("Posten | Betrag"), nil if none is recognizable.
    public var headerRow: Int?
    /// Column with the row labels ("Miete", "Strom" ...), nil if none is recognizable.
    public var labelColumn: Int?

    public init(headerRow: Int?, labelColumn: Int?) { self.headerRow = headerRow; self.labelColumn = labelColumn }

    /// Recognizes the heading row (in the first five rows: at least two headings, no numbers other than
    /// years, numbers below) and the label column (first column whose entries below the headings
    /// are mostly text).
    public static func detect(_ grid: SheetGrid) -> SheetLayout {
        guard !grid.isEmpty else { return SheetLayout(headerRow: nil, labelColumn: nil) }
        var header: Int?
        for row in grid.firstRow...min(grid.lastRow, grid.firstRow + 4) {
            var labels = 0, years = 0, numbers = 0
            for column in grid.columnNumbers {
                let value = grid[row, column].value
                if value.label != nil { labels += 1 } else if let n = value.anyNumber { if isYear(n) { years += 1 } else { numbers += 1 } }
            }
            let enough = labels >= 1 && (labels + years >= 2 || grid.columnCount == 1)
            guard enough, numbers == 0, row < grid.lastRow else { continue }
            let numbersBelow = (row + 1...grid.lastRow).contains { r in
                grid.columnNumbers.contains { c in grid[r, c].value.anyNumber != nil }
            }
            if numbersBelow { header = row; break }
        }
        let firstData = (header ?? grid.firstRow - 1) + 1
        var labelColumn: Int?
        if firstData <= grid.lastRow {
            for column in grid.columnNumbers {
                var labels = 0, filled = 0
                for row in firstData...grid.lastRow {
                    let value = grid[row, column].value
                    if value.isEmpty { continue }
                    filled += 1
                    if value.label != nil { labels += 1 }
                }
                if labels >= 1 && labels * 2 >= filled { labelColumn = column; break }
            }
        }
        return SheetLayout(headerRow: header, labelColumn: labelColumn)
    }

    /// First row with data (below the heading).
    public func firstDataRow(in grid: SheetGrid) -> Int { headerRow.map { $0 + 1 } ?? grid.firstRow }

    /// Heading of the column ("Betrag", "2025"), nil without a heading row or with an empty cell.
    public func heading(column: Int, in grid: SheetGrid) -> String? {
        guard let headerRow else { return nil }
        let value = grid[headerRow, column].value
        if let label = value.label { return Self.clean(label) }
        if let n = value.anyNumber, Self.isYear(n) { return String(Int(n)) }
        return nil
    }

    /// Label of the row: the text in the label column, otherwise the first text left of `column`
    /// (or in the whole row if `column` is nil).
    public func label(row: Int, before column: Int? = nil, in grid: SheetGrid) -> String? {
        if let labelColumn, labelColumn != column, let label = grid[row, labelColumn].value.label { return Self.clean(label) }
        let end = column.map { $0 - 1 } ?? grid.lastColumn
        guard end >= grid.firstColumn else { return nil }
        for c in grid.firstColumn...end {
            if let label = grid[row, c].value.label { return Self.clean(label) }
        }
        return nil
    }

    /// Is there a word for a sum in the row ("Summe", "Gesamt", "Total" ...)?
    public func isTotalRow(_ row: Int, in grid: SheetGrid) -> Bool {
        guard let label = label(row: row, in: grid) else { return false }
        return Self.isTotalLabel(label)
    }

    /// Words for total rows, German and English.
    public static func isTotalLabel(_ text: String) -> Bool {
        let s = clean(text).lowercased()
        guard !s.isEmpty else { return false }
        if totalWords.contains(s) { return true }
        let first = s.split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "-" }).first.map(String.init) ?? s
        if totalWords.contains(first) { return true }
        return s.hasPrefix("gesamt") || s.hasSuffix(" total") || s.hasSuffix("summe") || s.hasPrefix("summe ")
    }

    private static let totalWords: Set<String> = [
        "total", "totals", "sum", "summe", "summen", "gesamt", "gesamtsumme", "insgesamt", "zwischensumme", "subtotal",
        "sub-total", "endsumme", "gesamtbetrag", "grand total", "summe gesamt",
    ]

    static func isYear(_ n: Double) -> Bool { n.rounded() == n && (1900...2100).contains(n) }

    static func clean(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(":") { s.removeLast(); s = s.trimmingCharacters(in: .whitespaces) }
        return s
    }
}
