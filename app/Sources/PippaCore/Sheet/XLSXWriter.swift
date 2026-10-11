import Foundation

// A real Excel file (.xlsx) instead of CSV: umlauts, separators and decimal commas need no guessing in Excel
// or Numbers, whatever the Mac's language. Plain code: XML parts in a stored ZIP (`ZipWriter`).
// Formulas are written with their cached value, so Quick Look and Numbers show the number before recalculating.

public enum XLSXWriter {
    /// How a number is shown. `money`: "1.234,50" in the reader's language; `date`: the reader's short date.
    public enum Format: Int, Sendable, Hashable, CaseIterable {
        case general, money, date
        var numFmtId: Int { switch self { case .general: 0; case .money: 4; case .date: 14 } }
    }

    public struct Cell: Sendable, Hashable {
        public var value: SheetValue
        /// Without "=" or with it; written as Excel stores it (English function names).
        public var formula: String?
        public var format: Format
        public var bold: Bool
        /// A soft yellow fill: "please check this cell".
        public var highlight: Bool

        public init(_ value: SheetValue = .empty, formula: String? = nil, format: Format = .general, bold: Bool = false, highlight: Bool = false) {
            self.value = value; self.formula = formula; self.format = format; self.bold = bold; self.highlight = highlight
        }

        public static func text(_ s: String, bold: Bool = false, highlight: Bool = false) -> Cell {
            Cell(s.isEmpty ? .empty : .text(s), bold: bold, highlight: highlight)
        }
        public static func number(_ n: Double, format: Format = .general, bold: Bool = false, highlight: Bool = false) -> Cell {
            Cell(.number(n), format: format, bold: bold, highlight: highlight)
        }
    }

    public struct Sheet: Sendable, Hashable {
        public var name: String
        public var rows: [[Cell]]
        /// First row is a heading: bold, frozen while scrolling, with a filter.
        public var headerRow: Bool

        public init(name: String, rows: [[Cell]], headerRow: Bool = true) {
            self.name = name; self.rows = rows; self.headerRow = headerRow
        }

        /// A read sheet as it was: every cell at its own address (empty rows and columns before the excerpt),
        /// values and formulas, no styling. Nil if the excerpt starts too far down or right to pad sensibly.
        public init?(name: String, grid: SheetGrid) {
            guard grid.firstRow <= 1000, grid.firstColumn <= 100 else { return nil }
            let lead = Array(repeating: Cell(), count: grid.firstColumn - 1)
            var rows = Array(repeating: [Cell](), count: grid.firstRow - 1)
            for r in grid.rowNumbers {
                rows.append(lead + grid.columnNumbers.map { c in
                    let cell = grid[r, c]
                    if case .date = cell.value { return Cell(cell.value, formula: cell.formula, format: .date) }
                    return Cell(cell.value, formula: cell.formula)
                })
            }
            self.init(name: name, rows: rows, headerRow: false)
        }
    }

