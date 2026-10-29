import Foundation
import PippaCore

/// make_chart: every value computed in code from grids built by hand here and from real files (an XLSX written here, a
/// CSV with ";" and decimal commas), the card stored with the answer, and the MCP tool end to end. No model.
func runChartChecks() async {
    let german = Locale(identifier: "de_DE")
    func t(_ s: String) -> SheetCell { SheetCell(.text(s)) }
    func n(_ v: Double) -> SheetCell { SheetCell(.number(v)) }
    func grid(_ rows: [[SheetCell]]) -> SheetGrid { SheetGrid(rows: rows) }
    func build(_ g: SheetGrid, x: String = "Monat", y: [String] = ["Betrag"], agg: ChartAggregate? = nil,
               kind: ChartCard.Kind = .bar) -> Result<ChartCard, ChartBuildFailure> {
        ChartBuilder.build(g, x: x, y: y, aggregate: agg, kind: kind, source: "Umsatz.xlsx", locale: german)
    }
    func card(_ result: Result<ChartCard, ChartBuildFailure>) -> ChartCard? {
        if case .success(let value) = result { return value }
        return nil
    }
    func failure(_ result: Result<ChartCard, ChartBuildFailure>) -> ChartBuildFailure? {
        if case .failure(let value) = result { return value }
        return nil
    }

    // MARK: Values

    check("Chart: repeated labels add up, a total row stays out, \"1.234,56 €\" as text counts as 1234.56") {
        let g = grid([[t("Monat"), t("Betrag")], [t("Jan"), n(10)], [t("Feb"), t("1.234,56 €")], [t("Jan"), n(5.5)],
                      [t("Summe"), n(1250.06)]])
        guard let c = card(build(g)) else { return false }
        let cut = card(ChartBuilder.build(g, x: "Monat", y: ["Betrag"], aggregate: .sum, kind: .bar, source: "x.csv", truncated: true))
        let values: [Double?] = [15.5, 1234.56]
        let summed = c.labels == ["Jan", "Feb"] && c.series.map(\.name) == ["Betrag"] && c.series[0].values == values
            && c.note == nil && c.xTitle == "Monat" && c.kind == .bar
        let texts = c.title == L("%@ by %@", table: "MCP", "Betrag", "Monat")
            && c.footer == L("Computed by Pippa from %@", table: "MCP", "Umsatz.xlsx")
            && cut?.note == L("Only the first part of the table was read.", table: "MCP")
        return summed && texts
    }
    check("Chart: without y it counts rows per label; average divides by the rows with a number; float noise is removed") {
        let g = grid([[t("Monat"), t("Betrag")], [t("Jan"), n(10)], [t("Feb"), n(4)], [t("Jan"), n(20)], [t("Jan"), t("")]])
        let noise = grid([[t("Monat"), t("Betrag")], [t("Jan"), n(0.1)], [t("Jan"), n(0.2)]])
        guard let counted = card(build(g, y: [])), let average = card(build(g, agg: .average)),
              let plain = card(build(g, agg: ChartAggregate.none)), let added = card(build(noise)) else { return false }
        let counts: [Double?] = [3, 1], averages: [Double?] = [15, 4], rows: [Double?] = [10, 4, 20, nil], sum: [Double?] = [0.3]
        let countOK = counted.series.map(\.name) == [L("Count", table: "MCP")] && counted.series[0].values == counts && counted.note == nil
        let averageOK = average.labels == ["Jan", "Feb"] && average.series[0].values == averages
            && average.note == L("One row without a number was left out.", table: "MCP")
        let plainOK = plain.labels == ["Jan", "Feb", "Jan (2)", "Jan (3)"] && plain.series[0].values == rows && added.series[0].values == sum
        let text = grid([[t("Monat"), t("Betrag"), t("Notiz")], [t("Jan"), n(1), t("offen")]])
        let refused = failure(build(g, y: [], agg: .sum)) == .noNumbers("y") && failure(build(text, y: ["Notiz"])) == .noNumbers("Notiz")
        return countOK && averageOK && plainOK && refused
    }

    check("Chart: long category prefixes stay separate, repeated rows get distinct positions, and pie totals stay finite") {
        let prefix = String(repeating: "A", count: 70)
        let long = grid([[t("Monat"), t("Betrag")], [t(prefix + "1"), n(10)], [t(prefix + "2"), n(20)], [t(prefix + "1"), n(5)]])
        let huge = grid([[t("Monat"), t("Betrag")], [t("A"), n(1e308)], [t("B"), n(1e308)]])
        guard let distinct = card(build(long)) else { return false }
        return distinct.labels.count == 2 && Set(distinct.labels).count == 2
            && distinct.series[0].values == [15, 20]
            && failure(build(huge, kind: .pie)) == .pieNeedsPositive
            && (try? JSONEncoder().encode(distinct)) != nil
    }

    // MARK: Columns, dates, limits

    check("Chart: an unknown column names every heading; a column letter works; headings match without case and accents") {
        let g = grid([[t("Monat"), t("Betrag"), t("Gebühr")], [t("Jan"), n(10), n(1)], [t("Feb"), n(4), n(2)]])
        let unknown = failure(build(g, y: ["Kosten"]))
        let sentence = unknown?.sentence ?? ""
        guard let letter = card(build(g, y: ["B"])), let folded = card(build(g, x: "monat", y: ["GEBUHR"])) else { return false }
        let named = unknown == .unknownColumn("Kosten", available: ["Monat", "Betrag", "Gebühr"])
            && ["Monat", "Betrag", "Gebühr", "Kosten"].allSatisfy { sentence.contains($0) }
        let letterValues: [Double?] = [10, 4], foldedValues: [Double?] = [1, 2]
        let found = letter.series.map(\.name) == ["Betrag"] && letter.series[0].values == letterValues
            && folded.series.map(\.name) == ["Gebühr"] && folded.series[0].values == foldedValues
        return named && found && failure(build(grid([[t("Monat"), t("Betrag")], [t("Jan"), t("x")]]))) == .noHeadings
    }
    check("Chart: text dates sort in time order; XLSX dates keep their UTC day") {
        let g = grid([[t("Datum"), t("Betrag")], [t("15.03.2026"), n(3)], [t("1.2.2026"), n(2)], [t("2026-01-10"), n(1)]])
        guard let text = card(build(g, x: "Datum", kind: .line)) else { return false }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let march = utc.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let january = utc.date(from: DateComponents(year: 2026, month: 1, day: 31))!
        let data = XLSXWriter.data([XLSXWriter.Sheet(name: "Umsatz", rows: [
            [.text("Datum"), .text("Betrag")],
            [XLSXWriter.Cell(.date(march), format: .date), .number(12)],
            [XLSXWriter.Cell(.date(january), format: .date), .number(7)],
        ])])
        guard let sheet = XLSXReader.workbook(data)?.sheets.first, let read = card(build(sheet.grid, x: "Datum")) else { return false }
        let day = DateFormatter()
        day.locale = german; day.timeZone = TimeZone(identifier: "UTC"); day.dateStyle = .medium; day.timeStyle = .none
        let textValues: [Double?] = [1, 2, 3], readValues: [Double?] = [7, 12]
        let sorted = text.labels == ["2026-01-10", "1.2.2026", "15.03.2026"] && text.series[0].values == textValues
        return sorted && read.labels == [day.string(from: january), day.string(from: march)] && read.series[0].values == readValues
            && read.labels.first?.contains("31") == true
    }
    check("Chart: at most 24 bars; a pie keeps 7 slices plus Other; negative slices, two pie series and 5 series are refused") {
        let many = grid([[t("Monat"), t("Betrag")]] + (1...25).map { [t("Posten \($0)"), n(Double($0))] })
        let slices = grid([[t("Posten"), t("Betrag")]] + (1...10).map { [t("P\($0)"), n(Double(11 - $0))] })
        let negative = grid([[t("Posten"), t("Betrag")], [t("A"), n(5)], [t("B"), n(-2)]])
        let wide = grid([[t("Monat"), t("Eins"), t("Zwei"), t("Drei"), t("Vier"), t("Fünf")], [t("Jan"), n(1), n(2), n(3), n(4), n(5)]])
        guard let pie = card(build(slices, x: "Posten", kind: .pie)) else { return false }
        let sliceValues: [Double?] = [10, 9, 8, 7, 6, 5, 4, 6]
        let bars = failure(build(many)) == .tooManyPoints(25, limit: 24) && card(build(many, kind: .line))?.labels.count == 25
        let merged = pie.labels.count == 8 && pie.labels.first == "P1" && pie.labels.last == L("Other", table: "MCP")
            && pie.series.count == 1 && pie.series[0].values == sliceValues
        let refused = failure(build(negative, x: "Posten", kind: .pie)) == .pieNeedsPositive
            && failure(build(wide, y: ["Eins", "Zwei"], kind: .pie)) == .pieNeedsOneSeries
            && failure(build(wide, y: ["Eins", "Zwei", "Drei", "Vier", "Fünf"])) == .tooManySeries(limit: 4)
        return bars && merged && refused
    }

    // MARK: Stored with the answer

    check("Chart: the card is stored with the answer, a missing value as null; an unknown card is still dropped") {
        let chart = ChartCard(kind: .line, title: "Betrag nach Monat", xTitle: "Monat", labels: ["Jan", "Feb"],
                              series: [ChartCard.Series(name: "Betrag", values: [12.5, nil])],
                              footer: "Von Pippa aus Umsatz.xlsx berechnet", note: "Eine Zeile ohne Zahl wurde weggelassen.")
        guard let data = try? JSONEncoder().encode(ResultCard.chart(chart)), let json = String(data: data, encoding: .utf8),
              let back = try? JSONDecoder().decode(ResultCard.self, from: data),
              let stored = try? JSONEncoder().encode(ActionReceipt(items: [ActionReceipt.Item(action: "read", outcome: "done", name: "Diagramm")],
                                                                   cards: [.chart(chart)])),
              var receipt = try? JSONSerialization.jsonObject(with: stored) as? [String: Any],
              var cards = receipt["cards"] as? [Any] else { return false }
        cards.insert(["hologram": ["_0": ["x": 1]]], at: 0)
        receipt["cards"] = cards
        let mixed = (try? JSONSerialization.data(withJSONObject: receipt)).flatMap { try? JSONDecoder().decode(ActionReceipt.self, from: $0) }
        return back == .chart(chart) && json.contains("[12.5,null]") && mixed?.cards == [.chart(chart)] && mixed?.items.count == 1
    }

    // MARK: MCP

    check("make_chart: declared read-only, last in the tool list, closed schema") {
        let tool = PippaMCPTools.toolList().last ?? [:]
        let hints = tool["annotations"] as? [String: Any] ?? [:]
        let schema = tool["inputSchema"] as? [String: Any] ?? [:]
        return tool["name"] as? String == PippaMCPChart.name && PippaMCPTools.toolNames.last == PippaMCPChart.name
            && hints["readOnlyHint"] as? Bool == true && hints["destructiveHint"] as? Bool == false && hints["openWorldHint"] as? Bool == false
            && schema["additionalProperties"] as? Bool == false && (schema["properties"] as? [String: Any])?.keys.sorted() == ["agg", "path", "type", "x", "y"]
    }

    let folder = dir("chart")
    let xlsx = folder.appendingPathComponent("Umsatz.xlsx"), csv = folder.appendingPathComponent("Konto.csv")
    let numbers = folder.appendingPathComponent("Haushalt.numbers")
    try? XLSXWriter.write([XLSXWriter.Sheet(name: "Umsatz", rows: [
        [.text("Monat"), .text("Betrag")], [.text("Jan"), .number(10)], [.text("Feb"), .number(20.5)], [.text("Jan"), .number(5)],
    ])], to: xlsx)
    write("Monat;Betrag\nJan;1.234,56\nFeb;\nMär;10,5\nSumme;1245,06\n", csv)
    write("not a table", numbers)

    await checkAsync("make_chart end to end: computed rows for the model (null where empty), a chart card for this answer, the table noted as read") {
        var host = PippaMCPHost.demo()
        host.turns = PippaMCPTurns()
        let turn = PippaMCPTurn()
        host.turns.begin(turn)
        let notes = LockedBox<[PippaMCPReadNote]>([])
        host.onRead = { note in notes.mutate { $0.append(note) } }
        let tools = PippaMCPTools(host: host)
        func call(_ arguments: [String: Any]) async throws -> (result: [String: Any], payload: [String: Any]) {
            let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                                   "params": ["name": "make_chart", "arguments": arguments]])
            guard let data = await tools.handle(body), let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let result = reply["result"] as? [String: Any],
                  let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String,
                  let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return ([:], [:]) }
            return (result, payload)
        }
        func rows(_ payload: [String: Any]) -> [[Any]] { ((payload["data"] as? [String: Any])?["rows"] as? [[Any]]) ?? [] }
        func same(_ rows: [[Any]], _ expected: [(String, Double?)]) -> Bool {
            rows.count == expected.count && zip(rows, expected).allSatisfy { row, want in
                guard row.count == 2, row[0] as? String == want.0 else { return false }
                if let value = want.1 { return (row[1] as? NSNumber)?.doubleValue == value }
                return row[1] is NSNull
            }
        }
        let fromXLSX = try await call(["path": xlsx.path, "x": "Monat", "y": ["Betrag"]])
        // Without y the rows would be counted (ChartBuilder.resolved); the sums need the number column.
        let fromCSV = try await call(["path": csv.path, "x": "Monat", "y": ["Betrag"], "type": "line"])
        let charted = notes.value
        guard charted.count == 2, charted.allSatisfy({ $0.read && $0.tool == PippaMCPChart.name && $0.turnID == turn.id }),
              case .chart(let xlsxCard)? = charted[0].card, case .chart(let csvCard)? = charted[1].card else { return false }
        let succeeded = [fromXLSX, fromCSV].allSatisfy { $0.result["isError"] as? Bool == false && $0.payload["untrusted"] as? Bool == true }
        let computed = same(rows(fromXLSX.payload), [("Jan", 15), ("Feb", 20.5)])
            && same(rows(fromCSV.payload), [("Jan", 1234.56), ("Feb", nil), ("Mär", 10.5)])
            && (fromCSV.payload["data"] as? [String: Any])?["aggregate"] as? String == "sum"
        let csvValues: [Double?] = [1234.56, nil, 10.5]
        let cards = xlsxCard.labels == ["Jan", "Feb"] && csvCard.kind == .line && csvCard.series[0].values == csvValues
            && csvCard.note == L("One row without a number was left out.", table: "MCP")
            && charted[1].line == L("Chart: %@", table: "MCP", "Konto.csv")
        let ledger = await turn.ledger
        let noted = [xlsx, csv].allSatisfy { ledger.paths.contains($0.standardizedFileURL.path) }
        // The computed rows stand in for the table in the source check, amounts also written the German way.
        let received = ledger.adjusting([DocumentSnapshot(name: "Konto.csv", text: "")], files: [csv]).first
        let ledgerText = received?.text ?? ""
        let counted = received?.readStatus == .readable && ledgerText.contains("Jan: 1234.56 (1.234,56)")
            && ledgerText.contains("Feb: –") && ledgerText.contains("Mär: 10.5 (10,50)")

        let errors: [([String: Any], String)] = [
            (["path": "Umsatz.xlsx", "x": "Monat"], "invalid_arguments"),
            (["path": numbers.path, "x": "Monat"], "unsupported"),
            (["path": xlsx.path, "x": "Monat", "y": "Betrag"], "invalid_arguments"),
            (["path": xlsx.path, "x": "Monat", "foo": 1], "invalid_arguments"),
            (["path": xlsx.path, "x": "Monat", "type": "radar"], "invalid_arguments"),
            (["path": xlsx.path, "x": "Kosten"], "no_chart"),
            (["path": folder.appendingPathComponent("Fehlt.csv").path, "x": "Monat"], "not_found"),
        ]
        for (arguments, status) in errors {
            let reply = try await call(arguments)
            guard reply.result["isError"] as? Bool == true, reply.payload["status"] as? String == status,
                  reply.payload["read"] as? Bool == false, reply.payload["error"] is String else { return false }
        }
        let failed = notes.value.dropFirst(2)
        return succeeded && computed && cards && noted && counted && failed.count == errors.count
            && failed.allSatisfy { !$0.read && $0.card == nil && $0.turnID == turn.id }
    }
}
