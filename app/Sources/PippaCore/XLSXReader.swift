import Foundation
import zlib

/// Reads entries from a ZIP (stored or deflate) via the central directory. Enough for XLSX parts.
public struct ZipReader {
    private let data: Data
    private var entries: [String: (method: Int, compressed: Int, size: Int, offset: Int, crc: UInt32)] = [:]

    public init?(_ data: Data) {
        self.data = data
        guard data.count >= 22 else { return nil }
        var end = data.count - 22
        while end >= max(0, data.count - 22 - 65_535) {
            if Self.u32(data, end) == 0x0605_4B50, end + 22 + Self.u16(data, end + 20) == data.count { break }
            end -= 1
        }
        guard end >= 0, Self.u32(data, end) == 0x0605_4B50,
              end + 22 + Self.u16(data, end + 20) == data.count,
              Self.u16(data, end + 4) == 0, Self.u16(data, end + 6) == 0,
              Self.u16(data, end + 8) == Self.u16(data, end + 10),
              Self.u16(data, end + 10) != 65_535 else { return nil } // no multi-disk/ZIP64
        var p = Self.u32(data, end + 16)
        let centralEnd = p + Self.u32(data, end + 12)
        guard centralEnd <= end else { return nil }
        for _ in 0..<Self.u16(data, end + 10) {
            guard p + 46 <= centralEnd, Self.u32(data, p) == 0x0201_4B50,
                  Self.u16(data, p + 8) & 1 == 0, Self.u16(data, p + 34) == 0 else { return nil }
            let nameLength = Self.u16(data, p + 28), extra = Self.u16(data, p + 30), comment = Self.u16(data, p + 32)
            guard p + 46 + nameLength + extra + comment <= centralEnd else { return nil }
            let name = String(decoding: data[(data.startIndex + p + 46)..<(data.startIndex + p + 46 + nameLength)], as: UTF8.self)
            guard entries[name] == nil else { return nil }
            entries[name] = (Self.u16(data, p + 10), Self.u32(data, p + 20), Self.u32(data, p + 24), Self.u32(data, p + 42), UInt32(Self.u32(data, p + 16)))
            p += 46 + nameLength + extra + comment
        }
        guard p == centralEnd else { return nil }
    }

    private static func u16(_ d: Data, _ o: Int) -> Int { Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 }
    private static func u32(_ d: Data, _ o: Int) -> Int { u16(d, o) | u16(d, o + 2) << 16 }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    /// Content of an entry; nil if it does not exist, is too large (> 50 MB) or cannot be decompressed.
    public func read(_ name: String) -> Data? {
        guard let e = entries[name], e.size <= 50_000_000, e.offset + 30 <= data.count,
              Self.u32(data, e.offset) == 0x0403_4B50,
              Self.u16(data, e.offset + 6) & 1 == 0,
              Self.u16(data, e.offset + 8) == e.method else { return nil }
        let start = e.offset + 30 + Self.u16(data, e.offset + 26) + Self.u16(data, e.offset + 28)
        guard start + e.compressed <= data.count else { return nil }
        let raw = data[(data.startIndex + start)..<(data.startIndex + start + e.compressed)]
        let out: Data
        if e.method == 0 {
            guard e.size == e.compressed else { return nil }
            out = Data(raw)
        } else {
            guard e.method == 8 else { return nil }
            // One byte more: even an empty deflate must contain a valid end marker.
            var buffer = Data(count: e.size + 1)
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
            defer { inflateEnd(&stream) }
            let status = buffer.withUnsafeMutableBytes { dst in
                raw.withUnsafeBytes { src in
                    stream.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: UInt8.self).baseAddress)
                    stream.avail_in = uInt(e.compressed)
                    stream.next_out = dst.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = uInt(e.size + 1)
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard status == Z_STREAM_END, stream.total_out == e.size, stream.total_in == e.compressed else { return nil }
            out = buffer.prefix(e.size)
        }
        let checksum = out.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(out.count)) }
        return UInt32(checksum) == e.crc ? out : nil
    }
}

