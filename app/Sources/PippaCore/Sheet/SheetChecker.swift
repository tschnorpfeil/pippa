import Foundation

// MARK: - Recomputing

/// A possible total before recomputing.
struct TotalCandidate {
    enum Kind {
        case formula(SumFormula)
        /// Typed number in a total row; adds the column above from `blockStart`.
        case labelled(blockStart: Int)
    }
    var cell: CellRef
    var kind: Kind

    var areas: [CellArea] {
        switch kind {
        case .formula(let f): return f.areas
        case .labelled(let start): return start < cell.row ? [CellArea(top: start, left: cell.column, bottom: cell.row - 1, right: cell.column)] : []
        }
    }

    func touches(_ focus: CellArea) -> Bool { focus.contains(cell) || areas.contains { $0.intersects(focus) } }
}

/// Direction of a total: down a column or along a row.
private enum Axis { case column(Int), row(Int) }

struct Checker {
    let grid: SheetGrid
    let layout: SheetLayout
    let locale: Locale
    var totals: [SheetTotal] = []
    var findings: [SheetFinding] = []
    /// Report each number stored as text only once, even if several totals contain it.
    var reportedText: Set<CellRef> = []

    init(grid: SheetGrid, layout: SheetLayout, locale: Locale) { self.grid = grid; self.layout = layout; self.locale = locale }

    private var firstData: Int { layout.firstDataRow(in: grid) }

    // MARK: Candidates

    func candidates() -> [TotalCandidate] {
        var out: [TotalCandidate] = []
        for row in grid.rowNumbers {
            for column in grid.columnNumbers {
                let cell = grid[row, column]
                if let formula = cell.formula, let sum = SumFormula.parse(formula) {
                    out.append(TotalCandidate(cell: CellRef(row: row, column: column), kind: .formula(sum)))
                }
            }
        }
        // Total rows with typed numbers (no formula). Other formulas (average, percent …) are left out.
        for row in grid.rowNumbers where row > firstData && layout.isTotalRow(row, in: grid) {
            let start = blockStart(above: row)
            for column in grid.columnNumbers where column != layout.labelColumn {
                let cell = grid[row, column]
                guard cell.formula == nil, cell.value.number != nil else { continue }
                // Numbers above (since the header): also a grand total directly below the last subtotal.
                let hasNumbers = (firstData..<row).contains { r in
                    !layout.isTotalRow(r, in: grid) && grid[r, column].value.anyNumber != nil
                }
                guard hasNumbers else { continue }
                out.append(TotalCandidate(cell: CellRef(row: row, column: column), kind: .labelled(blockStart: start)))
            }
        }
        return out.sorted { $0.cell < $1.cell }
    }

    /// First row of the block above a total row: after the last total row above, otherwise the first data row.
    private func blockStart(above row: Int) -> Int {
        var r = row - 1
        while r >= firstData {
            if layout.isTotalRow(r, in: grid) { return r + 1 }
            r -= 1
        }
        return firstData
    }

    // MARK: Evaluating

    mutating func evaluate(_ candidate: TotalCandidate) {
        switch candidate.kind {
        case .formula(let formula): evaluateFormula(candidate.cell, formula)
        case .labelled(let start): evaluateLabelled(candidate.cell, blockStart: start)
        }
    }

