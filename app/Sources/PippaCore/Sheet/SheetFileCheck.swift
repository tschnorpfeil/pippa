import Foundation

// "Check the total" for a table file (dropped .xlsx, .csv, .tsv), not only for the open Excel window:
// `SheetCheck` runs on the read cells and its findings go to the model ahead of the cells, so the model
// explains what code found instead of adding up numbers itself. Plain code, no model.

public enum SheetFileCheck {
    /// Table formats Pippa reads as cells. Others (.numbers, .xls, .ods) get a sentence instead (`unreadableNote`).
    public static let readableExtensions: Set<String> = ["xlsx", "xlsm", "csv", "tsv"]
    /// Spreadsheet formats Pippa cannot read yet.
    public static let unreadableExtensions: Set<String> = ["numbers", "xls", "ods"]
    /// At most this many findings per sheet in the note; the cells follow anyway.
    static let findingLimit = 8
    /// At most this many cells from a CSV go into the check (the same budget as Excel files).
    static let maxCells = 4000

    /// What the model reads before the cells. Fixed German text, like "Blatt" in `XLSXReader`; the finding sentences
    /// are in the UI language. Nil if no sheet has a total: then there is nothing code checked, and the model must stay
    /// free to answer questions like "how much in total?".
    public static func note(for sheets: [(name: String, grid: SheetGrid)], locale: Locale = .current) -> String? {
        let checked = sheets.filter { !$0.grid.isEmpty }.map { (name: $0.name, result: SheetCheck.run($0.grid, locale: locale)) }
            .filter { $0.result.foundTotals || !$0.result.findings.isEmpty }
        guard !checked.isEmpty else { return nil }
        var lines = ["[Pippa hat die Summen dieser Tabelle mit Code nachgerechnet – verlässlich. Übernimm diese Ergebnisse, statt die Summen selbst neu zu rechnen.]"]
        for (name, result) in checked {
            let prefix = sheets.count > 1 ? "Blatt „\(name)“: " : ""
            lines.append(prefix + result.firstLine.text)
            for finding in result.findings.prefix(findingLimit) {
                let cells = finding.addresses.isEmpty ? "" : " (Zellen: \(finding.addresses.joined(separator: ", ")))"
                lines.append("- " + finding.sentence + cells)
            }
            if result.findings.count > findingLimit {
                lines.append("- … und \(result.findings.count - findingLimit) weitere Funde.")
            }
        }
        return lines.joined(separator: "\n")
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
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !body.hasPrefix("Table: ") else { return nil }
        let separator = forced ?? guessSeparator(body)
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
                if !endRow() { break }
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { _ = endRow() }
        while let last = rows.last, last.allSatisfy({ $0.value.isEmpty }) { rows.removeLast() }
        guard !rows.isEmpty else { return nil }
        return SheetGrid(rows: rows)
    }

    /// The separator that occurs most often in the first line outside quotes; a comma if none occurs.
    static func guessSeparator(_ text: String) -> Character {
        var counts: [Character: Int] = ["\t": 0, ";": 0, ",": 0]
        var quoted = false
        for c in text {
            if c == "\"" { quoted.toggle(); continue }
            if !quoted && (c == "\n" || c == "\r\n" || c == "\r") { break }
            if !quoted, counts[c] != nil { counts[c, default: 0] += 1 }
        }
        let order: [Character] = ["\t", ";", ","]
        let best = order.max { (counts[$0] ?? 0) < (counts[$1] ?? 0) } ?? ","
        return (counts[best] ?? 0) > 0 ? best : ","
    }

    /// A field as a cell: empty, number (as Excel would store it on import) or text.
    static func cell(_ raw: String) -> SheetCell {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .empty }
        if let number = SheetNumber.parse(trimmed) { return SheetCell(.number(number)) }
        return SheetCell(.text(trimmed))
    }
}
