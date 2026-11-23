import Foundation

// `compute`: exact arithmetic and calendar date math for the model, in Swift, with no file or network access.
//
// A 4B–12B local model loses cents and days when it adds amounts or counts dates in its thinking
// (docs/local-ai-research-2026-11.md). This tool does it with `Decimal` (no binary floating point) and the host's
// `Calendar`, so 0.1 + 0.2 is 0.3 and 31 January plus one month is the last day of February.
//
// Wiring: the name, `toolList()` and `call(_:)` plug into `PippaMCPToolList`, `PippaActionClasses.table` (`.read`) and
// `PippaMCPTools` dispatch.

public struct PippaMCPComputeTool: Sendable {
    public static let name = "compute"
    /// At most this many numbers per call.
    public static let maxNumbers = 500
    /// At most this many days, weeks or months to add (about 100 years of days).
    public static let maxShift = 36_600
    /// Fraction digits kept for a division or a mean that does not end.
    public static let scale: Int16 = 10

    static let arithmetic: Set<String> = ["sum", "subtract", "multiply", "divide", "stats"]
    static let dateOps: Set<String> = ["add_days", "add_weeks", "add_months", "days_between"]
    static let allowed: Set<String> = ["op", "numbers", "date", "to", "n"]

    let calendar: Calendar
    public init(calendar: Calendar) { self.calendar = calendar }
    public init(host: PippaMCPHost) { self.init(calendar: host.calendar) }

    /// One tool, short (every word costs prompt time with the local model). Values are checked in `call`.
    public static func toolList() -> [[String: Any]] {
        let title = "Rechnen"
        let string: [String: Any] = ["type": "string"]
        return [[
            "name": name, "title": title,
            "description": "Exact math. sum/subtract/multiply/divide (left to right)/stats: numbers. add_days/add_weeks/add_months: date YYYY-MM-DD, n. days_between: date, to.",
            "inputSchema": ["type": "object", "additionalProperties": false, "required": ["op"],
                            "properties": ["op": ["enum": (arithmetic.union(dateOps)).sorted()], "numbers": ["type": "array"],
                                           "date": string, "to": string, "n": ["type": "integer"]]] as [String: Any],
            "annotations": PippaActionClasses.annotations(name, title: title),
        ]]
    }