    private mutating func evaluateFormula(_ cell: CellRef, _ formula: SumFormula) {
        let axis = Self.axis(of: formula.areas)
        let name = totalName(cell: cell, axis: axis)
        let value = grid[cell].value.number
        let inside = formula.areas.allSatisfy { grid.covers($0) }
        var total = SheetTotal(cell: cell, source: .formula, name: name, formula: grid[cell].formula, value: value,
                               recomputed: nil, covered: formula.areas)
        guard inside else {
            unverified(total, sentence: L("I couldn’t check this total because some of its numbers are outside the part I read.", table: "Sheet"))
            return
        }
        guard formula.kind != .subtotal else {
            unverified(total, sentence: L("This total depends on which rows are visible. I couldn’t check that here.", table: "Sheet"))
            return
        }
        // The formula may count the same cell several times. Deduplicate only for the search for omitted cells.
        let coveredCells = formula.areas.flatMap(\.cells)
        guard let value, value.isFinite, !coveredCells.contains(cell) else {
            unverified(total, sentence: L("I couldn’t check this total because it contains an error or a value I can’t add safely.", table: "Sheet"))
            return
        }
        var sum = 0.0
        var textCells: [CellRef] = []
        for ref in coveredCells {
            let v = grid[ref].value
            if case .date = v {
                unverified(total, sentence: L("I couldn’t check this total because it contains an error or a value I can’t add safely.", table: "Sheet"))
                return
            }
            if v.text?.hasPrefix("#") == true || (grid[ref].formula != nil && v.isEmpty)
                || (!formula.skipsTextNumbers && v.text != nil && v.numberInText == nil) {
                unverified(total, sentence: L("I couldn’t check this total because it contains an error or a value I can’t add safely.", table: "Sheet"))
                return
            }
            if let n = v.number { sum += n } else if let n = v.numberInText {
                if formula.skipsTextNumbers { textCells.append(ref) } else { sum += n }
            } else if !formula.skipsTextNumbers, case .bool(let flag) = v {
                sum += flag ? 1 : 0
            }
        }
        guard sum.isFinite else {
            unverified(total, sentence: L("I couldn’t check this total because it contains an error or a value I can’t add safely.", table: "Sheet"))
            return
        }
        total.recomputed = sum
        totals.append(total)

        // Omitted rows (or columns for a total along a row).
        if let axis {
            let missing = missingCells(total: cell, covered: Set(coveredCells), axis: axis)
            if !missing.isEmpty {
                let extra = missing.compactMap { grid[$0].value.anyNumber }.reduce(0, +)
                let expected = sum + extra
                let items = missing.map { itemName($0, axis: axis) }
                let list = Self.join(items, locale: locale)
                var sentence = name.map { L("The total for “%@” leaves out %@.", table: "Sheet", $0, list) }
                    ?? L("This total leaves out %@.", table: "Sheet", list)
                let amount = SheetCheck.format(expected, locale: locale)
                sentence += " " + (missing.count == 1 ? L("With it, the total would be %@.", table: "Sheet", amount)
                                                      : L("With them, the total would be %@.", table: "Sheet", amount))
                findings.append(SheetFinding(kind: .missingRows, total: cell, cells: missing, sentence: sentence, expected: expected))
            }
        }
        if !SheetCheck.same(value, sum) {
            findings.append(mismatch(cell, name: name, value: value, numbers: sum))
        }
        reportText(textCells, total: cell)
    }

    private mutating func unverified(_ total: SheetTotal, sentence: String) {
        totals.append(total)
        findings.append(SheetFinding(kind: .unverified, total: total.cell, cells: [total.cell], sentence: sentence, expected: nil))
    }