/// Excel workbook (.xlsx) as text for Pi: per sheet, per row `A1: Wert | B7 = SUM(B2:B6) → 1234`.
/// Formulas are stored in English in the file (SUM, IF). The number of cells is capped.
public enum XLSXReader {
    static let maxCells = 4000
    static let maxCharacters = 200_000

    public static func read(_ data: Data) -> (text: String, truncated: Bool)? {
        workbook(data).map { ($0.text, $0.truncated) }
    }

    /// One sheet as cells for `SheetCheck` (values and formulas with a leading "="). Cells of a shared formula
    /// other than its origin carry only their value: their formula text is not in the file.
    public struct Sheet: Sendable {
        public var name: String
        public var grid: SheetGrid
    }

    /// Largest grid built for the check; a sparse sheet over a larger area gets no grid (the text stays).
    static let maxGridCells = 200_000

    /// Text for Pi and the read sheets as grids, from the same pass.
    public static func workbook(_ data: Data) -> (text: String, truncated: Bool, sheets: [Sheet])? {
        guard let zip = ZipReader(data), let workbook = zip.read("xl/workbook.xml") else { return nil }
        guard let relXML = zip.read("xl/_rels/workbook.xml.rels"), let rels = Relationships.parse(relXML),
              let sheets = SheetList.parse(workbook) else { return nil }
        var strings: [String] = []
        if zip.contains("xl/sharedStrings.xml") {
            guard let xml = zip.read("xl/sharedStrings.xml"), let parsed = SharedStrings.parse(xml) else { return nil }
            strings = parsed
        }
        // Cells with a date format hold day numbers; without styles.xml (or unreadable) there are no date cells.
        let dateStyles = zip.read("xl/styles.xml").flatMap(DateStyles.parse) ?? []
        var out: [String] = [], cells = 0, truncated = false
        var characters = 0
        var grids: [Sheet] = []
        for sheet in sheets {
            guard let relative = rels[sheet.rid] else { return nil }
            // Relationships are package paths; never access the file system.
            let target = URL(fileURLWithPath: relative, relativeTo: URL(fileURLWithPath: "/xl/", isDirectory: true)).standardizedFileURL.path.dropFirst()
            guard target.hasPrefix("xl/"), let xml = zip.read(String(target)),
                  let parsed = SheetCells.parse(xml, strings: strings, dateStyles: dateStyles, budget: maxCells - cells,
                                                      characterBudget: maxCharacters - characters) else { return nil }
            cells += parsed.cellCount; truncated = truncated || parsed.truncated
            if !parsed.rows.isEmpty {
                let text = "Blatt „\(sheet.name)“\n" + parsed.rows.joined(separator: "\n")
                out.append(text); characters += text.count
            }
            if let grid = grid(parsed.cells) { grids.append(Sheet(name: sheet.name, grid: grid)) }
            if truncated { break }
        }
        return (out.joined(separator: "\n\n"), truncated, grids)
    }

    /// The cells as one rectangle from the first to the last used cell; nil if empty or too sparse.
    static func grid(_ cells: [CellRef: SheetCell]) -> SheetGrid? {
        guard let first = cells.keys.first else { return nil }
        var top = first.row, bottom = first.row, left = first.column, right = first.column
        for ref in cells.keys {
            top = min(top, ref.row); bottom = max(bottom, ref.row)
            left = min(left, ref.column); right = max(right, ref.column)
        }
        guard (bottom - top + 1) * (right - left + 1) <= maxGridCells else { return nil }
        var rows = Array(repeating: Array(repeating: SheetCell.empty, count: right - left + 1), count: bottom - top + 1)
        for (ref, cell) in cells { rows[ref.row - top][ref.column - left] = cell }
        return SheetGrid(origin: CellRef(row: top, column: left), rows: rows)
    }

