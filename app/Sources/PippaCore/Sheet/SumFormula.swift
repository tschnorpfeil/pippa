import Foundation

/// Recognizes formulas that only add: `=SUM(F2:F10)`, `=SUMME(F2:F10;F12)`, `=SUBTOTAL(9,F2:F10)`,
/// `=TEILERGEBNIS(9;F2:F10)` and `=F2+F3+F4`. Everything else (references to other sheets, multiplication,
/// nested functions) is not a sum Pippa recomputes.
public struct SumFormula: Sendable, Hashable {
    public enum Kind: String, Sendable { case sum, plus, subtotal }

    public var kind: Kind
    /// The added ranges, as they stand in the formula.
    public var areas: [CellArea]

    public init(kind: Kind, areas: [CellArea]) { self.kind = kind; self.areas = areas }

    /// SUM skips numbers stored as text; "+" includes them.
    public var skipsTextNumbers: Bool { kind != .plus }

    public static func parse(_ formula: String) -> SumFormula? {
        var s = formula.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("=") else { return nil }
        s.removeFirst()
        s = s.replacingOccurrences(of: " ", with: "").uppercased()
        guard !s.isEmpty, !s.contains("!"), !s.contains("[") else { return nil }
        for name in ["SUMME(", "SUM(", "SUBTOTAL(", "TEILERGEBNIS("] where s.hasPrefix(name) {
            guard s.hasSuffix(")") else { return nil }
            let inner = String(s.dropFirst(name.count).dropLast())
            guard !inner.contains("("), !inner.contains(")") else { return nil }
            var args = inner.split(whereSeparator: { $0 == "," || $0 == ";" }).map(String.init)
            if name == "SUBTOTAL(" || name == "TEILERGEBNIS(" {
                // Only the function numbers for "sum" (9, and 109 without hidden rows).
                guard let code = args.first, code == "9" || code == "109" else { return nil }
                args.removeFirst()
            }
            let areas = args.compactMap(area)
            guard !areas.isEmpty, areas.count == args.count else { return nil }
            // SUBTOTAL depends on filters, hidden rows and contained subtotals.
            // The grid read provides none of that; don't treat it as an ordinary SUM.
            let kind: Kind = name == "SUBTOTAL(" || name == "TEILERGEBNIS(" ? .subtotal : .sum
            return SumFormula(kind: kind, areas: areas)
        }
        let terms = s.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard terms.count >= 2 else { return nil }
        let areas = terms.compactMap(area)
        guard areas.count == terms.count else { return nil }
        return SumFormula(kind: .plus, areas: areas)
    }

    /// "F2:F10", "$F$2", no whole columns or rows (nobody names those as the sum of a list).
    private static func area(_ text: String) -> CellArea? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ CellRef(a1: String($0)) != nil }) else { return nil }
        return CellArea(a1: text)
    }
}