    private mutating func evaluateLabelled(_ cell: CellRef, blockStart: Int) {
        let column = cell.column
        let name = layout.heading(column: column, in: grid)
        guard let value = grid[cell].value.number else { return }
        func sums(_ rows: [Int]) -> (numbers: Double, withText: Double, text: [CellRef]) {
            var numbers = 0.0, withText = 0.0, text: [CellRef] = []
            for r in rows {
                let v = grid[r, column].value
                if let n = v.number { numbers += n; withText += n } else if let n = v.numberInText {
                    withText += n; text.append(CellRef(row: r, column: column))
                }
            }
            return (numbers, withText, text)
        }
        let isTotal: (Int) -> Bool = { [layout, grid] r in layout.isTotalRow(r, in: grid) }
        let block = blockStart < cell.row ? (blockStart..<cell.row).filter { !isTotal($0) } : []
        let all = firstData < cell.row ? (firstData..<cell.row).filter { !isTotal($0) } : []
        let earlierTotals = firstData < blockStart ? (firstData..<blockStart).filter(isTotal) : []
        let covered = block.first.map { [CellArea(top: $0, left: column, bottom: block.last ?? $0, right: column)] } ?? []
        let unsafe = (all + earlierTotals).contains { row in
            let source = grid[row, column]
            if case .date = source.value { return true }
            return source.value.text?.hasPrefix("#") == true || source.value.number.map { !$0.isFinite } == true
                || (source.formula != nil && source.value.isEmpty)
        }
        guard value.isFinite, !unsafe else {
            unverified(SheetTotal(cell: cell, source: .labelledRow, name: name, formula: nil, value: value,
                                 recomputed: nil, covered: covered),
                       sentence: L("I couldn’t check this total because it contains an error or a value I can’t add safely.", table: "Sheet"))
            return
        }
        let a = sums(block), b = sums(all), c = sums(earlierTotals)
        // A grand total may add the subtotals or all rows; both are correct.
        let options = [a.numbers, a.withText, b.numbers, b.withText, c.numbers + a.numbers, c.numbers + a.withText]
        // What "the numbers above" add up to: the block since the last total row, or the subtotals if the
        // block is empty (grand total directly below the last subtotal).
        let mainNumbers = (earlierTotals.isEmpty || !block.isEmpty) ? a.withText : c.numbers
        let matches = options.contains { SheetCheck.same(value, $0) }
        totals.append(SheetTotal(cell: cell, source: .labelledRow, name: name, formula: nil, value: value,
                                 recomputed: mainNumbers, covered: covered))
        if !matches { findings.append(mismatch(cell, name: name, value: value, numbers: mainNumbers)) }
        reportText(a.text, total: cell)
    }

    private func mismatch(_ cell: CellRef, name: String?, value: Double, numbers: Double) -> SheetFinding {
        let says = SheetCheck.format(value, locale: locale), adds = SheetCheck.format(numbers, locale: locale)
        let sentence = name.map { L("The total for “%@” says %@, but its numbers add up to %@.", table: "Sheet", $0, says, adds) }
            ?? L("This total says %@, but its numbers add up to %@.", table: "Sheet", says, adds)
        return SheetFinding(kind: .mismatch, total: cell, cells: [cell], sentence: sentence, expected: numbers)
    }

    private mutating func reportText(_ cells: [CellRef], total: CellRef) {
        // At most five per total; the first line names no count anyway.
        for ref in cells.prefix(5) {
            guard reportedText.insert(ref).inserted else { continue }
            let label = layout.label(row: ref.row, before: ref.column, in: grid)
            let heading = layout.heading(column: ref.column, in: grid)
            let sentence: String
            switch (label, heading) {
            case let (label?, heading?): sentence = L("“%@” in “%@” is stored as text, so sums skip it.", table: "Sheet", label, heading)
            case let (label?, nil): sentence = L("The number for “%@” is stored as text, so sums skip it.", table: "Sheet", label)
            case let (nil, heading?): sentence = L("A number in “%@” is stored as text, so sums skip it.", table: "Sheet", heading)
            case (nil, nil): sentence = L("A number here is stored as text, so sums skip it.", table: "Sheet")
            }
            findings.append(SheetFinding(kind: .textNumber, total: total, cells: [ref], sentence: sentence,
                                         expected: grid[ref].value.numberInText))
        }
    }

    // MARK: Omitted rows

    /// Total along a column (all ranges in the same single column) or a row; otherwise nil.
    private static func axis(of areas: [CellArea]) -> Axis? {
        guard let first = areas.first else { return nil }
        if areas.allSatisfy({ $0.left == first.left && $0.right == first.left }) { return .column(first.left) }
        if areas.allSatisfy({ $0.top == first.top && $0.bottom == first.top }) { return .row(first.top) }
        return nil
    }

