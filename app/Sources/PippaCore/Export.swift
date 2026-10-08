import Foundation

/// Invoice tables as CSV (German Excel) and XLSX (own small writer).
/// Header, sheet name and check note follow the system language; the number format (semicolon, decimal comma) stays.
public enum InvoiceExport {
    /// Header row; `amount` is the "Betrag" column (in the CSV with currency).
    static func headers(amount: String) -> [String] {
        [L("Date", table: "Analysis"), L("Sender", table: "Analysis"), amount, L("File", table: "Analysis"),
         L("Source text", table: "Analysis"), L("Check", table: "Analysis")]
    }

    /// Name of the sheet in the XLSX file.
    public static var sheetName: String { L("Invoices", table: "Analysis") }

    /// Header of the table preview in the app: as in the file, without the "Belegstelle" column.
    public static var previewHeaders: [String] {
        [L("Date", table: "Analysis"), L("Sender", table: "Analysis"), L("Amount", table: "Analysis"),
         L("File", table: "Analysis"), L("Check", table: "Analysis")]
    }

    /// Check note of a row as it appears in the file (empty if sure).
    public static func check(_ row: InvoiceRow) -> String {
        switch row.certainty {
        case .sure: ""
        case .unsure: L("please check", table: "Analysis")
        case .unreadable: L("unreadable", table: "Analysis")
        }
    }

    /// CSV with UTF-8 BOM, semicolon, decimal comma, CRLF.
    public static func csv(_ rows: [InvoiceRow]) -> Data {
        func field(_ s: String) -> String {
            s.contains(where: { $0 == ";" || $0 == "\"" || $0 == "\n" || $0 == "\r" })
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        // CSV has no text-cell type. Spreadsheet applications otherwise interpret document
        // text starting with these characters as formulas, even inside quoted CSV fields.
        func textField(_ s: String) -> String {
            let significant = s.trimmingCharacters(in: .whitespacesAndNewlines).first
            let formula = significant.map { "=+-@".contains($0) } ?? false
            let controlPrefix = s.first.map { $0 == "\t" || $0 == "\r" || $0 == "\n" } ?? false
            return field(formula || controlPrefix ? "'" + s : s)
        }
        var lines = [headers(amount: L("Amount (EUR)", table: "Analysis")).map(field).joined(separator: ";")]
        for r in rows {
            let amount = r.amount.map { GermanText.formatAmount($0, currency: false).replacingOccurrences(of: ".", with: "") } ?? ""
            lines.append([textField(r.date ?? ""), textField(r.sender ?? ""), field(amount),
                          textField(r.source.lastPathComponent), textField(r.evidence ?? ""), textField(check(r))].joined(separator: ";"))
        }
        return Data([0xEF, 0xBB, 0xBF]) + Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    /// XLSX: one sheet "Rechnungen" (or "Invoices"), header bold, date as a real date, amount as a number with € format.
    public static func xlsx(_ rows: [InvoiceRow]) -> Data {
        func esc(_ s: String) -> String {
            var out = ""
            for scalar in s.unicodeScalars {
                switch scalar {
                case "&": out += "&amp;"
                case "<": out += "&lt;"
                case ">": out += "&gt;"
                case "\"": out += "&quot;"
                case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
                default: if scalar.value >= 0x20 { out.unicodeScalars.append(scalar) }
                }
            }
            return out
        }
        func col(_ i: Int) -> String { String(UnicodeScalar(UInt8(65 + i))) }
        func str(_ ref: String, _ s: String, style: Int = 0) -> String {
            "<c r=\"\(ref)\" t=\"inlineStr\"\(style > 0 ? " s=\"\(style)\"" : "")><is><t xml:space=\"preserve\">\(esc(s))</t></is></c>"
        }
        let header = headers(amount: L("Amount", table: "Analysis"))
        var sheetRows = "<row r=\"1\">" + header.enumerated().map { str("\(col($0.offset))1", $0.element, style: 1) }.joined() + "</row>"
        for (i, r) in rows.enumerated() {
            let n = i + 2
            var cells = ""
            let unsureStyle = r.certainty == .sure ? 0 : 4
            if let d = r.date.flatMap(GermanText.parseDate) {
                cells += "<c r=\"A\(n)\" s=\"3\"><v>\(d.excelSerial)</v></c>"
            } else if let d = r.date { cells += str("A\(n)", d) }
            cells += str("B\(n)", r.sender ?? "")
            if let a = r.amount { cells += "<c r=\"C\(n)\" s=\"\(r.certainty == .sure ? 2 : 5)\"><v>\(NSDecimalNumber(decimal: a).stringValue)</v></c>" }
            cells += str("D\(n)", r.source.lastPathComponent)
            cells += str("E\(n)", r.evidence ?? "")
            let flag = check(r)
            if !flag.isEmpty { cells += str("F\(n)", flag, style: unsureStyle) }
            sheetRows += "<row r=\"\(n)\">\(cells)</row>"
        }
        let last = rows.count + 1
        // Sheet name in the reference always in apostrophes (allows spaces in translations), apostrophe inside doubled.
        let sheet = esc(sheetName)
        let sheetRef = "'" + sheet.replacingOccurrences(of: "'", with: "''") + "'"
        let sheetXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <dimension ref="A1:F\(last)"/><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>\
        <cols><col min="1" max="1" width="12" customWidth="1"/><col min="2" max="2" width="28" customWidth="1"/><col min="3" max="3" width="14" customWidth="1"/>\
        <col min="4" max="4" width="36" customWidth="1"/><col min="5" max="5" width="48" customWidth="1"/><col min="6" max="6" width="14" customWidth="1"/></cols>\
        <sheetData>\(sheetRows)</sheetData><autoFilter ref="A1:F\(last)"/></worksheet>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">\
        <numFmts count="2"><numFmt numFmtId="164" formatCode="#,##0.00\\ &quot;€&quot;"/><numFmt numFmtId="165" formatCode="dd.mm.yyyy"/></numFmts>\
        <fonts count="2"><font><sz val="12"/><name val="Calibri"/></font><font><b/><sz val="12"/><name val="Calibri"/></font></fonts>\
        <fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>\
        <fill><patternFill patternType="solid"><fgColor rgb="FFFFF2B3"/><bgColor indexed="64"/></patternFill></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="6"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
        <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>\
        <xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
        <xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>\
        <xf numFmtId="0" fontId="0" fillId="2" borderId="0" xfId="0" applyFill="1"/>\
        <xf numFmtId="164" fontId="0" fillId="2" borderId="0" xfId="0" applyNumberFormat="1" applyFill="1"/></cellXfs>\
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
        """
        let files: [(String, String)] = [
            ("[Content_Types].xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
            <Default Extension="xml" ContentType="application/xml"/>\
            <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
            <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
            <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
            """),
            ("_rels/.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
            """),
            ("xl/workbook.xml", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
            <sheets><sheet name="\(sheet)" sheetId="1" r:id="rId1"/></sheets>\
            <definedNames><definedName name="_xlnm._FilterDatabase" localSheetId="0" hidden="1">\(sheetRef)!$A$1:$F$\(last)</definedName></definedNames></workbook>
            """),
            ("xl/_rels/workbook.xml.rels", """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
            <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
            <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
            """),
            ("xl/styles.xml", styles),
            ("xl/worksheets/sheet1.xml", sheetXML),
        ]
        var zip = ZipWriter()
        for (name, content) in files { zip.add(name, Data(content.utf8)) }
        return zip.finish()
    }
}

