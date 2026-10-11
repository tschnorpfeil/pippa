import Foundation

// "Check the total" for a table file (dropped .xlsx, .csv, .tsv, and the open Excel sheet handed to the conversation):
// `SheetCheck` and `SheetFacts` run on the read cells and their results go to the model ahead of the cells, so the
// model explains what code found and computed instead of adding up numbers itself. Plain code, no model.

public enum SheetFileCheck {
    /// Table formats Pippa reads as cells. Others (.numbers, .xls, .ods) get a sentence instead (`unreadableNote`).
    public static let readableExtensions: Set<String> = ["xlsx", "xlsm", "csv", "tsv"]
    /// Can Pippa read this table? The formats above, and Numbers files when Numbers is installed (`NumbersExport`
    /// saves an Excel copy first).
    public static func isReadable(fileExtension: String) -> Bool {
        let ext = fileExtension.lowercased()
        return readableExtensions.contains(ext) || (ext == "numbers" && NumbersExport.isInstalled)
    }
    /// Spreadsheet formats Pippa cannot read yet.
    public static let unreadableExtensions: Set<String> = ["numbers", "xls", "ods"]
    /// At most this many findings per sheet in the note; the cells follow anyway.
    static let findingLimit = 8
    /// At most this many cells from a CSV go into the check (the same budget as Excel files).
    static let maxCells = 4000

    /// What the model reads before the cells: the totals checked (`SheetCheck`) and the sums computed (`SheetFacts`).
    /// Fixed German text, like "Blatt" in `XLSXReader`; the finding sentences are in the UI language. Nil if code found
    /// nothing to check or to add up (no heading row, no number column, no total). `truncated`: Pippa read only the first
    /// part of the table, so the sums cover only that part, and the note says so.
    public static func note(for sheets: [(name: String, grid: SheetGrid)], locale: Locale = .current, truncated: Bool = false) -> String? {
        let header = truncated
            ? "[Die Tabelle ist länger, als Pippa liest. Pippa hat nur den gelesenen Teil mit Code nachgerechnet: Diese Summen gelten nur für diesen Teil, nicht für die ganze Tabelle. Sag das der Person, wenn du sie nennst. Summenzeilen sind nicht mitgezählt.]"
            : "[Pippa hat diese Tabelle mit Code nachgerechnet – verlässlich. Übernimm diese Zahlen genau, statt selbst zu rechnen. Summenzeilen sind in den Summen nicht mitgezählt.]"
        var lines = [header]
        for sheet in sheets where !sheet.grid.isEmpty {
            let result = SheetCheck.run(sheet.grid, locale: locale)
            let facts = SheetFacts.lines(SheetFacts.compute(sheet.grid), locale: locale)
            let checked = result.foundTotals || !result.findings.isEmpty
            guard checked || !facts.isEmpty else { continue }
            if sheets.count > 1 { lines.append("Blatt „\(sheet.name)“:") }
            if checked {
                lines.append(result.firstLine.text)
                for finding in result.findings.prefix(findingLimit) {
                    let cells = finding.addresses.isEmpty ? "" : " (Zellen: \(finding.addresses.joined(separator: ", ")))"
                    lines.append("- " + finding.sentence + cells)
                }
                if result.findings.count > findingLimit {
                    lines.append("- … und \(result.findings.count - findingLimit) weitere Funde.")
                }
            }
            lines += facts
        }
        return lines.count > 1 ? lines.joined(separator: "\n") : nil
    }

    /// The check's note followed by the text Pi reads, or the text alone when there is nothing to check.
    public static func prepend(_ note: String?, to text: String) -> String {
        guard let note, !text.isEmpty else { return text }
        return note + "\n\n" + text
    }

    /// For the model when a spreadsheet cannot be read (read_document). Nil for other formats.
    public static func unreadableNote(fileExtension: String) -> String? {
        guard unreadableExtensions.contains(fileExtension.lowercased()) else { return nil }
        return "Pippa cannot read this spreadsheet format yet. Tell the person in one sentence: save it as an Excel file (.xlsx) and show it again (in Numbers: File > Export To > Excel). Do not guess its content."
    }

    /// A CSV or TSV as cells: separator from the first line (tab, semicolon or comma, outside quotes),
    /// quoted fields with doubled quotes, numbers as numbers (German or English style), the rest as text.
    /// Nil for an empty text and for the table text Pippa writes itself from Excel (`SheetSnapshot.contextText`):
    /// that sheet was already checked.
    public static func csvGrid(_ text: String, separator forced: Character? = nil) -> SheetGrid? {
        csvRead(text, separator: forced)?.grid
    }

    /// `csvGrid`, and whether the cell budget cut the table short.
    public static func csvRead(_ text: String, separator forced: Character? = nil) -> (grid: SheetGrid, truncated: Bool)? {
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !body.hasPrefix("Table: ") else { return nil }
        // No separator in the first line: one column ("Betrag" over "12,50"), never split at a decimal comma.
        let separator = forced ?? (separatorCounts(body).values.contains { $0 > 0 } ? guessSeparator(body) : "\u{1F}")
        var truncated = false
        var rows: [[SheetCell]] = []
        var row: [SheetCell] = []
        var field = ""
        var quoted = false
        var cells = 0
        func endField() {
            row.append(cell(field)); field = ""
        }
        func endRow() -> Bool {
            endField()
            if !(row.count == 1 && row[0].value.isEmpty) || !rows.isEmpty { rows.append(row) }
            cells += row.count
            row = []
            return cells < maxCells
        }
        var chars = body.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? chars.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let next = chars.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == separator {
                endField()
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                if !endRow() {
                    while !truncated, let rest = chars.next() { truncated = !rest.isWhitespace }
                    break
                }
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { _ = endRow() }
        while let last = rows.last, last.allSatisfy({ $0.value.isEmpty }) { rows.removeLast() }
        guard !rows.isEmpty else { return nil }
        return (SheetGrid(rows: rows), truncated)
    }

    /// The separator that occurs most often in the first line outside quotes; a comma if none occurs.
    public static func guessSeparator(_ text: String) -> Character {
        let counts = separatorCounts(text)
        let order: [Character] = ["\t", ";", ","]
        let best = order.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? ","
        return (counts[best] ?? 0) > 0 ? best : ","
    }

    /// How often tab, semicolon and comma occur in the first line, outside quotes.
    static func separatorCounts(_ text: String) -> [Character: Int] {
        var counts: [Character: Int] = ["\t": 0, ";": 0, ",": 0]
        var quoted = false
        for c in text {
            if c == "\"" { quoted.toggle(); continue }
            if !quoted && (c == "\n" || c == "\r\n" || c == "\r") { break }
            if !quoted, counts[c] != nil { counts[c, default: 0] += 1 }
        }
        return counts
    }

    /// A field as a cell: empty, number (as Excel would store it on import) or text.
    static func cell(_ raw: String) -> SheetCell {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .empty }
        if let number = SheetNumber.parse(trimmed) { return SheetCell(.number(number)) }
        return SheetCell(.text(trimmed))
    }
}
