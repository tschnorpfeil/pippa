import Foundation

// Sheet (what Pippa reads from Excel, as plain values). No AppKit, no Apple Events:
// ExcelScript (Integrations/ExcelScript.swift) fills it, SheetCheck checks it, the checks build it by hand.
// Rows and columns count from 1 as in Excel (A = 1). Addresses are meant only for "Details" and the model;
// what the person reads names the heading and the row label.

/// Content of a cell, as Excel delivers it.
public enum SheetValue: Sendable, Hashable {
    case empty
    case number(Double)
    case text(String)
    case bool(Bool)
    case date(Date)

    public var number: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    /// Trimmed text; nil for empty text and for anything that is not text.
    public var text: String? {
        guard case .text(let s) = self else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    public var isEmpty: Bool {
        switch self {
        case .empty: true
        case .text(let s): s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default: false
        }
    }

    /// Text that looks like a number ("12,50", "1.234,56 €", "1,234.56"): stored as text in the sheet,
    /// a sum does not count it.
    public var numberInText: Double? { text.flatMap(SheetNumber.parse) }

    /// Real number or number as text.
    public var anyNumber: Double? { number ?? numberInText }

    /// Text that is not a number (label, heading).
    public var label: String? {
        guard let t = text, SheetNumber.parse(t) == nil, !t.hasPrefix("#") else { return nil }
        return t
    }
}

/// Read numbers from text, written in German or English style.
public enum SheetNumber {
    private static let digits = CharacterSet(charactersIn: "0123456789")
    /// Digits, separators, signs, spaces and the letters of the allowed currencies (€, EUR, $, USD, CHF, £).
    private static let allowed = CharacterSet(charactersIn: "0123456789.,+-−'€$£EURSDCHF \u{00A0}\u{202F}\t\n\r")
    /// "12,50" → 12.5, "1.234,56 €" → 1234.56, "1,234.56" → 1234.56, "-3" → -3.
    /// nil for dates ("01.10.2026"), phone numbers with a leading zero and anything with letters.
    public static func parse(_ raw: String) -> Double? {
        // Quick exclusion before the replacements: labels ("Miete", "Zeile 12") are the rule, and the check
        // asks every cell several times (4000 cells under a second, also in the CI debug build).
        guard raw.unicodeScalars.allSatisfy({ Self.allowed.contains($0) }), raw.unicodeScalars.contains(where: { Self.digits.contains($0) })
        else { return nil }
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for symbol in ["€", "EUR", "$", "USD", "CHF", "£"] { s = s.replacingOccurrences(of: symbol, with: "") }
        for space in [" ", "\u{00A0}", "\u{202F}", "'"] { s = s.replacingOccurrences(of: space, with: "") }
        var negative = false
        if s.hasPrefix("-") || s.hasPrefix("−") { negative = true; s.removeFirst() } else if s.hasPrefix("+") { s.removeFirst() }
        guard let first = s.first, first.isASCII, first.isNumber,
              s.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") }) else { return nil }
        let dots = s.filter { $0 == "." }.count
        let commas = s.filter { $0 == "," }.count
        var decimal: Character?
        var thousands: Character?
        if dots > 0 && commas > 0 {
            guard let lastDot = s.lastIndex(of: "."), let lastComma = s.lastIndex(of: ",") else { return nil }
            decimal = lastDot > lastComma ? "." : ","
            thousands = decimal == "." ? "," : "."
            guard s.filter({ $0 == decimal }).count == 1 else { return nil }
        } else if dots + commas > 0 {
            let separator: Character = dots > 0 ? "." : ","
            let parts = s.split(separator: separator, omittingEmptySubsequences: false)
            if parts.count == 2 && parts[1].count != 3 { decimal = separator } else { thousands = separator }
        }
        var integerPart = Substring(s)
        var fraction = Substring("")
        if let decimal, let index = s.lastIndex(of: decimal) {
            integerPart = s[s.startIndex..<index]
            fraction = s[s.index(after: index)...]
            guard !fraction.isEmpty, !fraction.contains(where: { !$0.isNumber }) else { return nil }
        }
        if let thousands {
            let groups = integerPart.split(separator: thousands, omittingEmptySubsequences: false)
            guard let head = groups.first, (1...3).contains(head.count),
                  groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
            integerPart = Substring(groups.joined())
        }
        guard !integerPart.isEmpty, integerPart.allSatisfy(\.isNumber) else { return nil }
        // Leading zero on a multi-digit number without a comma: more likely a phone or customer number.
        if integerPart.count > 1 && integerPart.hasPrefix("0") && fraction.isEmpty && thousands == nil { return nil }
        guard let value = Double(fraction.isEmpty ? String(integerPart) : "\(integerPart).\(fraction)") else { return nil }
        return negative ? -value : value
    }
}

/// A cell as row and column (from 1).
public struct CellRef: Sendable, Hashable, Comparable, CustomStringConvertible {
    public var row: Int
    public var column: Int

