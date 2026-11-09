import Foundation

// "Check the total": plain code, no model. Finds totals (formulas SUM/SUMME/"+" and rows labeled
// "Summe", "Gesamt" or "Total"), recomputes them from the cell values and reports:
//   - rows a total leaves out (SUM(F2:F10) while the data goes to F11),
//   - totals that do not match their numbers,
//   - numbers stored as text (a total does not count them).
// The sentences name the column header and row label, never an address; addresses appear only in the fields
// (for "Details" and the model).

public enum SheetCheck {
    /// Checks all totals in the grid. With `focus` (the selection), only totals in the selection or adding cells
    /// from it count; if there are none, all in the grid.
    public static func run(_ grid: SheetGrid, focus: CellArea? = nil, locale: Locale = .current) -> SheetCheckResult {
        let layout = SheetLayout.detect(grid)
        var check = Checker(grid: grid, layout: layout, locale: locale)
        let candidates = check.candidates()
        let inFocus = focus.map { area in candidates.filter { $0.touches(area) } } ?? []
        let chosen = inFocus.isEmpty ? candidates : inFocus
        for candidate in chosen { check.evaluate(candidate) }
        let findings = check.findings.sorted { a, b in
            let order: [SheetFinding.Kind] = [.missingRows, .mismatch, .unverified, .textNumber]
            let ia = order.firstIndex(of: a.kind) ?? 0, ib = order.firstIndex(of: b.kind) ?? 0
            return ia != ib ? ia < ib : a.total < b.total
        }
        let line = firstLine(totals: check.totals, findings: findings)
        return SheetCheckResult(layout: layout, totals: check.totals, findings: findings, firstLine: line)
    }

    public static func run(_ snapshot: SheetSnapshot, locale: Locale = .current) -> SheetCheckResult {
        run(snapshot.grid, focus: snapshot.selection, locale: locale)
    }

    /// The first line: the most important finding, otherwise "correct", otherwise "no total found". Without numbers and addresses.
    static func firstLine(totals: [SheetTotal], findings: [SheetFinding]) -> String {
        let text: String
        if totals.isEmpty {
            text = L("I didn’t find a total here.", table: "Sheet")
        } else if let first = findings.first {
            let name = totals.count > 1 ? totals.first(where: { $0.cell == first.total })?.name : nil
            switch first.kind {
            case .missingRows:
                let one = first.cells.count == 1
                if let name {
                    text = one ? L("The total for “%@” leaves out one row.", table: "Sheet", name)
                               : L("The total for “%@” leaves out some rows.", table: "Sheet", name)
                } else {
                    text = one ? L("This total leaves out one row.", table: "Sheet") : L("This total leaves out some rows.", table: "Sheet")
                }
            case .mismatch:
                text = name.map { L("The total for “%@” doesn’t match its numbers.", table: "Sheet", $0) }
                    ?? L("This total doesn’t match its numbers.", table: "Sheet")
            case .textNumber:
                let one = findings.filter { $0.kind == .textNumber }.count == 1
                text = one ? L("One number here is stored as text.", table: "Sheet") : L("Some numbers here are stored as text.", table: "Sheet")
            case .unverified:
                text = L("I couldn’t fully check this total.", table: "Sheet")
            }
        } else if totals.contains(where: { $0.recomputed == nil || $0.value == nil }) {
            text = L("I couldn’t fully check this total.", table: "Sheet")
        } else {
            text = totals.count == 1 ? L("The total adds up.", table: "Sheet") : L("The totals add up.", table: "Sheet")
        }
        return text
    }

    /// Number for sentences: without decimals if whole, otherwise two.
    public static func format(_ value: Double, locale: Locale = .current) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        let whole = abs(value - value.rounded()) < 0.000_5
        f.minimumFractionDigits = whole ? 0 : 2
        f.maximumFractionDigits = whole ? 0 : 2
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= max(0.005, abs(b) * 1e-9) }
}
