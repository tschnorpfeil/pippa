import Foundation

/// Dates in an answer that nothing the turn read shows. Small local models work "four weeks after receipt" out into a
/// date of their own, a different one each run, whatever the persona says (docs/omlx-switch.md, acceptance). The app
/// names such dates under the answer instead of trusting the model.
///
/// Shown are the dates in what tools returned, in the arguments of Pippa's write tools (the person confirmed those in
/// the native preview) and in the person's own words. The same day in any form counts (15.11.2026, 15. November 2026,
/// 2026-11-15, November 15, 2026). A date close to today is no exception: "Dienstag" turned into a date shows in
/// the calendar result like any other. Only checked once a tool returned something; a plain chat answer has nothing to check against. Dates without a year
/// ("bis 19.11.") are not seen.
public struct DateEvidence: Sendable {
    private var shown: Set<DayDate> = []
    public private(set) var hasSources = false

    public init() {}

    /// The person's own words: their dates are shown, but they are no source to check against.
    public mutating func add(prompt text: String) { shown.formUnion(Self.dates(in: text).map(\.value)) }

    public mutating func add(source text: String) {
        hasSources = true
        shown.formUnion(Self.dates(in: text).map(\.value))
    }

    private var pendingWrites: [String: String] = [:]

    /// A tool call began; a write's arguments count once it is done (the person confirmed them).
    public mutating func toolStarted(id: String, isWrite: Bool, arguments: String) {
        if isWrite { pendingWrites[id] = arguments }
    }

    /// A tool call ended; only a successful one's result is a source.
    public mutating func toolEnded(id: String, done: Bool, result: String) {
        let arguments = pendingWrites.removeValue(forKey: id)
        guard done else { return }
        add(source: result)
        if let arguments { add(source: arguments) }
    }

    /// The answer's dates that no source shows, as written, each day once, in order.
    public func unsupported(in answer: String) -> [String] {
        guard hasSources else { return [] }
        var seen = Set<DayDate>()
        return Self.dates(in: answer).compactMap { match in
            guard !shown.contains(match.value), seen.insert(match.value).inserted else { return nil }
            return match.text
        }
    }

    /// The answer's dates that a source shows, as written, each day once.
    public func supported(in answer: String) -> [String] {
        guard hasSources else { return [] }
        var seen = Set<DayDate>()
        return Self.dates(in: answer).compactMap { shown.contains($0.value) && seen.insert($0.value).inserted ? $0.text : nil }
    }

    // GermanText reads German and numeric dates; English answers write the month as a word.
    static let englishMonths: [String: Int] = [
        "january": 1, "jan": 1, "february": 2, "feb": 2, "march": 3, "mar": 3, "april": 4, "apr": 4, "may": 5,
        "june": 6, "jun": 6, "july": 7, "jul": 7, "august": 8, "aug": 8, "september": 9, "sep": 9, "sept": 9,
        "october": 10, "oct": 10, "november": 11, "nov": 11, "december": 12, "dec": 12,
    ]
    static let monthWords = "January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sept|Sep|Oct|Nov|Dec"
    /// November 15, 2026 · Nov 15th 2026
    static let monthFirst = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z])("# + monthWords + #")\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})(?!\d)"#, options: [.caseInsensitive])
    /// 15 October 2026 · 15th of October, 2026
    static let dayFirst = try! NSRegularExpression(
        pattern: #"(?<!\d)(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?("# + monthWords + #")\.?,?\s+(\d{4})(?!\d)"#, options: [.caseInsensitive])

    static func dates(in text: String) -> [TextMatch<DayDate>] {
        var out = GermanText.dates(in: text)
        let whole = NSRange(text.startIndex..., in: text)
        for (pattern, dayGroup, monthGroup) in [(monthFirst, 2, 1), (dayFirst, 1, 2)] {
            for m in pattern.matches(in: text, range: whole) {
                guard let r = Range(m.range, in: text),
                      let d = Int(text[Range(m.range(at: dayGroup), in: text)!]),
                      let mo = englishMonths[text[Range(m.range(at: monthGroup), in: text)!].lowercased()],
                      let y = Int(text[Range(m.range(at: 3), in: text)!]), let date = DayDate(year: y, month: mo, day: d),
                      !out.contains(where: { $0.range.overlaps(r) }) else { continue }
                out.append(TextMatch(value: date, range: r, text: String(text[r])))
            }
        }
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}