    /// Number as in German: decimal comma. Everything else stays as it is.
    static func german(_ v: String) -> String { Double(v) != nil ? v.replacingOccurrences(of: ".", with: ",") : v }

    private final class SharedStrings: NSObject, XMLParserDelegate {
        var list: [String] = [], current = "", inText = false, inItem = false
        static func parse(_ data: Data) -> [String]? { let d = SharedStrings(); let p = XMLParser(data: data); p.delegate = d; return p.parse() ? d.list : nil }
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            if e == "si" { inItem = true; current = "" } else if e == "t" { inText = true }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if inText && inItem { current += s } }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            if e == "t" { inText = false } else if e == "si" { list.append(current); inItem = false }
        }
    }

    /// Indexes into `cellXfs` whose number format shows a date: the built-in date formats (14–22, 45–47) and own
    /// formats with day, month or year letters outside quotes and brackets ("dd.mm.yyyy", not "[Red]0.00").
    final class DateStyles: NSObject, XMLParserDelegate {
        var custom: [Int: String] = [:], styles: [Int] = [], inCellXfs = false
        static func parse(_ data: Data) -> Set<Int>? {
            let d = DateStyles(); let p = XMLParser(data: data); p.delegate = d
            guard p.parse() else { return nil }
            return Set(d.styles.indices.filter { d.isDate(d.styles[$0]) })
        }
        func isDate(_ id: Int) -> Bool {
            if (14...22).contains(id) || (45...47).contains(id) { return true }
            guard let code = custom[id] else { return false }
            let plain = code.replacingOccurrences(of: #""[^"]*"|\[[^\]]*\]|\\."#, with: "", options: .regularExpression).lowercased()
            return plain.contains("d") || plain.contains("y") || plain.contains("m") && !plain.contains("0") && !plain.contains("#")
        }
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            switch e {
            case "numFmt": if let id = a["numFmtId"].flatMap(Int.init), let code = a["formatCode"] { custom[id] = code }
            case "cellXfs": inCellXfs = true
            case "xf" where inCellXfs: styles.append(a["numFmtId"].flatMap(Int.init) ?? 0)
            default: break
            }
        }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            if e == "cellXfs" { inCellXfs = false }
        }
    }

    /// Day number (1900 system) as a date at midnight UTC, and as "2026-01-01" for the text.
    static func date(serial: Double) -> (date: Date, text: String)? {
        guard serial.isFinite, serial >= 1, serial < 2_958_466 else { return nil }
        let date = Date(timeIntervalSince1970: (serial.rounded(.down) - 25_569) * 86_400)
        var f = Date.ISO8601FormatStyle(timeZone: TimeZone(identifier: "UTC")!)
        f = f.year().month().day()
        return (date, date.formatted(f))
    }

    private final class Relationships: NSObject, XMLParserDelegate {
        var map: [String: String] = [:]
        static func parse(_ data: Data) -> [String: String]? { let d = Relationships(); let p = XMLParser(data: data); p.delegate = d; return p.parse() ? d.map : nil }
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            if e == "Relationship", a["TargetMode"] != "External", let id = a["Id"], let t = a["Target"] { map[id] = t }
        }
    }

    private final class SheetList: NSObject, XMLParserDelegate {
        var sheets: [(name: String, rid: String)] = []
        static func parse(_ data: Data) -> [(name: String, rid: String)]? { let d = SheetList(); let p = XMLParser(data: data); p.delegate = d; return p.parse() ? d.sheets : nil }
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            if e == "sheet", let n = a["name"] { sheets.append((n, a["r:id"] ?? "")) }
        }
    }

    private final class SheetCells: NSObject, XMLParserDelegate {
        let strings: [String]; let dateStyles: Set<Int>; var budget: Int; var characterBudget: Int
        var rows: [String] = [], line: [String] = [], cellCount = 0, truncated = false
        var cells: [CellRef: SheetCell] = [:]
        var ref = "", type = "", formula = "", value = "", inline = "", field = "", style = 0
        var sharedID: String?, sharedFormulas: [String: String] = [:]
        var invalid = false
        init(strings: [String], dateStyles: Set<Int>, budget: Int, characterBudget: Int) {
            self.strings = strings; self.dateStyles = dateStyles; self.budget = budget; self.characterBudget = characterBudget
        }
        /// A number cell with a date format: the date, else nil.
        var dateValue: (date: Date, text: String)? {
            guard type == "" || type == "n", dateStyles.contains(style), let serial = Double(value) else { return nil }
            return XLSXReader.date(serial: serial)
        }
        /// The cell's value for the check: text cells stay text (a number typed as text is what the check looks for),
        /// numbers become numbers, error values ("#REF!") stay text.
        func typed(_ shown: String) -> SheetValue {
            switch type {
            case "s", "inlineStr", "str", "e": return shown.isEmpty ? .empty : .text(shown)
            case "b": return .bool(value == "1")
            default:
                if let date = dateValue { return .date(date.date) }
                return Double(value).map(SheetValue.number) ?? (shown.isEmpty ? .empty : .text(shown))
            }
        }
        static func parse(_ data: Data, strings: [String], dateStyles: Set<Int>, budget: Int, characterBudget: Int) -> SheetCells? {
            let d = SheetCells(strings: strings, dateStyles: dateStyles, budget: budget, characterBudget: characterBudget)
            let p = XMLParser(data: data); p.delegate = d
            let ok = p.parse()
            return !d.invalid && (ok || d.truncated) ? d : nil
        }
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            switch e {
            case "c": ref = a["r"] ?? ""; type = a["t"] ?? ""; style = a["s"].flatMap(Int.init) ?? 0; formula = ""; value = ""; inline = ""; sharedID = nil
            case "f": field = e; sharedID = a["t"] == "shared" ? a["si"] : nil
            case "v", "t": field = e
            default: break
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) {
            switch field { case "f": formula += s; case "v": value += s; case "t": inline += s; default: break }
        }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            if e == "f" || e == "v" || e == "t" { field = "" }
            if e == "c" {
                var shown: String
                switch type {
                case "s":
                    guard let i = Int(value), strings.indices.contains(i) else { invalid = true; p.abortParsing(); return }
                    shown = strings[i]
                case "inlineStr": shown = inline
                case "b": shown = value == "1" ? "WAHR" : "FALSCH"
                default: shown = dateValue?.text ?? XLSXReader.german(value)
                }
                shown = shown.replacingOccurrences(of: "\n", with: " ")
                var f = formula.trimmingCharacters(in: .whitespacesAndNewlines)
                if let id = sharedID {
                    if !f.isEmpty { sharedFormulas[id] = "\(ref): \(f)" }
                    else {
                        guard let base = sharedFormulas[id] else { invalid = true; p.abortParsing(); return }
                        f = "[gemeinsame Formel, relativ zu \(base)]"
                    }
                }
                if !ref.isEmpty, !f.isEmpty || !shown.isEmpty {
                    let cell = f.isEmpty ? "\(ref): \(shown)" : "\(ref) = \(f)" + (shown.isEmpty ? "" : " → \(shown)")
                    if budget <= 0 || cell.count > characterBudget {
                        if !line.isEmpty { rows.append(line.joined(separator: " | ")); line = [] }
                        truncated = true; p.abortParsing(); return
                    }
                    budget -= 1; cellCount += 1
                    characterBudget -= cell.count + 3
                    line.append(cell)
                    let derived = sharedID != nil && formula.isEmpty
                    if let at = CellRef(a1: ref) { cells[at] = SheetCell(typed(shown), formula: derived || f.isEmpty ? nil : "=" + f) }
                }
            } else if e == "row" {
                if !line.isEmpty { rows.append(line.joined(separator: " | ")) }
                line = []
            }
        }
    }
}
