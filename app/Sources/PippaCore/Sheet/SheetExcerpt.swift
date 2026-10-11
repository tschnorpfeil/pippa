import Foundation

/// "Show me where": a small piece of the sheet around one finding, which the line draws itself (no Accessibility
/// permission, nothing in Excel moves). The label column and the columns of the finding, the heading row, the rows
/// of the finding and the total row; skipped rows in between become a gap. Marked cells are the finding's cells and
/// the total.
public struct SheetExcerpt: Sendable, Hashable {
    public struct Row: Sendable, Hashable {
        /// Row number in the sheet (for VoiceOver and "Details").
        public var number: Int
        public var cells: [String]
        public var marked: [Bool]
        public var isTotal: Bool
        /// Rows above this one were left out.
        public var gapBefore: Bool
    }

    /// Column headings, "" where a column has none.
    public var headings: [String]
    /// Which columns hold numbers (right-aligned when drawn).
    public var numeric: [Bool]
    public var rows: [Row]

    /// At most this many rows, so the line stays small.
    public static let maxRows = 7
    /// At most this many columns next to the label column.
    public static let maxColumns = 3

    public static func around(_ finding: SheetFinding, in grid: SheetGrid, layout: SheetLayout? = nil,
                              locale: Locale = .current) -> SheetExcerpt? {
        let layout = layout ?? SheetLayout.detect(grid)
        let marked = Set(finding.cells + [finding.total]).filter { grid.contains($0) }
        guard !marked.isEmpty else { return nil }

        // Columns: the label column first, then the columns of the finding, the total's column first among them.
        let findingColumns = [finding.total.column] + marked.map(\.column).sorted()
        var columns: [Int] = []
        for c in findingColumns where !columns.contains(c) && c != layout.labelColumn && columns.count < maxColumns {
            columns.append(c)
        }
        columns.sort()
        if let label = layout.labelColumn, grid.columnNumbers.contains(label) { columns.insert(label, at: 0) }

        // Rows: all data rows when they fit, otherwise the marked rows with one row around each, the total kept.
        let first = layout.firstDataRow(in: grid)
        let markedRows = Set(marked.map(\.row))
        let bottom = max(markedRows.max() ?? first, first)
        let top = min(markedRows.min() ?? first, bottom)
        var wanted: [Int]
        if bottom - min(first, top) + 1 <= maxRows {
            wanted = Array(min(first, top)...bottom)
        } else {
            var set = markedRows
            for r in markedRows { set.insert(r - 1); set.insert(r + 1) }
            wanted = set.filter { $0 >= first && $0 <= bottom && $0 <= grid.lastRow }.sorted()
            // Too many: keep the marked rows (the total last) and drop the context rows.
            if wanted.count > maxRows { wanted = markedRows.sorted() }
            if wanted.count > maxRows {
                let rest = markedRows.subtracting([finding.total.row]).sorted().prefix(maxRows - 1)
                wanted = (Array(rest) + [finding.total.row]).sorted()
            }
        }

        let headings = columns.map { layout.heading(column: $0, in: grid) ?? "" }
        let numeric = columns.map { c in wanted.contains { grid[$0, c].value.anyNumber != nil } && c != layout.labelColumn }
        var rows: [Row] = []
        var previous: Int?
        for r in wanted {
            rows.append(Row(number: r,
                            cells: columns.map { text(grid[r, $0].value, locale: locale) },
                            marked: columns.map { marked.contains(CellRef(row: r, column: $0)) },
                            isTotal: r == finding.total.row || layout.isTotalRow(r, in: grid),
                            gapBefore: previous.map { r > $0 + 1 } ?? (r > first)))
            previous = r
        }
        guard !rows.isEmpty else { return nil }
        return SheetExcerpt(headings: headings, numeric: numeric, rows: rows)
    }

    /// The cell as the person sees it: numbers in the Mac's format, text stays as typed (a number stored as text too).
    static func text(_ value: SheetValue, locale: Locale) -> String {
        switch value {
        case .empty: return ""
        case .number(let n): return SheetCheck.format(n, locale: locale)
        case .text(let s): return s.trimmingCharacters(in: .whitespacesAndNewlines)
        case .bool(let b): return b ? "✓" : "–"
        case .date(let d): return d.formatted(Date.FormatStyle(date: .numeric, time: .omitted).locale(locale))
        }
    }
}
