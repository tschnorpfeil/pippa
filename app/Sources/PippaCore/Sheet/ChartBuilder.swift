import Foundation

/// A chart under the answer, computed in code from the table's cells; the model never types a value.
public struct ChartCard: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case bar, line, pie }
    public struct Series: Codable, Sendable, Equatable {
        public var name: String
        /// One per label; nil where the row had no number. Never NaN or infinite (the history is JSON).
        public var values: [Double?]
        public init(name: String, values: [Double?]) { self.name = name; self.values = values }
    }
    public var kind: Kind
    public var title: String
    public var xTitle: String
    public var labels: [String]
    public var series: [Series]
    /// "Von Pippa aus Umsatz.xlsx berechnet"
    public var footer: String
    public var note: String?
    public init(kind: Kind, title: String, xTitle: String, labels: [String], series: [Series], footer: String, note: String? = nil) {
        self.kind = kind; self.title = title; self.xTitle = xTitle; self.labels = labels; self.series = series
        self.footer = footer; self.note = note
    }
}

public enum ChartAggregate: String, Sendable, CaseIterable { case sum, count, average, none }

public enum ChartBuildFailure: Error, Sendable, Equatable {
    case noHeadings, unknownColumn(String, available: [String]), noNumbers(String), noRows
    case tooManyPoints(Int, limit: Int), tooManySeries(limit: Int), pieNeedsOneSeries, pieNeedsPositive

    /// For the model, English like the other tool errors; says what to change.
    public var sentence: String {
        switch self {
        case .noHeadings:
            return "Pippa found no heading row with numbers below it in this table, so there is nothing to chart. Tell the person in one sentence; do not draw a chart yourself."
        case .unknownColumn(let name, let available):
            let headings = available.isEmpty ? "none" : available.map { "\"\($0)\"" }.joined(separator: ", ")
            return "There is no column \"\(name)\". Use one of these headings exactly: \(headings); or a column letter such as B."
        case .noNumbers(let name):
            return name == "y"
                ? "Name the number columns in y, or use agg count to count the rows per label."
                : "The column \"\(name)\" has no numbers to chart. Choose number columns for y, or use agg count."
        case .noRows:
            return "There are no rows with a label under the headings. Choose another column for x."
        case .tooManyPoints(let count, let limit):
            let line = limit == ChartBuilder.maxBars ? ", use type line (up to \(ChartBuilder.maxLinePoints) points)" : ""
            return "That gives \(count) labels; this chart shows at most \(limit). Choose an x column with fewer different values\(line), or ask the person which part to show."
        case .tooManySeries(let limit):
            return "One chart shows at most \(limit) number columns. Give up to \(limit) in y."
        case .pieNeedsOneSeries:
            return "A pie chart shows exactly one number column. Give one column in y, or use type bar."
        case .pieNeedsPositive:
            return "A pie chart needs values of zero or more with a total above zero. Use type bar instead."
        }
    }
}

/// Builds a `ChartCard` from read cells: headings and total rows from `SheetLayout`, numbers as `SheetValue.anyNumber`
/// reads them (German or English style, also as text). Plain code, no model.
public enum ChartBuilder {
    public static let maxSeries = 4, maxBars = 24, maxLinePoints = 120, maxSlices = 8, modelRows = 40, maxLabel = 60

