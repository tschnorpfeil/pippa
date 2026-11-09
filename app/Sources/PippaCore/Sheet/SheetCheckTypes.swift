import Foundation

/// A total that was found.
public struct SheetTotal: Sendable, Hashable {
    public enum Source: String, Sendable {
        /// Formula that only adds (`=SUM(…)`, `=SUMME(…)`, `=F2+F3`).
        case formula
        /// A typed number in a row named "Summe", "Gesamt", "Total" …
        case labelledRow
    }

    public var cell: CellRef
    public var source: Source
    /// Human-readable name of the total: column header (total of a column) or row label (total of a row).
    public var name: String?
    public var formula: String?
    /// What the cell contains.
    public var value: Double?
    /// What Pippa recomputes from the cells (like Excel: for SUM, ignoring numbers stored as text); nil if it cannot be recomputed
    /// (e.g. parts of the total lie outside the part that was read).
    public var recomputed: Double?
    /// The cells the total adds up.
    public var covered: [CellArea]
}

/// A finding about a total.
public struct SheetFinding: Sendable, Hashable {
    public enum Kind: String, Sendable {
        case missingRows, mismatch, textNumber, unverified
    }

    public var kind: Kind
    /// The total the finding belongs to.
    public var total: CellRef
    /// Affected cells: omitted cells, the number stored as text, for `mismatch` the total itself.
    public var cells: [CellRef]
    /// A calm sentence without addresses: "The total for “Betrag” leaves out “Wasser”. With it, the total would be 1,106.69."
    public var sentence: String
    /// For `missingRows`: the total with the omitted rows. For `mismatch`: what the numbers add up to.
    public var expected: Double?

    /// Addresses for "Details" ("B6", "F11"); never in the first line.
    public var addresses: [String] { cells.map(\.a1) }
}

public struct SheetCheckResult: Sendable, Equatable {
    public var layout: SheetLayout
    public var totals: [SheetTotal]
    public var findings: [SheetFinding]
    /// "This total leaves out one row.", "The totals add up.", "I didn’t find a total here."
    public var firstLine: String

    public var foundTotals: Bool { !totals.isEmpty }
}