    public func call(_ raw: [String: Any]) -> PippaMCPToolResult {
        let unknown = raw.keys.filter { !Self.allowed.contains($0) }.sorted()
        if !unknown.isEmpty { return Self.failure("Unknown arguments: \(unknown.joined(separator: ", ")).") }
        guard let op = (raw["op"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased() else {
            return Self.failure("op is required: one of \(Self.arithmetic.union(Self.dateOps).sorted().joined(separator: ", ")).")
        }
        if Self.arithmetic.contains(op) {
            let extra = ["date", "to", "n"].filter { raw[$0] != nil }
            if !extra.isEmpty { return Self.failure("\(op) takes only numbers, not \(extra.joined(separator: ", ")).") }
            return arithmetic(op, raw["numbers"])
        }
        if Self.dateOps.contains(op) {
            if raw["numbers"] != nil { return Self.failure("\(op) takes no numbers.") }
            return dateMath(op, raw)
        }
        return Self.failure("Unknown op \"\(op)\". Use one of \(Self.arithmetic.union(Self.dateOps).sorted().joined(separator: ", ")).")
    }

    // MARK: Numbers

    private func arithmetic(_ op: String, _ value: Any?) -> PippaMCPToolResult {
        guard let list = value as? [Any] else { return Self.failure("\(op) needs numbers: a list like [12.5, \"84,20\"].") }
        guard !list.isEmpty else { return Self.failure("numbers is empty.") }
        guard list.count <= Self.maxNumbers else { return Self.failure("At most \(Self.maxNumbers) numbers per call; split the list and add the subtotals.") }
        if ["subtract", "multiply", "divide"].contains(op), list.count < 2 { return Self.failure("\(op) needs at least two numbers.") }
        var numbers: [Decimal] = []
        numbers.reserveCapacity(list.count)
        for (index, item) in list.enumerated() {
            switch Self.decimal(item) {
            case .success(let number): numbers.append(number)
            case .failure(let problem): return Self.failure("numbers[\(index)]: \(problem.text)")
            }
        }

        var result: [String: Any] = ["op": op, "count": numbers.count]
        var rounded = false
        switch op {
        case "sum":
            guard let sum = Self.fold(numbers, NSDecimalAdd) else { return Self.overflow }
            result["result"] = Self.text(sum)
        case "subtract":
            guard let difference = Self.fold(numbers, NSDecimalSubtract) else { return Self.overflow }
            result["result"] = Self.text(difference)
        case "multiply":
            guard let product = Self.fold(numbers, NSDecimalMultiply) else { return Self.overflow }
            result["result"] = Self.text(product)
        case "divide":
            if numbers.dropFirst().contains(where: \.isZero) { return Self.failure("Division by zero: there is no result. Say so; do not guess.") }
            guard let quotient = Self.fold(numbers, NSDecimalDivide) else { return Self.overflow }
            let (value, changed) = Self.round(quotient)
            rounded = changed
            result["result"] = Self.text(value)
        default: // stats
            guard let sum = Self.fold(numbers, NSDecimalAdd) else { return Self.overflow }
            var count = Decimal(numbers.count), total = sum, mean = Decimal()
            guard NSDecimalDivide(&mean, &total, &count, .plain) == .noError else { return Self.overflow }
            let (value, changed) = Self.round(mean)
            rounded = changed
            result["sum"] = Self.text(sum)
            result["min"] = Self.text(numbers.min()!)
            result["max"] = Self.text(numbers.max()!)
            result["mean"] = Self.text(value)
        }
        if rounded { result["rounded"] = "to \(Self.scale) decimal places" }
        result["next"] = "Exact. Copy the digits as given; in German text write a decimal comma."
        return PippaMCPToolResult(text: PippaMCPTools.json(result), isError: false)
    }

    private static let overflow = failure("The result is too large to compute exactly.")

    /// Left to right; `nil` on overflow, underflow or a NaN.
    private static func fold(_ numbers: [Decimal],
                             _ step: (UnsafeMutablePointer<Decimal>, UnsafePointer<Decimal>, UnsafePointer<Decimal>, NSDecimalNumber.RoundingMode) -> NSDecimalNumber.CalculationError) -> Decimal? {
        var total = numbers[0]
        for var next in numbers.dropFirst() {
            var left = total
            guard step(&total, &left, &next, .plain) == .noError, !total.isNaN else { return nil }
        }
        return total.isNaN ? nil : total
    }

    private static func round(_ value: Decimal) -> (Decimal, Bool) {
        var input = value, output = Decimal()
        NSDecimalRound(&output, &input, Int(scale), .plain)
        return (output, output != value)
    }

    static func text(_ value: Decimal) -> String {
        var value = value
        return NSDecimalString(&value, Locale(identifier: "en_US_POSIX"))
    }

    struct Problem: Error { let text: String }

    /// A JSON number, or a string in German ("1.234,56 €") or US ("1,234.56") spelling. Ambiguous spellings ("1.234",
    /// "1,234") are refused instead of guessed.
    static func decimal(_ item: Any) -> Result<Decimal, Problem> {
        if let number = item as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .failure(Problem(text: "true/false is no number.")) }
            if let exact = number as? NSDecimalNumber, !(exact.decimalValue.isNaN) { return .success(exact.decimalValue) }
            let double = number.doubleValue
            guard double.isFinite else { return .failure(Problem(text: "not a finite number.")) }
            // Doubles print in their shortest exact spelling (0.1 → "0.1"), so the Decimal is what the model wrote.
            let spelled = CFNumberIsFloatType(number) ? "\(double)" : number.stringValue
            guard let value = Decimal(string: spelled, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else {
                return .failure(Problem(text: "not a number."))
            }
            return .success(value)
        }
        guard let raw = item as? String else { return .failure(Problem(text: "not a number.")) }
        return parse(raw)
    }

    static func parse(_ raw: String) -> Result<Decimal, Problem> {
        let original = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, original.count <= 40 else { return .failure(Problem(text: "\"\(original.prefix(40))\" is not a number.")) }
        var text = original
        for unit in ["EUR", "Euro", "€", "$", "USD"] { text = text.replacingOccurrences(of: unit, with: "", options: .caseInsensitive) }
        text = text.filter { !$0.isWhitespace && $0 != "\u{202F}" && $0 != "\u{00A0}" && $0 != "'" }
        var negative = false
        if let first = text.first, first == "-" || first == "\u{2212}" { negative = true; text.removeFirst() }
        else if text.first == "+" { text.removeFirst() }
        if text.hasSuffix("-") { negative = true; text.removeLast() } // "184,37-" on statements
        let bad = Problem(text: "\"\(original)\" is not a number.")
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == ",") }),
              text.first?.isNumber == true || text.first == "." || text.first == "," else { return .failure(bad) }

        let commas = text.filter { $0 == "," }.count, dots = text.filter { $0 == "." }.count
        let decimalMark: Character?, grouping: Character?
        switch (commas, dots) {
        case (0, 0): decimalMark = nil; grouping = nil
        case (_, 0) where commas > 1: decimalMark = nil; grouping = ","
        case (0, _) where dots > 1: decimalMark = nil; grouping = "."
        case (1, 0), (0, 1):
            let mark: Character = commas == 1 ? "," : "."
            let after = text.split(separator: mark, omittingEmptySubsequences: false).last ?? ""
            let before = text.split(separator: mark, omittingEmptySubsequences: false).first ?? ""
            // "1.234" is 1234 in German and 1.234 in English: refuse rather than guess.
            if after.count == 3 && !before.isEmpty && before != "0" {
                return .failure(Problem(text: "\"\(original)\" is ambiguous (thousands or decimals?). Send it as a JSON number, e.g. 1234 or 1.234."))
            }
            decimalMark = mark; grouping = nil
        default:
            // Both marks: the last one is the decimal mark, the other groups thousands.
            let lastComma = text.lastIndex(of: ",")!, lastDot = text.lastIndex(of: ".")!
            decimalMark = lastComma > lastDot ? "," : "."
            grouping = decimalMark == "," ? "." : ","
            if text.filter({ $0 == decimalMark }).count > 1 { return .failure(bad) }
        }

        var integer = Substring(text), fraction: Substring = ""
        if let decimalMark, let index = text.lastIndex(of: decimalMark) {
            integer = text[..<index]; fraction = text[text.index(after: index)...]
            guard !fraction.isEmpty, fraction.allSatisfy(\.isNumber) else { return .failure(bad) }
        }
        if let grouping {
            let groups = integer.split(separator: grouping, omittingEmptySubsequences: false)
            guard let head = groups.first, (1...3).contains(head.count), groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return .failure(bad) }
            integer = Substring(groups.joined())
        }
        guard integer.allSatisfy(\.isNumber) else { return .failure(bad) }
        let plain = (negative ? "-" : "") + (integer.isEmpty ? "0" : integer) + (fraction.isEmpty ? "" : "." + fraction)
        guard let value = Decimal(string: plain, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return .failure(bad) }
        return .success(value)
    }

    // MARK: Dates

    private func dateMath(_ op: String, _ raw: [String: Any]) -> PippaMCPToolResult {
        guard let start = raw["date"] as? String else { return Self.failure("\(op) needs date as YYYY-MM-DD.") }
        guard let from = day(start) else { return Self.failure("\"\(start)\" is not a real date in the form YYYY-MM-DD.") }
        var result: [String: Any] = ["op": op, "date": start.trimmingCharacters(in: .whitespaces), "weekday": weekday(from)]
        if op == "days_between" {
            if raw["n"] != nil { return Self.failure("days_between takes date and to, not n.") }
            guard let end = raw["to"] as? String else { return Self.failure("days_between needs to as YYYY-MM-DD.") }
            guard let until = day(end) else { return Self.failure("\"\(end)\" is not a real date in the form YYYY-MM-DD.") }
            guard let days = calendar.dateComponents([.day], from: from, to: until).day else { return Self.failure("These dates cannot be compared.") }
            result["to"] = end.trimmingCharacters(in: .whitespaces)
            result["toWeekday"] = weekday(until)
            result["days"] = days
            result["next"] = "days = to minus date (negative when to is earlier). Exact."
            return PippaMCPToolResult(text: PippaMCPTools.json(result), isError: false)
        }
        if raw["to"] != nil { return Self.failure("\(op) takes date and n, not to.") }
        guard let n = Self.integer(raw["n"]) else { return Self.failure("\(op) needs n as a whole number (negative goes back).") }
        guard abs(n) <= Self.maxShift else { return Self.failure("n must be between -\(Self.maxShift) and \(Self.maxShift).") }
        let component: Calendar.Component = op == "add_months" ? .month : .day
        let amount = op == "add_weeks" ? n * 7 : n
        guard let target = calendar.date(byAdding: component, value: amount, to: from) else { return Self.failure("This date cannot be computed.") }
        result["n"] = n
        result["result"] = iso(target)
        result["resultWeekday"] = weekday(target)
        if op == "add_months", calendar.component(.day, from: target) != calendar.component(.day, from: from) {
            result["clamped"] = "That month is shorter: the last day of the month."
        }
        result["next"] = "Exact. Copy the date and weekday as given."
        return PippaMCPToolResult(text: PippaMCPTools.json(result), isError: false)
    }

    /// Noon of a strict YYYY-MM-DD day in the host calendar (noon keeps daylight saving changes out of day counts).
    func day(_ text: String) -> Date? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2]), year >= 1 else { return nil }
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth, hour: 12)) else { return nil }
        // The calendar rolls 30 February over into March; a real date comes back unchanged.
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == year && back.month == month && back.day == dayOfMonth ? date : nil
    }

    func iso(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// English weekday name (the model writes it in the person's language), e.g. "Saturday".
    func weekday(_ date: Date) -> String {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        return names[(calendar.component(.weekday, from: date) - 1) % 7]
    }

    /// A whole number from JSON, or as text ("2"), as small models send it.
    static func integer(_ value: Any?) -> Int? {
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue.isFinite ? Int(exactly: n.doubleValue) : nil }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func failure(_ why: String) -> PippaMCPToolResult {
        PippaMCPToolResult(text: PippaMCPTools.json(["status": "invalid_arguments", "error": why]), isError: true)
    }
}
