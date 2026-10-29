import Foundation

/// `make_chart`: a chart card under the answer from a table file on this Mac (.csv, .tsv, .xlsx). Pi names the file and
/// the columns; Pippa reads the cells and computes every value (`ChartBuilder`). The model gets the computed rows back to
/// quote, never a number of its own. Reads only, like the other readers; not offered in draft-only tasks.
public struct PippaMCPChart: Sendable {
    public static let name = "make_chart"
    /// Larger tables are not charted; the readers keep only the first 4,000 cells anyway.
    static let maxFileBytes = 20_000_000
    let turn: PippaMCPTurn?
    public init(turn: PippaMCPTurn?) { self.turn = turn }

    public static func toolList() -> [[String: Any]] {
        [["name": name, "title": "Diagramm",
          "description": "Chart card of a .csv/.xlsx; Pippa computes values. x=label column, y=number columns, agg=sum default.",
          "inputSchema": ["type": "object", "additionalProperties": false, "required": ["path", "x"], "properties": [
              "path": ["type": "string"], "x": ["type": "string"], "y": ["type": "array", "items": ["type": "string"]],
              "type": ["enum": ["bar", "line", "pie"]], "agg": ["enum": ["sum", "count", "average", "none"]]]],
          "annotations": PippaMCPTools.readOnly.merging(["title": "Diagramm"]) { a, _ in a }]]
    }

    /// Sets turnID and permissionRepair, like PippaMCPFilePreparation.readNote.
    public static func readNote(for result: PippaMCPToolResult, path: String, turnID: UUID?) -> PippaMCPReadNote {
        let normalized = normalize(path)
        let file = normalized.isEmpty ? "" : URL(fileURLWithPath: normalized).lastPathComponent
            .split(whereSeparator: \.isNewline).joined(separator: " ")
        let shown = String(file.prefix(80))
        var note = PippaMCPReadNote(tool: name, read: !result.isError,
                                    line: result.isError ? L("No chart: %@", table: "MCP", shown) : L("Chart: %@", table: "MCP", shown),
                                    card: result.isError ? nil : result.card, permissionRepair: result.permissionRepair)
        note.turnID = turnID
        return note
    }