    public init(row: Int, column: Int) { self.row = row; self.column = column }

    /// "F11" or "$F$11".
    public init?(a1: String) {
        let s = a1.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces).uppercased()
        let letters = s.prefix { $0.isASCII && $0.isLetter }
        let digits = s.dropFirst(letters.count)
        guard (1...3).contains(letters.count), !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let column = Self.columnNumber(String(letters)), let row = Int(digits),
              (1...CellArea.maxRow).contains(row) else { return nil }
        self.init(row: row, column: column)
    }

    public var a1: String { Self.columnName(column) + String(row) }
    public var description: String { a1 }

    /// 1 → "A", 27 → "AA".
    public static func columnName(_ column: Int) -> String {
        var n = max(column, 1)
        var out = ""
        while n > 0 {
            let r = (n - 1) % 26
            out = String(UnicodeScalar(UInt8(65 + r))) + out
            n = (n - 1) / 26
        }
        return out
    }

    /// "A" → 1, "AA" → 27; nil outside A…XFD.
    public static func columnNumber(_ letters: String) -> Int? {
        var n = 0
        for c in letters.uppercased().unicodeScalars {
            guard (65...90).contains(c.value) else { return nil }
            n = n * 26 + Int(c.value - 64)
        }
        return (1...CellArea.maxColumn).contains(n) ? n : nil
    }

    public static func < (a: CellRef, b: CellRef) -> Bool { (a.row, a.column) < (b.row, b.column) }
}

/// A rectangular range, both edges included.
public struct CellArea: Sendable, Hashable, CustomStringConvertible {
    public static let maxRow = 1_048_576
    public static let maxColumn = 16_384

    public var top: Int
    public var left: Int
    public var bottom: Int
    public var right: Int

    public init(top: Int, left: Int, bottom: Int, right: Int) {
        self.top = min(top, bottom); self.bottom = max(top, bottom)
        self.left = min(left, right); self.right = max(left, right)
    }

    public init(_ a: CellRef, _ b: CellRef) { self.init(top: a.row, left: a.column, bottom: b.row, right: b.column) }

    /// First part of an Excel address: "$F$2:$F$10", "B3", "F:F" (whole column), "2:4" (whole rows),
    /// "'Kosten 2026'!A1:B2" (sheet name ignored), "A1:B2,D4" (only "A1:B2").
    public init?(a1: String) {
        var s = a1.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
        if let bang = s.lastIndex(of: "!") { s = String(s[s.index(after: bang)...]) }
        s = s.replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespaces).uppercased()
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 2 else { return nil }
        if let a = CellRef(a1: parts[0]) {
            if parts.count == 1 { self.init(a, a); return }
            guard let b = CellRef(a1: parts[1]) else { return nil }
            self.init(a, b)
        } else if parts.count == 2, let a = CellRef.columnNumber(parts[0]), let b = CellRef.columnNumber(parts[1]) {
            self.init(top: 1, left: a, bottom: Self.maxRow, right: b)
        } else if parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]),
                  (1...Self.maxRow).contains(a), (1...Self.maxRow).contains(b) {
            self.init(top: a, left: 1, bottom: b, right: Self.maxColumn)
        } else {
            return nil
        }
    }

    public var topLeft: CellRef { CellRef(row: top, column: left) }
    public var bottomRight: CellRef { CellRef(row: bottom, column: right) }
    public var rowCount: Int { bottom - top + 1 }
    public var columnCount: Int { right - left + 1 }
    public var cellCount: Int { rowCount * columnCount }
    public var isSingleCell: Bool { top == bottom && left == right }

    public var a1: String { isSingleCell ? topLeft.a1 : "\(topLeft.a1):\(bottomRight.a1)" }
    public var description: String { a1 }

    public func contains(_ ref: CellRef) -> Bool {
        (top...bottom).contains(ref.row) && (left...right).contains(ref.column)
    }

    public func contains(_ other: CellArea) -> Bool {
        top <= other.top && left <= other.left && bottom >= other.bottom && right >= other.right
    }

    public func intersection(_ other: CellArea) -> CellArea? {
        let t = max(top, other.top), b = min(bottom, other.bottom)
        let l = max(left, other.left), r = min(right, other.right)
        guard t <= b, l <= r else { return nil }
        return CellArea(top: t, left: l, bottom: b, right: r)
    }

    public func intersects(_ other: CellArea) -> Bool { intersection(other) != nil }

    /// All cells row by row. Meant only for small ranges (inside a read grid).
    public var cells: [CellRef] {
        (top...bottom).flatMap { row in (left...right).map { CellRef(row: row, column: $0) } }
    }
}

/// A cell: value and, if present, formula (always with a leading "=").
public struct SheetCell: Sendable, Hashable {
    public var value: SheetValue
    public var formula: String?