/// ZIP without compression ("stored"), with CRC-32. Enough for XLSX.
public struct ZipWriter {
    private var body = Data()
    private var central = Data()
    private var count: UInt16 = 0

    public init() {}

    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let hour: Int = c.hour ?? 0, minute: Int = c.minute ?? 0, second: Int = c.second ?? 0
        let year: Int = max(0, (c.year ?? 1980) - 1980), month: Int = c.month ?? 1, dayOfMonth: Int = c.day ?? 1
        let timeBits: Int = (hour << 11) | (minute << 5) | (second / 2)
        let dayBits: Int = (year << 9) | (month << 5) | dayOfMonth
        let time = UInt16(timeBits)
        let day = UInt16(dayBits)
        return (time, day)
    }

    public mutating func add(_ name: String, _ data: Data, date: Date = Date()) {
        let nameData = Data(name.utf8)
        let crc = Self.crc32(data)
        let (time, day) = Self.dosDateTime(date)
        let offset = UInt32(body.count)
        var local = Data()
        local += Self.le32(0x0403_4B50); local += Self.le16(20); local += Self.le16(0x0800); local += Self.le16(0)
        local += Self.le16(time); local += Self.le16(day); local += Self.le32(crc)
        local += Self.le32(UInt32(data.count)); local += Self.le32(UInt32(data.count))
        local += Self.le16(UInt16(nameData.count)); local += Self.le16(0)
        body += local; body += nameData; body += data

        var entry = Data()
        entry += Self.le32(0x0201_4B50); entry += Self.le16(20); entry += Self.le16(20); entry += Self.le16(0x0800); entry += Self.le16(0)
        entry += Self.le16(time); entry += Self.le16(day); entry += Self.le32(crc)
        entry += Self.le32(UInt32(data.count)); entry += Self.le32(UInt32(data.count))
        entry += Self.le16(UInt16(nameData.count)); entry += Self.le16(0); entry += Self.le16(0)
        entry += Self.le16(0); entry += Self.le16(0); entry += Self.le32(0); entry += Self.le32(offset)
        central += entry; central += nameData
        count += 1
    }

    public func finish() -> Data {
        var out = body
        out += central
        out += Self.le32(0x0605_4B50); out += Self.le16(0); out += Self.le16(0)
        out += Self.le16(count); out += Self.le16(count)
        out += Self.le32(UInt32(central.count)); out += Self.le32(UInt32(body.count)); out += Self.le16(0)
        return out
    }
}