    public static func build(_ grid: SheetGrid, x: String, y: [String], aggregate: ChartAggregate?, kind: ChartCard.Kind,
                             source: String, truncated: Bool = false, locale: Locale = .current) -> Result<ChartCard, ChartBuildFailure> {
        let agg = resolved(aggregate, y: y)
        var layout = SheetLayout.detect(grid)
        // Counting categories needs no numeric column. The requested heading still has to identify a column in
        // the first row, so a text-only status or category table can be counted without inventing numbers.
        if layout.headerRow == nil, agg == .count, grid.firstRow < grid.lastRow {
            let candidate = SheetLayout(headerRow: grid.firstRow, labelColumn: nil)
            if column(named: x, in: grid, layout: candidate) != nil { layout = candidate }
        }
        guard layout.headerRow != nil else { return .failure(.noHeadings) }
        guard y.count <= maxSeries else { return .failure(.tooManySeries(limit: maxSeries)) }
        let available = grid.columnNumbers.compactMap { layout.heading(column: $0, in: grid) }
        guard let xColumn = column(named: x, in: grid, layout: layout) else { return .failure(.unknownColumn(x, available: available)) }
        var yColumns: [Int] = []
        for name in y {
            guard let found = column(named: name, in: grid, layout: layout) else { return .failure(.unknownColumn(name, available: available)) }
            if !yColumns.contains(found) { yColumns.append(found) }
        }
        if yColumns.isEmpty && agg != .count { return .failure(.noNumbers("y")) }
        func title(_ column: Int) -> String { layout.heading(column: column, in: grid) ?? CellRef.columnName(column) }
        let xTitle = title(xColumn)
        let names = agg == .count ? [L("Count", table: "MCP")] : yColumns.map(title)

        // Rows below the headings that have a label; total rows ("Summe") stay out.
        let dates = DateFormatter()
        dates.locale = locale; dates.timeZone = TimeZone(identifier: "UTC"); dates.dateStyle = .medium; dates.timeStyle = .none
        let first = layout.firstDataRow(in: grid)
        guard first <= grid.lastRow else { return .failure(.noRows) }
        var rows: [(label: ChartLabel, values: [Double?])] = []
        var skipped = 0
        for row in first...grid.lastRow {
            let cell = grid[row, xColumn].value
            guard !cell.isEmpty, !layout.isTotalRow(row, in: grid), let shown = Self.chartLabel(cell, locale: locale, dates: dates) else { continue }
            let values: [Double?] = agg == .count ? [] : yColumns.map { grid[row, $0].value.anyNumber }
            if values.contains(where: { $0 == nil }) { skipped += 1 }
            rows.append((label: shown, values: values))
        }
        guard !rows.isEmpty else { return .failure(.noRows) }

        var labels: [ChartLabel] = []
        var series: [[Double?]] = []
        switch agg {
        case .none:
            labels = rows.map { $0.label }
            series = names.indices.map { s in rows.map { $0.values[s] } }
        case .sum, .count, .average:
            // Grouped by label, in the order the labels first appear.
            var index: [String: Int] = [:]
            var sums: [[Double]] = [], counts: [[Int]] = [], rowCounts: [Int] = []
            for row in rows {
                let i: Int
                if let known = index[row.label.identity] { i = known } else {
                    i = labels.count
                    index[row.label.identity] = i
                    labels.append(row.label)
                    sums.append(Array(repeating: 0, count: row.values.count))
                    counts.append(Array(repeating: 0, count: row.values.count))
                    rowCounts.append(0)
                }
                rowCounts[i] += 1
                for (s, value) in row.values.enumerated() {
                    if let value { sums[i][s] += value; counts[i][s] += 1 }
                }
            }
            if agg == .count {
                series = [rowCounts.map { Optional(Double($0)) }]
            } else {
                series = names.indices.map { s in
                    labels.indices.map { i -> Double? in
                        guard counts[i][s] > 0 else { return nil }
                        return agg == .sum ? sums[i][s] : sums[i][s] / Double(counts[i][s])
                    }
                }
            }
        }
        for s in series.indices {
            for i in series[s].indices {
                guard let value = series[s][i] else { continue }
                guard value.isFinite else { return .failure(.noNumbers(names[s])) }
                series[s][i] = clean(value)
            }
            if series[s].allSatisfy({ $0 == nil }) { return .failure(.noNumbers(names[s])) }
        }

        // Dates and years read left to right in time.
        let kinds = Set(labels.map(\.kind))
        if kinds.count == 1, let only = kinds.first, only != .plain {
            let order = labels.indices.sorted { (labels[$0].key, $0) < (labels[$1].key, $1) }
            labels = order.map { labels[$0] }
            series = series.map { values in order.map { values[$0] } }
        }

        var shownLabels = uniqueLabels(labels.map(\.text))
        switch kind {
        case .bar:
            guard shownLabels.count <= maxBars else { return .failure(.tooManyPoints(shownLabels.count, limit: maxBars)) }
        case .line:
            guard shownLabels.count <= maxLinePoints else { return .failure(.tooManyPoints(shownLabels.count, limit: maxLinePoints)) }
        case .pie:
            guard series.count == 1 else { return .failure(.pieNeedsOneSeries) }
            var slices: [(label: String, value: Double)] = []
            for (i, value) in series[0].enumerated() { if let value { slices.append((label: shownLabels[i], value: value)) } }
            let total = slices.reduce(0, { $0 + $1.value })
            guard slices.allSatisfy({ $0.value >= 0 }), total.isFinite, total > 0 else { return .failure(.pieNeedsPositive) }
            // Largest first; past `maxSlices` the smallest share one slice.
            slices = slices.enumerated().sorted { a, b in
                a.element.value != b.element.value ? a.element.value > b.element.value : a.offset < b.offset
            }.map { $0.element }
            if slices.count > maxSlices {
                let rest = slices[(maxSlices - 1)...].reduce(0) { $0 + $1.value }
                var merged = Array(slices.prefix(maxSlices - 1))
                merged.append((label: L("Other", table: "MCP"), value: clean(rest)))
                slices = merged
            }
            shownLabels = uniqueLabels(slices.map { $0.label })
            series = [slices.map { Optional($0.value) }]
        }

        var notes: [String] = []
        if truncated { notes.append(L("Only the first part of the table was read.", table: "MCP")) }
        if skipped == 1 { notes.append(L("One row without a number was left out.", table: "MCP")) }
        else if skipped > 1 { notes.append(L("%lld rows without a number were left out.", table: "MCP", skipped)) }
        let card = ChartCard(kind: kind, title: L("%@ by %@", table: "MCP", names.joined(separator: " · "), xTitle), xTitle: xTitle,
                             labels: shownLabels, series: zip(names, series).map { ChartCard.Series(name: $0, values: $1) },
                             footer: L("Computed by Pippa from %@", table: "MCP", source),
                             note: notes.isEmpty ? nil : notes.joined(separator: " "))
        return .success(card)
    }