    /// `formula` without a leading "=" does not count as a formula (for fixed values Excel returns the value as text).
    public init(_ value: SheetValue = .empty, formula: String? = nil) {
        self.value = value
        let f = formula?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.formula = f.hasPrefix("=") && f.count > 1 ? f : nil
    }

    public static let empty = SheetCell()
}

/// A rectangular excerpt of a sheet. `origin` is the top-left cell.
public struct SheetGrid: Sendable, Hashable {
    public private(set) var origin: CellRef
    /// Row by row, all rows the same length (padded with empty cells on creation).
    public private(set) var rows: [[SheetCell]]

    public init(origin: CellRef = CellRef(row: 1, column: 1), rows: [[SheetCell]]) {
        let width = rows.map(\.count).max() ?? 0
        self.origin = origin
        self.rows = rows.map { $0 + Array(repeating: SheetCell.empty, count: width - $0.count) }
    }

    public var rowCount: Int { rows.count }
    public var columnCount: Int { rows.first?.count ?? 0 }
    public var isEmpty: Bool { rowCount == 0 || columnCount == 0 }

    public var firstRow: Int { origin.row }
    public var lastRow: Int { origin.row + rowCount - 1 }
    public var firstColumn: Int { origin.column }
    public var lastColumn: Int { origin.column + columnCount - 1 }

    /// The grid's range; nil if it is empty.
    public var area: CellArea? {
        isEmpty ? nil : CellArea(top: firstRow, left: firstColumn, bottom: lastRow, right: lastColumn)
    }

    public func contains(_ ref: CellRef) -> Bool { area?.contains(ref) ?? false }
    public func covers(_ other: CellArea) -> Bool { area?.contains(other) ?? false }

    /// Cell at `ref`; empty outside the grid.
    public subscript(ref: CellRef) -> SheetCell {
        guard contains(ref) else { return .empty }
        return rows[ref.row - origin.row][ref.column - origin.column]
    }

    public subscript(row: Int, column: Int) -> SheetCell { self[CellRef(row: row, column: column)] }

    public var rowNumbers: ClosedRange<Int> { firstRow...max(firstRow, lastRow) }
    public var columnNumbers: ClosedRange<Int> { firstColumn...max(firstColumn, lastColumn) }
}

/// What Pippa read on the call into Excel.
public struct SheetSnapshot: Sendable, Hashable {
    /// Name of the workbook as Excel names it ("Kosten 2026.xlsx").
    public var workbook: String
    /// Name of the sheet ("2026").
    public var sheet: String
    /// The person's selection (first part), if Excel could name it.
    public var selection: CellArea?
    /// Excerpt read: the selection with its headings and the rows below, or the used range.
    public var grid: SheetGrid
    /// The excerpt is smaller than what was meant (at most `ExcelScript.maxCells` cells).
    public var isClipped: Bool

    public init(workbook: String, sheet: String, selection: CellArea?, grid: SheetGrid, isClipped: Bool = false) {
        self.workbook = workbook; self.sheet = sheet; self.selection = selection; self.grid = grid; self.isClipped = isClipped
    }

    /// Name of the sheet for humans: without file extension.
    public var tableName: String {
        let name = workbook.trimmingCharacters(in: .whitespaces)
        for ext in [".xlsx", ".xlsm", ".xlsb", ".xls", ".csv", ".numbers"] where name.lowercased().hasSuffix(ext) {
            return String(name.dropLast(ext.count))
        }
        return name
    }

    /// The sheet as text for the model (questions, "Compare with last year" without two matching columns):
    /// per row address and cells, formulas in square brackets. For the model only, never for the person.
    public func contextText(maxRows: Int = 300) -> String {
        var lines = ["Table: \(tableName)", "Sheet: \(sheet)"]
        if let selection { lines.append("Selected: \(selection.a1)") }
        if grid.isEmpty { return lines.joined(separator: "\n") }
        let header = grid.columnNumbers.map { CellRef.columnName($0) }.joined(separator: "\t")
        lines.append("Row\t" + header)
        for row in grid.rowNumbers.prefix(maxRows) {
            let cells = grid.columnNumbers.map { column -> String in
                let cell = grid[row, column]
                let shown = SheetText.plain(cell.value)
                if let formula = cell.formula { return "\(shown) [\(formula)]" }
                return shown
            }
            guard cells.contains(where: { !$0.isEmpty }) else { continue }
            lines.append("\(row)\t" + cells.joined(separator: "\t"))
        }
        if grid.rowCount > maxRows || isClipped { lines.append("(more rows not shown)") }
        return lines.joined(separator: "\n")
    }
}

/// Values as plain text (for the model and for headings made from numbers like "2025").
enum SheetText {
    static func plain(_ value: SheetValue) -> String {
        switch value {
        case .empty: return ""
        case .text(let s): return s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .number(let n):
            if n.rounded() == n && abs(n) < 1e15 { return String(Int64(n)) }
            return String(n)
        case .date(let d):
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: d)
        }
    }
}
