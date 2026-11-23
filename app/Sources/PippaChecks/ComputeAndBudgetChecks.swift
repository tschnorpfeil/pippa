import Foundation
import PippaCore

/// `compute` (exact Decimal and calendar math), `read_document` with `to_page` and `query`, and the prompt budget of
/// Pippa's MCP tool list. Synthetic fixtures only.
func runComputeAndBudgetChecks() async {
    var berlin = Calendar(identifier: .gregorian)
    berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!; berlin.locale = Locale(identifier: "de_DE"); berlin.firstWeekday = 2
    let compute = PippaMCPComputeTool(calendar: berlin)
    func run(_ arguments: [String: Any]) -> (json: [String: Any], isError: Bool) {
        // Through JSON like a real call, so numbers arrive as the server's parser makes them.
        let wire = try! JSONSerialization.data(withJSONObject: arguments)
        let raw = try! JSONSerialization.jsonObject(with: wire) as! [String: Any]
        let result = compute.call(raw)
        return ((try? JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any]) ?? [:], result.isError)
    }
    func result(_ arguments: [String: Any]) -> String? {
        let r = run(arguments)
        return r.isError ? nil : r.json["result"] as? String
    }
    func refused(_ arguments: [String: Any]) -> Bool {
        let r = run(arguments)
        return r.isError && r.json["status"] as? String == "invalid_arguments" && (r.json["error"] as? String)?.isEmpty == false
    }

    // MARK: (a) exact numbers

    check("compute: 0.1 + 0.2 is exactly 0.3 (float would say 0.30000000000000004)") {
        result(["op": "sum", "numbers": [0.1, 0.2]]) == "0.3" && 0.1 + 0.2 != 0.3
    }
    check("compute: a German invoice in euro strings sums to the cent") {
        // 19,99 + 1.234,56 + 0,01 + 84,20 € + 7.000,00 EUR + 0,10 + 0,20 = 8.339,06
        result(["op": "sum", "numbers": ["19,99", "1.234,56", "0,01", "84,20 €", "7.000,00 EUR", "0,10", "0,20"]]) == "8339.06"
            && result(["op": "sum", "numbers": ["1,234.56", "-34.56", 100]]) == "1300"
            && result(["op": "sum", "numbers": Array(repeating: 0.01, count: 300)]) == "3"
    }
    check("compute: subtract, multiply and divide go left to right") {
        result(["op": "subtract", "numbers": ["1.000,00", "184,37", "0,63"]]) == "815"
            && result(["op": "multiply", "numbers": ["19,99", 3]]) == "59.97"
            && result(["op": "multiply", "numbers": [1.19, "84,20"]]) == "100.198"
            && result(["op": "divide", "numbers": [100, 4]]) == "25"
            && result(["op": "divide", "numbers": [10, 3]]) == "3.3333333333"
            && run(["op": "divide", "numbers": [10, 3]]).json["rounded"] != nil
            && run(["op": "divide", "numbers": [100, 4]]).json["rounded"] == nil
    }
    check("compute: stats gives count, sum, min, max and mean") {
        let r = run(["op": "stats", "numbers": ["84,20", "19,99", "120,00", 0.81]])
        return !r.isError && r.json["count"] as? Int == 4 && r.json["sum"] as? String == "225"
            && r.json["min"] as? String == "0.81" && r.json["max"] as? String == "120" && r.json["mean"] as? String == "56.25"
    }
    check("compute: division by zero, NaN, infinity and bad numbers are refused") {
        refused(["op": "divide", "numbers": [5, 0]]) && refused(["op": "divide", "numbers": [5, "0,00"]])
            && (run(["op": "divide", "numbers": [5, 0]]).json["error"] as? String)?.contains("zero") == true
            && refused(["op": "sum", "numbers": ["NaN"]]) && refused(["op": "sum", "numbers": ["inf"]])
            && refused(["op": "sum", "numbers": [true]]) && refused(["op": "sum", "numbers": ["12a"]])
            && refused(["op": "sum", "numbers": [["nested"]]]) && refused(["op": "sum", "numbers": ["1.2.3,4,5"]])
            && compute.call(["op": "sum", "numbers": [Double.nan]]).isError
            && compute.call(["op": "sum", "numbers": [Double.infinity]]).isError
    }
    check("compute: ambiguous \"1.234\" is refused instead of guessed; clear spellings parse") {
        refused(["op": "sum", "numbers": ["1.234"]]) && refused(["op": "sum", "numbers": ["1,234"]])
            && result(["op": "sum", "numbers": ["1.234,5"]]) == "1234.5" && result(["op": "sum", "numbers": ["0.125"]]) == "0.125"
            && result(["op": "sum", "numbers": ["5.231.992 €"]]) == "5231992" && result(["op": "sum", "numbers": ["184,37-"]]) == "-184.37"
            && result(["op": "sum", "numbers": ["1\u{202F}234,56"]]) == "1234.56"
    }
    check("compute: missing, unknown and wrong arguments, more than 500 numbers, too few to subtract") {
        refused([:]) && refused(["op": "power", "numbers": [2, 3]]) && refused(["op": "sum", "numbers": [1], "extra": 1])
            && refused(["op": "sum"]) && refused(["op": "sum", "numbers": []]) && refused(["op": "sum", "numbers": "1,2"])
            && refused(["op": "subtract", "numbers": [1]]) && refused(["op": "sum", "numbers": [1], "date": "2026-01-01"])
            && refused(["op": "sum", "numbers": Array(repeating: 1, count: 501)])
            && result(["op": "sum", "numbers": Array(repeating: 1, count: 500)]) == "500"
    }

    // MARK: (b) calendar

    check("compute: add_months clamps 31 January to the end of February, also in a leap year") {
        let plain = run(["op": "add_months", "date": "2026-01-31", "n": 1]), leap = run(["op": "add_months", "date": "2028-01-31", "n": 1])
        return plain.json["result"] as? String == "2026-02-28" && plain.json["resultWeekday"] as? String == "Saturday"
            && plain.json["clamped"] != nil && leap.json["result"] as? String == "2028-02-29"
            && result(["op": "add_months", "date": "2026-03-15", "n": -2]) == "2026-01-15"
            && run(["op": "add_months", "date": "2026-03-15", "n": -2]).json["clamped"] == nil
    }
    check("compute: add_days and add_weeks across leap days, year ends and daylight saving") {
        result(["op": "add_days", "date": "2028-02-28", "n": 1]) == "2028-02-29"
            && result(["op": "add_days", "date": "2026-02-28", "n": 1]) == "2026-03-01"
            && result(["op": "add_days", "date": "2026-12-31", "n": "1"]) == "2027-01-01"
            && result(["op": "add_days", "date": "2026-03-28", "n": 2]) == "2026-03-30"
            && result(["op": "add_weeks", "date": "2026-11-23", "n": 2]) == "2026-12-07"
            && run(["op": "add_weeks", "date": "2026-11-23", "n": 2]).json["weekday"] as? String == "Monday"
            && result(["op": "add_days", "date": "2026-11-23", "n": -30]) == "2026-10-24"
    }
    check("compute: days_between counts exactly, signed, across daylight saving and leap years") {
        let r = run(["op": "days_between", "date": "2026-10-07", "to": "2026-11-15"])
        return r.json["days"] as? Int == 39 && r.json["toWeekday"] as? String == "Sunday"
            && run(["op": "days_between", "date": "2028-02-01", "to": "2028-03-01"]).json["days"] as? Int == 29
            && run(["op": "days_between", "date": "2026-11-15", "to": "2026-10-07"]).json["days"] as? Int == -39
            && run(["op": "days_between", "date": "2026-03-28", "to": "2026-03-30"]).json["days"] as? Int == 2
    }
    check("compute: invalid dates and arguments are refused (2026-02-30, 2026-2-3, n missing or out of range)") {
        refused(["op": "add_days", "date": "2026-02-30", "n": 1]) && refused(["op": "add_days", "date": "2027-02-29", "n": 1])
            && refused(["op": "add_days", "date": "2026-2-3", "n": 1]) && refused(["op": "add_days", "date": "03.02.2026", "n": 1])
            && refused(["op": "add_days", "date": "2026-02-03"]) && refused(["op": "add_days", "date": "2026-02-03", "n": 1.5])
            && refused(["op": "add_days", "date": "2026-02-03", "n": 1_000_000]) && refused(["op": "days_between", "date": "2026-02-03"])
            && refused(["op": "days_between", "date": "2026-02-03", "to": "2026-13-01"])
            && refused(["op": "add_days", "date": "2026-02-03", "n": 1, "numbers": [1]])
            && refused(["op": "add_days", "date": "2026-02-03", "n": 1, "to": "2026-02-04"])
    }
    check("compute: listed as one compact tool with a closed op enum and no extra fields") {
        guard let tool = PippaMCPComputeTool.toolList().first, PippaMCPComputeTool.toolList().count == 1,
              let schema = tool["inputSchema"] as? [String: Any], let properties = schema["properties"] as? [String: Any],
              let ops = (properties["op"] as? [String: Any])?["enum"] as? [String] else { return false }
        return tool["name"] as? String == PippaMCPComputeTool.name && schema["additionalProperties"] as? Bool == false
            && Set(ops) == ["sum", "subtract", "multiply", "divide", "stats", "add_days", "add_weeks", "add_months", "days_between"]
            && (tool["description"] as? String ?? "").count <= 160
    }

    // MARK: (c) read_document with to_page and query

    let folder = dir("compute-read-document")
    let pdf = folder.appendingPathComponent("Kontoauszug Beispiel.pdf")
    makePDF((1...6).map { n in
        n == 2 || n == 5 ? "Seite \(n)\nNachzahlung Stadtwerke Beispiel 184,37 €\nEnde der Seite \(n)" : "Seite \(n)\nUmsätze ohne Treffer \(n)"
    }, at: pdf)
    let reader = PippaMCPTurnTools(turns: PippaMCPTurns())
    func read(_ arguments: [String: Any]) async -> (json: [String: Any], data: [String: Any], isError: Bool) {
        let r = await reader.call("read_document", arguments)
        let json = (try? JSONSerialization.jsonObject(with: Data(r.text.utf8)) as? [String: Any]) ?? [:]
        return (json, json["data"] as? [String: Any] ?? [:], r.isError)
    }

    await checkAsync("read_document: to_page stops at the asked page without claiming truncation") {
        let r = await read(["path": pdf.path, "from_page": 2, "to_page": 3])
        let text = r.data["text"] as? String ?? ""
        return !r.isError && r.data["pages"] as? String == "2-3" && text.contains("[S. 2]") && text.contains("[S. 3]")
            && !text.contains("[S. 4]") && !text.contains("[S. 1]") && r.data["nextPage"] == nil && r.data["truncated"] == nil
            && (r.json["next"] as? String)?.contains("6 pages") == true
    }
    await checkAsync("read_document: to_page past the end reads to the end; to_page < from_page is invalid_arguments") {
        let all = await read(["path": pdf.path, "to_page": "99"])
        let wrong = await read(["path": pdf.path, "from_page": 4, "to_page": 2])
        let badType = await read(["path": pdf.path, "to_page": true])
        return !all.isError && all.data["pages"] as? String == "1-6" && all.json["next"] as? String == "This is the whole document."
            && wrong.isError && wrong.json["status"] as? String == "invalid_arguments" && (wrong.json["error"] as? String)?.contains("to_page") == true
            && badType.isError && badType.json["status"] as? String == "invalid_arguments"
    }
    await checkAsync("read_document: query returns only matching pages (case-insensitive) with [S. n] and matchedPages") {
        let r = await read(["path": pdf.path, "query": "NACHZAHLUNG"])
        let text = r.data["text"] as? String ?? ""
        return !r.isError && r.data["matchedPages"] as? [Int] == [2, 5] && text.contains("[S. 2]") && text.contains("[S. 5]")
            && !text.contains("[S. 1]") && !text.contains("[S. 3]") && !text.contains("ohne Treffer")
            && r.data["pages"] as? String == "1-6" && (r.json["next"] as? String)?.contains("contain") == true
    }
    await checkAsync("read_document: query with to_page searches only that range") {
        let r = await read(["path": pdf.path, "query": "nachzahlung", "to_page": 3])
        return !r.isError && r.data["matchedPages"] as? [Int] == [2] && !(r.data["text"] as? String ?? "").contains("[S. 5]")
    }
    await checkAsync("read_document: a query with no match says so and asks not to guess") {
        let r = await read(["path": pdf.path, "query": "Kündigung"])
        let next = r.json["next"] as? String ?? ""
        let empty = await read(["path": pdf.path, "query": "   "])
        return !r.isError && r.data["matchedPages"] as? [Int] == [] && r.data["text"] as? String == ""
            && next.contains("Kündigung") && next.contains("do not guess") && next.contains("1-6")
            && empty.isError && empty.json["status"] as? String == "invalid_arguments"
    }
    await checkAsync("read_document: without the new arguments it reads as before") {
        let r = await read(["path": pdf.path])
        return !r.isError && r.data["pages"] as? String == "1-6" && r.data["matchedPages"] == nil
            && (r.data["text"] as? String ?? "").contains("[S. 6]") && r.json["next"] as? String == "This is the whole document."
    }
    await checkAsync("read_document: schema lists to_page and query; a table of amounts points to compute") {
        let tool = PippaMCPTurnTools.toolList().first ?? [:]
        let properties = (tool["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
        let table = folder.appendingPathComponent("Umsaetze Beispiel.txt")
        write("Jan 19,99 €\nFeb 84,20 €\nMär 120,00 €\nApr 0,81 €\nMai 1.234,56 €\n", table)
        let r = await read(["path": table.path])
        return Set(properties.keys) == ["path", "from_page", "to_page", "query"]
            && (r.json["next"] as? String)?.contains("call compute") == true
    }

    // MARK: (d) prompt budget

    // Every request to the local model carries the whole tool list, so its size is prompt time on every turn.
    // Measured 2026-11-23 (sorted keys): 7,118 bytes at fcec7f55, 7,209 with read_document's to_page and query. The
    // ceiling is that plus 2,191 bytes, room for about five compact 1.1 tools (`compute` alone is 546). Raise it only
    // with a measured reason; shorten descriptions first.
    let toolListCeiling = 9_400
    check("Prompt budget: PippaMCPTools.toolList() stays under \(toolListCeiling) bytes of JSON") {
        let bytes = (try? JSONSerialization.data(withJSONObject: PippaMCPTools.toolList(), options: [.sortedKeys]))?.count ?? .max
        let own = (try? JSONSerialization.data(withJSONObject: PippaMCPComputeTool.toolList(), options: [.sortedKeys]))?.count ?? .max
        print("  tool list: \(bytes) bytes (ceiling \(toolListCeiling), headroom \(toolListCeiling - bytes)); compute alone: \(own) bytes")
        return bytes < toolListCeiling
    }
}