    private func totalName(cell: CellRef, axis: Axis?) -> String? {
        switch axis {
        case .column(let c): return layout.heading(column: c, in: grid) ?? layout.heading(column: cell.column, in: grid)
        case .row(let r): return layout.label(row: r, before: cell.column, in: grid)
        case nil: return layout.heading(column: cell.column, in: grid) ?? layout.label(row: cell.row, before: cell.column, in: grid)
        }
    }

    /// Rows with numbers that belong to the list but are not in the total.
    /// If the total is in the same column below (or above) its range, everything in between up to the previous
    /// total row belongs to the list. Otherwise only numbers that connect to the range without a gap.
    private func missingCells(total: CellRef, covered: Set<CellRef>, axis: Axis) -> [CellRef] {
        let setup: (line: Int, positions: ClosedRange<Int>, start: Int, totalPos: Int, sameLine: Bool)
        switch axis {
        case .column(let c):
            setup = (c, grid.rowNumbers, firstData, total.row, total.column == c)
        case .row(let r):
            setup = (r, grid.columnNumbers, (layout.labelColumn ?? grid.firstColumn - 1) + 1, total.column, total.row == r)
        }
        let line = setup.line, positions = setup.positions, start = setup.start
        let totalPos = setup.totalPos, sameLine = setup.sameLine
        func ref(_ p: Int) -> CellRef {
            switch axis {
            case .column: return CellRef(row: p, column: line)
            case .row: return CellRef(row: line, column: p)
            }
        }
        let coveredPositions = covered.compactMap { c -> Int? in
            switch axis {
            case .column: return c.column == line ? c.row : nil
            case .row: return c.row == line ? c.column : nil
            }
        }
        guard let low = coveredPositions.min(), let high = coveredPositions.max() else { return [] }

        func isBoundary(_ p: Int) -> Bool {
            let r = ref(p)
            if r == total { return true }
            if let f = grid[r].formula, SumFormula.parse(f) != nil { return true }
            switch axis {
            case .column: return layout.isTotalRow(p, in: grid)
            case .row: return layout.heading(column: p, in: grid).map(SheetLayout.isTotalLabel) ?? false
            }
        }
        func isData(_ p: Int) -> Bool {
            guard p >= start, positions.contains(p), !isBoundary(p) else { return false }
            let r = ref(p)
            if grid[r].formula != nil && grid[r].value.number == nil { return false }
            return grid[r].value.anyNumber != nil
        }

        var span: [Int] = []
        if sameLine && totalPos > high {
            var from = low
            while from - 1 >= max(start, positions.lowerBound) && !isBoundary(from - 1) { from -= 1 }
            span = Array(from..<totalPos)
        } else if sameLine && totalPos < low {
            var to = high
            while to + 1 <= positions.upperBound && !isBoundary(to + 1) { to += 1 }
            span = Array((totalPos + 1)...to)
        } else {
            var p = low - 1
            while isData(p) { span.append(p); p -= 1 }
            p = high + 1
            while isData(p) { span.append(p); p += 1 }
        }
        return span.filter { !covered.contains(ref($0)) && isData($0) }.sorted().map(ref)
    }

    /// Name of an omitted cell: row label (column total) or header (row total), otherwise its value.
    private func itemName(_ ref: CellRef, axis: Axis) -> String {
        let name: String?
        switch axis {
        case .column: name = layout.label(row: ref.row, before: ref.column, in: grid)
        case .row: name = layout.heading(column: ref.column, in: grid)
        }
        if let name { return L("“%@”", table: "Sheet", name) }
        let amount = grid[ref].value.anyNumber.map { SheetCheck.format($0, locale: locale) } ?? ""
        switch axis {
        case .column: return L("the row with %@", table: "Sheet", amount)
        case .row: return L("the column with %@", table: "Sheet", amount)
        }
    }

    static func join(_ items: [String], locale: Locale) -> String {
        let f = ListFormatter()
        f.locale = locale
        return f.string(from: items) ?? items.joined(separator: ", ")
    }
}