    /// The workbook as file content.
    public static func data(_ sheets: [Sheet]) -> Data {
        let list = sheets.isEmpty ? [Sheet(name: "Tabelle1", rows: [])] : sheets
        var zip = ZipWriter()
        var names: [String] = []
        for sheet in list { names.append(uniqueName(sheetName(sheet.name), in: names)) }
        let types = list.indices.map { #"<Override PartName="/xl/worksheets/sheet\#($0 + 1).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"# }.joined()
        zip.add("[Content_Types].xml", Data((header + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>"# + types + "</Types>").utf8))
        zip.add("_rels/.rels", Data((header + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#).utf8))
        let sheetEntries = names.enumerated().map { #"<sheet name="\#(escape($1))" sheetId="\#($0 + 1)" r:id="rId\#($0 + 1)"/>"# }.joined()
        zip.add("xl/workbook.xml", Data((header + #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>"# + sheetEntries + "</sheets></workbook>").utf8))
        var rels = list.indices.map { #"<Relationship Id="rId\#($0 + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#($0 + 1).xml"/>"# }.joined()
        rels += #"<Relationship Id="rId\#(list.count + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>"#
        zip.add("xl/_rels/workbook.xml.rels", Data((header + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"# + rels + "</Relationships>").utf8))
        zip.add("xl/styles.xml", Data(styles.utf8))
        for (index, sheet) in list.enumerated() {
            zip.add("xl/worksheets/sheet\(index + 1).xml", Data(worksheet(sheet).utf8))
        }
        return zip.finish()
    }

    /// Writes the workbook in one step (temporary file, then moved into place), never half a file.
    public static func write(_ sheets: [Sheet], to url: URL) throws {
        try data(sheets).write(to: url, options: .atomic)
    }

    static let header = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#

    /// Index of the style for a cell: every combination of format, bold and highlight, in this order (see `styles`).
    static func styleIndex(_ cell: Cell) -> Int {
        cell.format.rawValue * 4 + (cell.bold ? 1 : 0) + (cell.highlight ? 2 : 0)
    }

    static let styles: String = {
        var xfs = ""
        for format in Format.allCases {
            // Same order as `styleIndex`: +1 bold, +2 highlight.
            for combo in 0..<4 {
                let bold = combo & 1 != 0, highlight = combo & 2 != 0
                xfs += #"<xf numFmtId="\#(format.numFmtId)" fontId="\#(bold ? 1 : 0)" fillId="\#(highlight ? 2 : 0)" borderId="0" xfId="0" applyNumberFormat="1" applyFont="1" applyFill="1"/>"#
            }
        }
        return header + #"<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="12"/><name val="Calibri"/></font><font><b/><sz val="12"/><name val="Calibri"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFFFF2A8"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="\#(Format.allCases.count * 4)">"# + xfs + #"</cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>"#
    }()

    static func worksheet(_ sheet: Sheet) -> String {
        let width = sheet.rows.map(\.count).max() ?? 0
        var out = header + #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#
        if sheet.headerRow, sheet.rows.count > 1 {
            out += #"<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>"#
        }
        if width > 0 {
            out += "<cols>"
            for column in 0..<width {
                let longest = sheet.rows.map { column < $0.count ? shownLength($0[column]) : 0 }.max() ?? 0
                let chars = min(60, max(8, longest + 2))
                out += #"<col min="\#(column + 1)" max="\#(column + 1)" width="\#(chars)" customWidth="1"/>"#
            }
            out += "</cols>"
        }
        out += "<sheetData>"
        for (r, row) in sheet.rows.enumerated() {
            out += #"<row r="\#(r + 1)">"#
            for (c, raw) in row.enumerated() {
                var cell = raw
                if sheet.headerRow && r == 0 { cell.bold = true }
                out += xml(cell, ref: CellRef(row: r + 1, column: c + 1).a1)
            }
            out += "</row>"
        }
        out += "</sheetData>"
        if sheet.headerRow, sheet.rows.count > 1, width > 0 {
            out += #"<autoFilter ref="A1:\#(CellRef(row: sheet.rows.count, column: width).a1)"/>"#
        }
        return out + "</worksheet>"
    }

    static func xml(_ cell: Cell, ref: String) -> String {
        let style = styleIndex(cell)
        let s = style == 0 ? "" : #" s="\#(style)""#
        let formula = cell.formula.map { f -> String in
            let plain = f.hasPrefix("=") ? String(f.dropFirst()) : f
            return "<f>\(escape(plain))</f>"
        } ?? ""
        switch cell.value {
        case .empty:
            return formula.isEmpty ? (style == 0 ? "" : #"<c r="\#(ref)"\#(s)/>"#) : #"<c r="\#(ref)"\#(s)>\#(formula)</c>"#
        case .number(let n):
            return #"<c r="\#(ref)"\#(s)>\#(formula)<v>\#(number(n))</v></c>"#
        case .date(let d):
            return #"<c r="\#(ref)"\#(s)>\#(formula)<v>\#(number(serial(d)))</v></c>"#
        case .bool(let b):
            return #"<c r="\#(ref)" t="b"\#(s)>\#(formula)<v>\#(b ? 1 : 0)</v></c>"#
        case .text(let t):
            if !formula.isEmpty { return #"<c r="\#(ref)" t="str"\#(s)>\#(formula)<v>\#(escape(t))</v></c>"# }
            return #"<c r="\#(ref)" t="inlineStr"\#(s)><is><t xml:space="preserve">\#(escape(t))</t></is></c>"#
        }
    }

    /// Characters a column needs for this cell (rough, for the column width).
    static func shownLength(_ cell: Cell) -> Int {
        switch cell.value {
        case .empty: return 0
        case .text(let t): return t.count
        case .number(let n): return cell.format == .money ? number(n).count + 4 : number(n).count
        case .date: return 10
        case .bool: return 5
        }
    }

    /// Day number as Excel counts it (1900 system): days since 30 Dec 1899, in UTC.
    static func serial(_ date: Date) -> Double {
        (date.timeIntervalSince1970 / 86_400 + 25_569).rounded(.toNearestOrEven)
    }

    /// Number as XML text: no exponent for ordinary amounts, no locale.
    static func number(_ n: Double) -> String {
        guard n.isFinite else { return "0" }
        if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        return String(n)
    }

    /// XML text: the five special characters escaped, control characters XML does not allow removed.
    static func escape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            default:
                if scalar.value >= 0x20 && !(0xFFFE...0xFFFF).contains(scalar.value) { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }

    /// Excel's rules for sheet names: at most 31 characters, none of : \ / ? * [ ], not empty.
    public static func sheetName(_ raw: String) -> String {
        let cleaned = String(raw.filter { !":\\/?*[]".contains($0) }.prefix(31)).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Tabelle1" : cleaned
    }

    public static func uniqueName(_ name: String, in taken: [String]) -> String {
        guard taken.contains(where: { $0.lowercased() == name.lowercased() }) else { return name }
        for n in 2... {
            let candidate = String(name.prefix(28)) + " \(n)"
            if !taken.contains(where: { $0.lowercased() == candidate.lowercased() }) { return candidate }
        }
        return name
    }
}