    public func call(_ raw: [String: Any]) async -> PippaMCPToolResult {
        let started = ContinuousClock.now
        let result = await chart(raw)
        let elapsed = (ContinuousClock.now - started).components
        var fields = ["name": Self.name, "fehler": String(result.isError),
                      "ms": String(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)]
        // Why it failed (status only, never the path or cells).
        if result.isError, let status = (try? JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])?["status"] as? String {
            fields["status"] = status
        }
        DiagnosticsLog.shared.event("mcp-werkzeug", fields)
        return result
    }

    private struct Request: Sendable {
        var path: String
        var x: String
        var y: [String]
        var kind: ChartCard.Kind
        var aggregate: ChartAggregate?
    }

    private enum Built: Sendable {
        case chart(ChartCard, aggregate: ChartAggregate, truncated: Bool)
        case noChart(ChartBuildFailure)
        case unreadable
    }

    private func chart(_ raw: [String: Any]) async -> PippaMCPToolResult {
        guard let request = Self.request(raw) else {
            return Self.failure("invalid_arguments", "Use path (absolute .csv/.tsv/.xlsx), x (label column heading), optional y (up to 4 number column headings), type bar/line/pie and agg sum/count/average/none. No other arguments are accepted.")
        }
        let path = Self.normalize(request.path)
        guard path.hasPrefix("/") else { return Self.failure("invalid_arguments", "Use the exact absolute path from the message.") }
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension.lowercased()
        if let note = SheetFileCheck.unreadableNote(fileExtension: ext) { return Self.failure("unsupported", note) }
        guard SheetFileCheck.readableExtensions.contains(ext) else {
            return Self.failure("invalid_arguments", "make_chart reads .csv, .tsv, .xlsx and .xlsm tables only. Use read_document for other files.")
        }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as NSError where PermissionRepairTarget.isFileAccessDenied(error) {
            return Self.denied(url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
            || error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return Self.failure("not_found", "There is no file at this path. Use the exact path from the message.")
        } catch {
            return Self.failure("failed", "Pippa could not open this file just now. Nothing was charted.")
        }
        if attributes[.type] as? FileAttributeType == .typeDirectory {
            return Self.failure("invalid_arguments", "This is a folder, not a table file. Use the exact path of the .csv or .xlsx file.")
        }
        // Privacy settings (Downloads, Desktop, Documents) can deny reading while the file exists.
        do { try FileHandle(forReadingFrom: url).close() } catch let error as NSError where PermissionRepairTarget.isFileAccessDenied(error) {
            return Self.denied(url)
        } catch {}
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= Self.maxFileBytes else { return Self.failure("failed", "This table is larger than 20 MB; Pippa does not chart it.") }

        let source = url.lastPathComponent
        let built = await Task.detached(priority: .userInitiated) {
            Self.build(url, ext: ext, fileSize: size, request: request, source: source)
        }.value
        switch built {
        case .unreadable:
            return Self.failure("failed", "Pippa could not read this table; it may be damaged or empty. Tell the person in one sentence; do not guess its content.")
        case .noChart(let failure):
            return Self.failure("no_chart", failure.sentence)
        case .chart(let card, let aggregate, let truncated):
            let rows = Self.rows(card)
            var data: [String: Any] = ["file": source, "type": card.kind.rawValue, "x": card.xTitle, "series": card.series.map(\.name),
                                       "rows": Array(rows.prefix(ChartBuilder.modelRows)), "rows_shown": min(rows.count, ChartBuilder.modelRows),
                                       "rows_total": card.labels.count, "aggregate": aggregate.rawValue]
            var next = "The person sees this chart as a card under your answer. Do not list the values or describe the chart; give the main takeaway in one or two sentences and copy any number exactly from data.rows."
            if truncated {
                data["table_truncated"] = true
                next += " Pippa read only the first part of the table; say so."
            }
            var result = PippaMCPTools.bounded(source: "Table on this Mac", data: data, next: next)
            result.card = .chart(card)
            // What was computed counts as read for the source check (PiAnswerReview), like a read_document result.
            await turn?.notedText(path: url.standardizedFileURL.path, text: Self.rowsText(card), firstPage: nil, lastPage: nil,
                                  pageCount: nil, cut: truncated)
            return result
        }
    }

    /// Only declared arguments with their declared types; an invalid optional one is an error, never ignored.
    private static func request(_ raw: [String: Any]) -> Request? {
        guard Set(raw.keys).isSubset(of: ["path", "x", "y", "type", "agg"]),
              let path = (raw["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
              path.utf8.count <= 4096, !path.contains("\0"),
              let x = (raw["x"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !x.isEmpty, x.count <= 200 else { return nil }
        var y: [String] = []
        if let value = raw["y"] {
            guard let list = value as? [String], list.count <= ChartBuilder.maxSeries else { return nil }
            y = list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard y.allSatisfy({ !$0.isEmpty && $0.count <= 200 }) else { return nil }
        }
        var kind = ChartCard.Kind.bar
        if let value = raw["type"] {
            guard let text = value as? String, let parsed = ChartCard.Kind(rawValue: text) else { return nil }
            kind = parsed
        }
        var aggregate: ChartAggregate?
        if let value = raw["agg"] {
            guard let text = value as? String, let parsed = ChartAggregate(rawValue: text) else { return nil }
            aggregate = parsed
        }
        return Request(path: path, x: x, y: y, kind: kind, aggregate: aggregate)
    }

    /// Shell habits of small models, as in read_document: quotes, escaped spaces, file:// and ~.
    static func normalize(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.count > 1, let first = path.first, first == path.last, first == "\"" || first == "'" { path = String(path.dropFirst().dropLast()) }
        if path.contains("\\ ") { path = path.replacingOccurrences(of: "\\ ", with: " ") }
        if path.hasPrefix("file://"), let url = URL(string: path) { path = url.path }
        return (path as NSString).expandingTildeInPath
    }

    /// Reads the file and builds the chart from the first sheet that fits the request.
    private static func build(_ url: URL, ext: String, fileSize: Int, request: Request, source: String) -> Built {
        let grids: [SheetGrid]
        let truncated: Bool
        if ext == "xlsx" || ext == "xlsm" {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), let book = XLSXReader.workbook(data) else { return .unreadable }
            grids = book.sheets.map(\.grid)
            truncated = book.truncated
        } else {
            guard let text = TextReader.readPlain(url), let read = SheetFileCheck.csvRead(text, separator: ext == "tsv" ? "\t" : nil) else {
                return .unreadable
            }
            grids = [read.grid]
            // readPlain reads the first 2 MB only.
            truncated = read.truncated || fileSize > 2_000_000
        }
        var firstFailure: ChartBuildFailure?
        for grid in grids where !grid.isEmpty {
            switch ChartBuilder.build(grid, x: request.x, y: request.y, aggregate: request.aggregate, kind: request.kind,
                                      source: source, truncated: truncated) {
            case .success(let card): return .chart(card, aggregate: ChartBuilder.resolved(request.aggregate, y: request.y), truncated: truncated)
            case .failure(let failure): if firstFailure == nil { firstFailure = failure }
            }
        }
        return .noChart(firstFailure ?? .noHeadings)
    }

    /// `[label, value, …]` per label, JSON null where a row had no number (never an Optional inside `[Any]`).
    static func rows(_ card: ChartCard) -> [[Any]] {
        card.labels.indices.map { index -> [Any] in
            var row: [Any] = [card.labels[index]]
            for series in card.series {
                if index < series.values.count, let value = series.values[index] { row.append(value) } else { row.append(NSNull()) }
            }
            return row
        }
    }

    /// "Jan: 1234.56 (1.234,56); 12 (12,00)" per label, for the read ledger. The read ledger stands in for the table in
    /// the source check, which compares amounts written the German way ("1.234,56"), so each value comes in both forms.
    static func rowsText(_ card: ChartCard) -> String {
        card.labels.indices.map { index -> String in
            let values = card.series.map { series -> String in
                guard index < series.values.count, let value = series.values[index] else { return "–" }
                let plain = SheetText.plain(.number(value))
                guard let amount = Decimal(string: plain, locale: Locale(identifier: "en_US_POSIX")) else { return plain }
                return plain + " (" + GermanText.formatAmount(amount, currency: false) + ")"
            }
            return card.labels[index] + ": " + values.joined(separator: "; ")
        }.joined(separator: "\n")
    }

    private static func denied(_ url: URL) -> PippaMCPToolResult {
        failure("denied", "Pippa is not allowed to open this file. Tell the person in one sentence; do not try other ways.",
                repair: PermissionRepairTarget.forDeniedFile(at: url))
    }

    static func failure(_ status: String, _ why: String, repair: PermissionRepairTarget? = nil) -> PippaMCPToolResult {
        PippaMCPToolResult(text: PippaMCPTools.json(["read": false, "status": status, "error": why]), isError: true, permissionRepair: repair)
    }
}
