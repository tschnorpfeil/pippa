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
        guard let zip = ZipReader(data), let workbook = zip.read("xl/workbook.xml") else { return nil }
        guard let relXML = zip.read("xl/_rels/workbook.xml.rels"), let rels = Relationships.parse(relXML),
              let sheets = SheetList.parse(workbook) else { return nil }
        var strings: [String] = []
        if zip.contains("xl/sharedStrings.xml") {
            guard let xml = zip.read("xl/sharedStrings.xml"), let parsed = SharedStrings.parse(xml) else { return nil }
            strings = parsed
        }
        var out: [String] = [], cells = 0, truncated = false
        var characters = 0
        for sheet in sheets {
            guard let relative = rels[sheet.rid] else { return nil }
            // Relationships are package paths; never access the file system.
            let target = URL(fileURLWithPath: relative, relativeTo: URL(fileURLWithPath: "/xl/", isDirectory: true)).standardizedFileURL.path.dropFirst()
            guard target.hasPrefix("xl/"), let xml = zip.read(String(target)),
                  let parsed = SheetCells.parse(xml, strings: strings, budget: maxCells - cells, characterBudget: maxCharacters - characters) else { return nil }
            cells += parsed.cellCount; truncated = truncated || parsed.truncated
            if !parsed.rows.isEmpty {
                let text = "Blatt „\(sheet.name)“\n" + parsed.rows.joined(separator: "\n")
                out.append(text); characters += text.count
            }
            if truncated { break }
        }
        return (out.joined(separator: "\n\n"), truncated)
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
        let strings: [String]; var budget: Int; var characterBudget: Int
        var rows: [String] = [], line: [String] = [], cellCount = 0, truncated = false
        var ref = "", type = "", formula = "", value = "", inline = "", field = ""
        var sharedID: String?, sharedFormulas: [String: String] = [:]
        var invalid = false
        init(strings: [String], budget: Int, characterBudget: Int) { self.strings = strings; self.budget = budget; self.characterBudget = characterBudget }
        static func parse(_ data: Data, strings: [String], budget: Int, characterBudget: Int) -> SheetCells? {
            let d = SheetCells(strings: strings, budget: budget, characterBudget: characterBudget); let p = XMLParser(data: data); p.delegate = d
            let ok = p.parse()
            return !d.invalid && (ok || d.truncated) ? d : nil
        }
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            switch e {
            case "c": ref = a["r"] ?? ""; type = a["t"] ?? ""; formula = ""; value = ""; inline = ""; sharedID = nil
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
                default: shown = XLSXReader.german(value)
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
                }
            } else if e == "row" {
                if !line.isEmpty { rows.append(line.joined(separator: " | ")) }
                line = []
            }
        }
    }
}