    /// Without `agg`: add up the y columns, or count the rows when there are none.
    static func resolved(_ aggregate: ChartAggregate?, y: [String]) -> ChartAggregate {
        if let aggregate { return aggregate }
        return y.isEmpty ? .count : .sum
    }

    /// Heading match ignoring case, accents and spaces; else a unique "contains" match; else a column letter ("B").
    static func column(named name: String, in grid: SheetGrid, layout: SheetLayout) -> Int? {
        let wanted = fold(name)
        guard !wanted.isEmpty else { return nil }
        let headings = grid.columnNumbers.compactMap { column in
            layout.heading(column: column, in: grid).map { (column: column, folded: fold($0)) }
        }
        if let exact = headings.first(where: { $0.folded == wanted }) { return exact.column }
        // Short names would match inside many headings ("b" in "Betrag"); they can still be a column letter.
        if wanted.count >= 3 {
            let partial = headings.filter { $0.folded.contains(wanted) }
            if partial.count == 1 { return partial[0].column }
        }
        let letters = name.trimmingCharacters(in: .whitespaces)
        guard (1...3).contains(letters.count), letters.allSatisfy({ $0.isASCII && $0.isLetter }),
              let number = CellRef.columnNumber(letters), grid.columnNumbers.contains(number) else { return nil }
        return number
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { !$0.isWhitespace && $0 != ":" }
    }

    /// Float noise from adding ("0.30000000000000004") never reaches the card or the model.
    static func clean(_ value: Double) -> Double { Double(String(format: "%.12g", value)) ?? value }

    /// Shortened labels and repeated unaggregated rows must retain distinct positions in Swift Charts.
    private static func uniqueLabels(_ labels: [String]) -> [String] {
        var used = Set<String>()
        return labels.map { label in
            var shown = label, suffix = 2
            while used.contains(shown) {
                shown = "\(label) (\(suffix))"
                suffix += 1
            }
            used.insert(shown)
            return shown
        }
    }

    private static func chartLabel(_ value: SheetValue, locale: Locale, dates: DateFormatter) -> ChartLabel? {
        switch value {
        case .empty:
            return nil
        case .text(let raw):
            let one = raw.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard !one.isEmpty else { return nil }
            let text = one.count > maxLabel ? String(one.prefix(maxLabel - 1)) + "…" : one
            if let day = textDate(one) { return ChartLabel(text: text, kind: .date, key: day, identity: one) }
            if let year = Int(one), SheetLayout.isYear(Double(year)) { return ChartLabel(text: text, kind: .year, key: Double(year), identity: one) }
            return ChartLabel(text: text, kind: .plain, key: 0, identity: one)
        case .number(let n):
            if SheetLayout.isYear(n) { return ChartLabel(text: String(Int(n)), kind: .year, key: n) }
            return ChartLabel(text: n.formatted(.number.locale(locale)), kind: .plain, key: 0, identity: String(n))
        case .date(let date):
            // XLSXReader gives day numbers as midnight UTC: shown in UTC, the day stays the same everywhere.
            return ChartLabel(text: dates.string(from: date), kind: .date, key: date.timeIntervalSince1970)
        case .bool:
            return ChartLabel(text: SheetText.plain(value), kind: .plain, key: 0)
        }
    }

    /// "15.03.2026", "1.3.2026" or "2026-03-15" as seconds since 1970 (UTC), for sorting; nil for anything else.
    static func textDate(_ text: String) -> Double? {
        func number(_ part: Substring) -> Int? { part.allSatisfy({ $0.isASCII && $0.isNumber }) ? Int(part) : nil }
        let dotted = text.split(separator: ".", omittingEmptySubsequences: false)
        let dashed = text.split(separator: "-", omittingEmptySubsequences: false)
        var parts = DateComponents()
        if dotted.count == 3, (1...2).contains(dotted[0].count), (1...2).contains(dotted[1].count), dotted[2].count == 4 {
            parts.day = number(dotted[0]); parts.month = number(dotted[1]); parts.year = number(dotted[2])
        } else if dashed.count == 3, dashed[0].count == 4, dashed[1].count == 2, dashed[2].count == 2 {
            parts.year = number(dashed[0]); parts.month = number(dashed[1]); parts.day = number(dashed[2])
        } else {
            return nil
        }
        guard let day = parts.day, let month = parts.month, parts.year != nil, (1...12).contains(month), (1...31).contains(day),
              let utc = TimeZone(identifier: "UTC") else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        // 31.02. rolls over into March: not a date.
        guard let date = calendar.date(from: parts), calendar.component(.day, from: date) == day else { return nil }
        return date.timeIntervalSince1970
    }
}

/// A label as shown, and how it sorts: dates and years in time order, anything else as it came.
private struct ChartLabel {
    enum Kind: Hashable { case plain, date, year }
    var text: String
    var kind: Kind
    var key: Double
    /// Full category before display shortening; distinct source cells never aggregate because their prefixes match.
    var identity: String
    init(text: String, kind: Kind, key: Double, identity: String? = nil) {
        self.text = text; self.kind = kind; self.key = key; self.identity = identity ?? text
    }
}
