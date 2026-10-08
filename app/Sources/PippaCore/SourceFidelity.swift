import Foundation
import NaturalLanguage

/// Host-side review of a free-chat answer about attached files (code decides facts, the model
/// decides words). It never adds a fact. Against the text Pippa actually read it
///
/// - removes comparison verdicts („kein Widerspruch“, „gleich“, „Abweichung“) and absence claims („nennt keinen Termin“)
///   that depend on an attachment Pippa did not read completely — unknown is not absent;
/// - removes dates, times and amounts presented as content of an attachment (or of its unread part) Pippa did not read;
/// - removes spans („eine Stunde später“) that match no difference between read dates or times;
/// - marks dates, times and amounts that occur in no read source („bitte prüfen“), as the letter line marks computed dates;
/// - states each read gap in code instead of trusting the model to mention it.
///
/// Units are lines, table rows and sentences; nothing is rewritten inside a kept sentence except the marks.
public enum SourceFidelity {
    public enum Finding: Equatable, Sendable {
        case verdictWithIncompleteSource(String)
        case absenceInIncompleteSource(String)
        case bothSourcesClaim(String)
        case valueFromUnreadSource(String)
        case unsupportedSpan(String)
        case valueNotInSources(String)
        case valueNotInNamedSource(String)
        /// The answer never named an attachment Pippa did not read completely; the code states it.
        case unstatedReadGap(String)
        /// „Quelle 1 nennt keine Höhe“ although the model was shown only excerpts of that readable source.
        case absenceInUnshownPart(String)
        /// A comparison verdict where only one source exists.
        case verdictWithoutComparison(String)

        /// Removed units leave the answer; marked values stay with a visible note.
        public var removes: Bool {
            switch self {
            case .valueNotInSources, .valueNotInNamedSource, .unstatedReadGap: return false
            default: return true
            }
        }
        /// The removed unit judged or described an incompletely read source, so the comparison stays open.
        var leavesComparisonOpen: Bool {
            switch self {
            case .verdictWithIncompleteSource, .absenceInIncompleteSource, .bothSourcesClaim, .valueFromUnreadSource: return true
            default: return false
            }
        }
    }

    public struct Review: Equatable, Sendable {
        public let text: String
        public let findings: [Finding]
        public var changed: Bool { !findings.isEmpty }
    }

    typealias ReadStatus = DocumentReadStatus

    /// Values a source contains, compared by value rather than by spelling („14.10.2026“ = „14. Oktober 2026“).
    struct Facts: Equatable {
        var dates: Set<DayDate> = []
        var times: Set<Int> = []
        var amounts: Set<Decimal> = []
        var spans: Set<Span> = []

        init() {}
        init(_ text: String) {
            dates = Set(GermanText.dates(in: text).map(\.value))
            times = Set(SourceFidelity.times(in: text).map(\.value))
            amounts = Set(GermanText.amounts(in: text).map { abs($0.value) })
            spans = Set(SourceFidelity.spans(in: text).map(\.value))
        }
        mutating func merge(_ other: Facts) {
            dates.formUnion(other.dates); times.formUnion(other.times); amounts.formUnion(other.amounts); spans.formUnion(other.spans)
        }
    }

    struct Span: Hashable { var minutes: Int }

    struct Source {
        let number: Int
        let name: String
        let status: ReadStatus
        let isFile: Bool
        /// Readable, but the model was shown only some of its passages for this answer.
        let excerptOnly: Bool
        let aliases: [String]
        let facts: Facts
        var complete: Bool { status == .readable }
        var read: Bool { status == .readable || status == .partial }
    }

    /// `snapshots` as `LocalEngine.snapshots` builds them: optional selected text/workflow first, then one per file.
    /// Source numbers match the read-status manifest (source evidence of the old selection step). `excerptOnly`: snapshot indices
    /// whose passages were shown only in part for this answer (selection evidence).
    public static func review(answer: String, question: String, snapshots: [DocumentSnapshot], fileCount: Int,
                              excerptOnly: Set<Int> = []) -> Review {
        let firstFile = max(0, snapshots.count - fileCount)
        let stems = snapshots.map { stem($0.name) }
        let sources: [Source] = snapshots.enumerated().map { index, snapshot in
            let readText = snapshot.readStatus == .readable || snapshot.readStatus == .partial ? snapshot.text : ""
            var aliases = ["quelle \(index + 1)", "source \(index + 1)", GermanText.fold(snapshot.name)]
            // A bare stem names a source only when it is distinctive; „Termin“ is also an ordinary word.
            if stems[index].count >= 4, stems.filter({ $0 == stems[index] }).count == 1 { aliases.append(stems[index]) }
            return Source(number: index + 1, name: snapshot.name, status: snapshot.readStatus, isFile: index >= firstFile,
                          excerptOnly: snapshot.readStatus == .readable && excerptOnly.contains(index), aliases: Array(Set(aliases)).sorted { $0.count > $1.count }, facts: Facts(readText))
        }
        var pool = Facts(question)
        for source in sources where source.read { pool.merge(source.facts) }
        let reviewer = Reviewer(sources: sources, pool: pool, language: language(question: question, answer: answer))
        return reviewer.run(answer)
    }

    /// Code-written notes follow the conversation („de“/„en“), not the Mac's language; otherwise the system's.
    static func language(question: String, answer: String) -> String? {
        // Only the languages Pippa is translated into; the person's question first, else the answer.
        for text in [question, answer] where text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8 {
            let recognizer = NLLanguageRecognizer()
            recognizer.languageConstraints = [.german, .english]
            recognizer.processString(text)
            switch recognizer.dominantLanguage {
            case .german?: return "de"
            case .english?: return "en"
            default: continue
            }
        }
        return nil
    }

    // MARK: Review

    struct Reviewer {
        let sources: [Source]
        let pool: Facts
        let language: String?
        var incomplete: [Source] { sources.filter { $0.isFile && !$0.complete } }

        func run(_ answer: String) -> Review {
            var findings: [Finding] = []
            var output: [String] = []
            let lines = answer.components(separatedBy: "\n")
            var index = 0
            while index < lines.count {
                let line = lines[index]
                if index + 1 < lines.count, SourceFidelity.isTableRow(line), SourceFidelity.isSeparatorRow(lines[index + 1]) {
                    let header = SourceFidelity.cells(line)
                    let columns = header.map { cell -> Int? in let found = self.named(in: cell); return found.count == 1 ? found.first : nil }
                    output.append(line); output.append(lines[index + 1])
                    index += 2
                    while index < lines.count, SourceFidelity.isTableRow(lines[index]) {
                        let (kept, rowFindings) = reviewRow(lines[index], columns: columns)
                        findings += rowFindings
                        if let kept { output.append(kept) }
                        index += 1
                    }
                    continue
                }
                let (kept, lineFindings) = reviewLine(line)
                findings += lineFindings
                if let kept { output.append(kept) }
                index += 1
            }
            var text = SourceFidelity.tidy(output)
            let removedOpen = findings.contains { $0.removes && $0.leavesComparisonOpen }
            let removedAny = findings.contains(where: \.removes)
            let gaps = incomplete
            let mentioned = self.named(in: text)
            let unmentioned = gaps.contains { !mentioned.contains($0.number - 1) }
            if !gaps.isEmpty && (removedAny || unmentioned) {
                if !removedAny { findings.append(contentsOf: gaps.filter { !mentioned.contains($0.number - 1) }.map { .unstatedReadGap($0.name) }) }
                var note = gaps.map { gap in SourceFidelity.gapSentence(gap, language: language, duplicateName: sources.filter { $0.name == gap.name }.count > 1) }
                if removedOpen { note.append(L("Whether the details match therefore remains open.", table: "Core", language: language)) }
                let block = "**" + L("Open:", table: "Core", language: language) + "** " + note.joined(separator: " ")
                // A removed verdict leaves the answer without its lead: the read gap comes first.
                text = text.isEmpty ? block : removedAny ? block + "\n\n" + text : text + "\n\n" + block
            } else if findings.contains(where: { if case .absenceInUnshownPart = $0 { return true }; return false }) {
                let excerpts = sources.filter { $0.isFile && $0.excerptOnly }.map {
                    L("I looked only at excerpts of “%@” for this answer; anything else in it is unchecked.", table: "Core", language: language, $0.name)
                }
                text = "**" + L("Open:", table: "Core", language: language) + "** " + excerpts.joined(separator: " ") + (text.isEmpty ? "" : "\n\n" + text)
            } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && removedAny {
                text = L("I can’t confirm that from the sources I read.", table: "Core", language: language)
            }
            return Review(text: findings.isEmpty ? answer : text, findings: findings)
        }

        /// Indices of sources a text names by file name, distinctive stem or manifest number („Quelle 2“).
        func named(in text: String) -> Set<Int> {
            let folded = GermanText.fold(text)
            // „Quelle 1 [Termin.txt]“: the number picks one of several sources sharing a file name.
            let numbered = Set(sources.indices.filter { index in ["quelle", "source"].contains { SourceFidelity.containsWord("\($0) \(sources[index].number)", in: folded) } })
            var result = numbered
            for (index, source) in sources.enumerated() where source.aliases.contains(where: { SourceFidelity.containsWord($0, in: folded) }) {
                let sharing = Set(sources.indices.filter { sources[$0].name == source.name })
                if sharing.count == 1 || numbered.isDisjoint(with: sharing) { result.insert(index) }
            }
            return result
        }

        /// The source a line is about when it starts with its name („- **Vertrag.txt**: …“, „Quelle 2 [Termin.txt]: …“).
        func label(of line: String) -> Int? {
            let stripped = GermanText.fold(line).replacingOccurrences(of: #"^[\s>*\-•+#_\[„"“(]*(?:\d+[.)]\s*)?[\s*_\[„"“(]*"#, with: "", options: .regularExpression)
            var matches = Set<Int>()
            for (index, source) in sources.enumerated() {
                for alias in source.aliases where stripped.hasPrefix(alias) {
                    let rest = stripped.dropFirst(alias.count)
                    if rest.first.map({ !$0.isLetter && !$0.isNumber }) ?? true { matches.insert(index) }
                }
            }
            return matches.count == 1 ? matches.first : nil
        }

        func reviewLine(_ line: String) -> (String?, [Finding]) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return (line, []) }
            let prefix = line.range(of: #"^\s*(?:>\s*)?(?:[-*+•]|\d+[.)])\s+"#, options: .regularExpression).map { String(line[$0]) } ?? ""
            let body = String(line.dropFirst(prefix.count))
            let lineLabel = label(of: line)
            var findings: [Finding] = []
            var kept: [String] = []
            for sentence in SourceFidelity.sentences(body) {
                let own = self.named(in: sentence)
                // A line label covers its sentences unless a sentence names another source itself.
                let label = lineLabel.flatMap { own.subtracting([$0]).isEmpty ? $0 : nil }
                let named = own.union(label.map { [$0] } ?? [])
                // Prose naming one source is enough to remove a value from an unread source, not to mark a read one.
                let attributed = label ?? (named.count == 1 ? named.first : nil)
                if let removal = removal(sentence, clauses: SourceFidelity.clauses(sentence), named: named, attributed: attributed) {
                    // „Vertrag: 14.10.2026 – kein Widerspruch belegt“: drop only the judging tail, keep the read fact.
                    if let trimmed = trimmedTail(sentence, named: named, attributed: attributed) {
                        findings += trimmed.findings
                        let (marked, marks) = mark(trimmed.text, attributed: label)
                        findings += marks
                        kept.append(marked)
                    } else {
                        findings.append(removal)
                    }
                    continue
                }
                let (marked, marks) = mark(sentence, attributed: label)
                findings += marks
                kept.append(marked)
            }
            guard findings.contains(where: \.removes) else {
                return (findings.isEmpty ? line : prefix + kept.joined(separator: " "), findings)
            }
            var rest = kept.joined(separator: " ")
            if rest.components(separatedBy: "**").count % 2 == 0 { rest = rest.replacingOccurrences(of: "**", with: "") }
            let meaningful = rest.trimmingCharacters(in: CharacterSet(charactersIn: " \t*_-–—:•|")).contains { $0.isLetter || $0.isNumber }
            return (meaningful ? prefix + rest : nil, findings)
        }

        /// A sentence whose head is sound and whose offending parts follow a dash or semicolon keeps its head.
        /// Nil when the head itself must go or nothing would be removed.
        func trimmedTail(_ sentence: String, named: Set<Int>, attributed: Int?) -> (text: String, findings: [Finding])? {
            let parts = SourceFidelity.segments(sentence)
            guard parts.count > 1 else { return nil }
            func check(_ part: String) -> Finding? { removal(part, clauses: SourceFidelity.clauses(part), named: named, attributed: attributed) }
            guard check(parts[0].text) == nil else { return nil }
            var text = parts[0].text, findings: [Finding] = []
            for part in parts.dropFirst() {
                if let finding = check(part.text) { findings.append(finding) } else { text += part.separator + part.text }
            }
            guard !findings.isEmpty else { return nil }
            text = text.trimmingCharacters(in: .whitespaces)
            if let end = sentence.trimmingCharacters(in: .whitespaces).last, ".!?".contains(end), !(text.last.map { ".!?".contains($0) } ?? false) {
                text.append(end)
            }
            return (text, findings)
        }

        func reviewRow(_ row: String, columns: [Int?]) -> (String?, [Finding]) {
            let cells = SourceFidelity.cells(row)
            let rowNamed = cells.first.map { named(in: $0) } ?? []
            let rowSource = rowNamed.count == 1 ? rowNamed.first : nil
            var involved = rowNamed
            for (index, cell) in cells.enumerated() where index < columns.count && !cell.trimmingCharacters(in: .whitespaces).isEmpty {
                if let column = columns[index] { involved.insert(column) }
            }
            var findings: [Finding] = []
            var out = cells
            for (index, cell) in cells.enumerated() {
                let attributed = index > 0 ? (rowSource ?? (index < columns.count ? columns[index] : nil)) : rowSource
                var cellNamed = involved
                if let attributed { cellNamed.insert(attributed) }
                let clauses = SourceFidelity.isVerdictWord(cell) ? [cell] : SourceFidelity.clauses(cell)
                if let removal = removal(cell, clauses: clauses, named: cellNamed, attributed: attributed, verdictWord: SourceFidelity.isVerdictWord(cell)) {
                    return (nil, [removal])
                }
                let (marked, marks) = mark(cell, attributed: attributed)
                findings += marks
                out[index] = marked
            }
            return (findings.isEmpty ? row : "| " + out.joined(separator: " | ") + " |", findings)
        }

        /// A unit that must leave the answer, or nil.
        func removal(_ unit: String, clauses: [String], named: Set<Int>, attributed: Int?, verdictWord: Bool = false) -> Finding? {
            let gaps = Set(sources.indices.filter { sources[$0].isFile && !sources[$0].complete })
            let excerpts = Set(sources.indices.filter { sources[$0].isFile && sources[$0].excerptOnly })
            // A question asserts nothing („… im Schreiben nicht erwähnt?“).
            let claims = !unit.trimmingCharacters(in: .whitespaces).hasSuffix("?")
            let verdict = claims && (verdictWord || clauses.contains { SourceFidelity.matches($0, SourceFidelity.verdict) && !SourceFidelity.matches($0, SourceFidelity.open) })
            // „Keine Abweichung zwischen den Quellen“ with one source compares nothing; a check inside one document stays.
            if verdict && sources.count < 2 && SourceFidelity.matches(unit, SourceFidelity.sourcesPlural) { return .verdictWithoutComparison(unit) }
            if claims && !excerpts.isEmpty {
                for clause in clauses where SourceFidelity.matches(clause, SourceFidelity.absence) && !SourceFidelity.matches(clause, SourceFidelity.scoped) {
                    let clauseNamed = self.named(in: clause)
                    let about = !clauseNamed.isEmpty ? clauseNamed : attributed.map { [$0] } ?? named
                    if !about.isDisjoint(with: excerpts) && about.isDisjoint(with: gaps) { return .absenceInUnshownPart(unit) }
                }
            }
            if claims && !gaps.isEmpty {
                // A verdict stands only for the named, completely read sources it compares.
                if verdict && !(named.count >= 2 && named.isDisjoint(with: gaps)) { return .verdictWithIncompleteSource(unit) }
                for clause in clauses where SourceFidelity.matches(clause, SourceFidelity.absence) && !SourceFidelity.matches(clause, SourceFidelity.scoped) {
                    let clauseNamed = self.named(in: clause)
                    // An unnamed clause is about the unit's source: its line label or table column, else all it names.
                    let about = !clauseNamed.isEmpty ? clauseNamed : attributed.map { [$0] } ?? named
                    if !about.isDisjoint(with: gaps) { return .absenceInIncompleteSource(unit) }
                }
            }
            // „Beide Quellen belegen …“ claims content for two read sources; there must be two, read completely.
            if claims, (!gaps.isEmpty || sources.count < 2),
               clauses.contains(where: { SourceFidelity.matches($0, SourceFidelity.both) && !SourceFidelity.matches($0, SourceFidelity.open) }) {
                return .bothSourcesClaim(unit)
            }
            if let attributed {
                let source = sources[attributed]
                if !source.complete {
                    for value in SourceFidelity.values(in: unit) where !contains(source.facts, value.kind) {
                        return .valueFromUnreadSource(unit)
                    }
                }
            }
            if SourceFidelity.matches(unit, SourceFidelity.comparisonCue) {
                for span in SourceFidelity.spans(in: unit) where !supports(span.value) { return .unsupportedSpan(unit) }
            }
            return nil
        }

        func mark(_ unit: String, attributed: Int?) -> (String, [Finding]) {
            var text = ""
            var findings: [Finding] = []
            var position = unit.startIndex
            for value in SourceFidelity.values(in: unit) {
                let finding: Finding
                if let attributed, sources[attributed].complete {
                    guard !contains(sources[attributed].facts, value.kind), !computed(value.kind) else { continue }
                    finding = contains(pool, value.kind) ? .valueNotInNamedSource(value.text) : .valueNotInSources(value.text)
                } else {
                    guard !contains(pool, value.kind), !computed(value.kind) else { continue }
                    finding = .valueNotInSources(value.text)
                }
                let note = finding == .valueNotInNamedSource(value.text)
                    ? L("please check: not in this source", table: "Core", language: language) : L("please check: not in the sources I read", table: "Core", language: language)
                text += unit[position..<value.range.upperBound] + " (\(note))"
                position = value.range.upperBound
                findings.append(finding)
            }
            return (findings.isEmpty ? unit : text + unit[position...], findings)
        }

        func contains(_ facts: Facts, _ kind: Value.Kind) -> Bool {
            switch kind {
            case .date(let d): return facts.dates.contains(d)
            case .time(let t): return facts.times.contains(t)
            case .amount(let a): return facts.amounts.contains(abs(a))
            }
        }

        /// A difference or sum of two read amounts is arithmetic the code can confirm.
        func computed(_ kind: Value.Kind) -> Bool {
            guard case .amount(let value) = kind else { return false }
            let target = abs(value)
            let amounts = Array(pool.amounts)
            for i in amounts.indices { for j in amounts.indices where i < j {
                if abs(amounts[i] - amounts[j]) == target || amounts[i] + amounts[j] == target { return true }
            } }
            return false
        }

        /// A span matches a difference between two read dates or times, or is stated in a source itself.
        func supports(_ span: Span) -> Bool {
            if pool.spans.contains(span) { return true }
            let days = pool.dates.map(SourceFidelity.dayNumber)
            for a in days { for b in days where a != b && abs(a - b) * 1440 == span.minutes { return true } }
            let times = Array(pool.times)
            for a in times { for b in times where a != b && abs(a - b) == span.minutes { return true } }
            return false
        }
    }

    // MARK: Values

    struct Value {
        enum Kind: Equatable { case date(DayDate), time(Int), amount(Decimal) }
        let kind: Kind
        let range: Range<String.Index>
        let text: String
    }

    /// Dates, clock times and amounts in order; times inside dates are not separate values.
    static func values(in text: String) -> [Value] {
        var result: [Value] = GermanText.dates(in: text).map { Value(kind: .date($0.value), range: $0.range, text: $0.text) }
        result += times(in: text).filter { time in !result.contains { $0.range.overlaps(time.range) } }
            .map { Value(kind: .time($0.value), range: $0.range, text: $0.text) }
        result += GermanText.amounts(in: text).filter { amount in !result.contains { $0.range.overlaps(amount.range) } }
            .map { Value(kind: .amount($0.value), range: $0.range, text: $0.text) }
        return result.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    static let clock = try! NSRegularExpression(pattern: #"(?<![\d:.,])([01]?\d|2[0-3])(?:[:.]([0-5]\d))?\s*Uhr\b"#, options: [.caseInsensitive])

    /// „09:00 Uhr“, „9.30 Uhr“, „10 Uhr“ as minutes after midnight.
    static func times(in text: String) -> [TextMatch<Int>] {
        clock.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text), let hourRange = Range(match.range(at: 1), in: text),
                  let hour = Int(text[hourRange]) else { return nil }
            let minute = Range(match.range(at: 2), in: text).flatMap { Int(text[$0]) } ?? 0
            return TextMatch(value: hour * 60 + minute, range: range, text: String(text[range]))
        }
    }

    static let numberWords = ["ein": 1, "eine": 1, "einen": 1, "einem": 1, "einer": 1, "zwei": 2, "drei": 3, "vier": 4, "fuenf": 5, "sechs": 6,
                              "sieben": 7, "acht": 8, "neun": 9, "zehn": 10, "elf": 11, "zwoelf": 12, "vierzehn": 14,
                              "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "twelve": 12, "fourteen": 14]
    static let spanPattern = try! NSRegularExpression(pattern: #"(?<![\p{L}\d])(\d{1,3}|ein|eine|einen|einem|einer|zwei|drei|vier|fuenf|sechs|sieben|acht|neun|zehn|elf|zwoelf|vierzehn|one|two|three|four|five|six|seven|eight|nine|ten|twelve|fourteen)\s+(tag|tage|tagen|stunde|stunden|woche|wochen|minute|minuten|day|days|hour|hours|week|weeks|minutes)(?![\p{L}])"#)

    /// „einen Tag“, „2 Stunden“, „drei Wochen“ as minutes (folded text).
    static func spans(in text: String) -> [TextMatch<Span>] {
        let folded = GermanText.fold(text)
        return spanPattern.matches(in: folded, range: NSRange(folded.startIndex..., in: folded)).compactMap { match in
            guard let range = Range(match.range, in: folded), let n = Range(match.range(at: 1), in: folded), let u = Range(match.range(at: 2), in: folded) else { return nil }
            let count = Int(folded[n]) ?? numberWords[String(folded[n])] ?? 0
            let unit = String(folded[u])
            let minutes = unit.hasPrefix("minute") ? 1 : unit.hasPrefix("stunde") || unit.hasPrefix("hour") ? 60
                : unit.hasPrefix("woche") || unit.hasPrefix("week") ? 7 * 1440 : 1440
            return TextMatch(value: Span(minutes: count * minutes), range: range, text: String(folded[range]))
        }
    }

    static func dayNumber(_ date: DayDate) -> Int { date.excelSerial }

    // MARK: Language patterns, German and English (on folded text: lower case, ä → ae)

    static func pattern(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }

    /// A comparison verdict: agreement, no conflict, or a difference.
    static let verdict = pattern(#"\bkein\w*\s+(?:\w+\s+){0,2}?\w*(?:widerspr\w*|abweichung\w*|unterschied\w*|differenz\w*|konflikt\w*)|widerspruchsfrei|uebereinstimm\w*|\bstimm\w*\s+(?:\w+\s+){0,4}?ueberein\b|\bidentisch\b|\b(?:sind|ist|bleiben|bleibt|waeren|sei)\s+(?:\w+\s+){0,2}?(?:gleich|dieselbe\w*|identisch)\b|\bgleich(?:e|en)?\s+(?:termin\w*|datum\w*|bedingung\w*|angabe\w*|preis\w*|betrag\w*|lieferung\w*)|\b(?:es\s+gibt|gibt\s+es|besteht|bestehen|liegt|liegen|ergibt\s+sich)\s+(?:\w+\s+){0,3}?\w*(?:widerspr\w*|abweichung\w*|unterschied\w*)|\bweich\w*\s+(?:\w+\s+){0,5}?ab\b|\bunterscheid\w*|\bunterschiedlich\w*|\bno\s+(?:\w+\s+){0,2}?(?:conflict\w*|discrepanc\w*|difference\w*|contradiction\w*|mismatch\w*)|\b(?:match|matches|agree|agrees|identical|consistent)\b|\b(?:is|are)\s+(?:\w+\s+){0,2}?the\s+same\b|\bthere\s+(?:is|are)\s+(?:\w+\s+){0,2}?(?:conflict\w*|discrepanc\w*|difference\w*|mismatch\w*)|\bdiffer\w*"#)
    /// The clause leaves the question open instead of answering it.
    static let open = pattern(#"\bob\b|\boffen\b|unklar|unbekannt|unentschieden|unentscheidbar|nicht\s+(?:\w+\s+){0,2}?(?:entscheid|beurteil|sagen|vergleich|bestimm|bewert|feststell|pruef|ermittel|klaer)\w*|keine\s+aussage|nicht\s+moeglich|unmoeglich|\bwhether\b|\bopen\b|unclear|unknown|undetermined|\bcan(?:not|'t|’t)\s+(?:\w+\s+){0,2}?(?:tell|say|determine|compare|confirm|judge|decide)|not\s+possible|impossible"#)
    /// The clause says a fact is missing from a source.
    static let absence = pattern(#"\bkein\w*\s+(?:\w+\s+){0,2}?\w*(?:termin\w*|datum|daten|angabe\w*|betrag\w*|betraege|preis\w*|frist\w*|hinweis\w*|information\w*|zeitpunkt\w*|uhrzeit\w*|zeit\w*|liefer\w*|hoehe|summe\w*|kosten\w*|wert\w*)|\bkein\w*\s+(?:\w+\s+){0,2}?(?:genannt|angegeben|erwaehnt)\b|\bnicht\s+(?:\w+\s+){0,2}?(?:genannt|angegeben|erwaehnt|spezifiziert|enthalten|aufgefuehrt|festgelegt|definiert)\b|\benthaelt\s+nichts\b|\b(?:enthaelt|steht|nennt)\s+(?:\w+\s+){0,3}?(?:lediglich|nur)\b|\bno\s+(?:\w+\s+){0,2}?(?:date|deadline|amount|price|time|information|details?)\b|\bnot\s+(?:\w+\s+){0,2}?(?:mentioned|stated|listed|specified|included|given)\b|\bdoes\s*(?:not|n't|n’t)\s+(?:\w+\s+){0,2}?(?:mention|state|list|specify|contain|include|give)\b|\b(?:contains|says|mentions|states)\s+only\b|\bonly\s+(?:contains|says|mentions|states)\b"#)
    /// The absence is limited to what was read, or stated as unknown, which is true.
    static let scoped = pattern(#"gelesen\w*\s+(?:teil|abschnitt|ausschnitt|bereich|text)|soweit\s+(?:ich\s+)?(?:\w+\s+)?gelesen|bisher\s+gelesen|\bbekannt\b|unbekannt|\bob\b|\bread\s+(?:part|section|portion|excerpt)|as\s+far\s+as\s+i\s+(?:could\s+)?read|\bknown\b|unknown|\bwhether\b"#)
    /// Content claimed for both documents at once.
    static let both = pattern(#"\bbeide\w*\s+(?:\w+\s+)?(?:dokument|quell|datei|unterlag|schreiben|text)\w*|\bboth\s+(?:\w+\s+)?(?:document|source|file|letter|text)s?\b"#)
    /// Several sources at once.
    static let sourcesPlural = pattern(#"\b(?:quellen|dokumente\w*|dateien|unterlagen|sources|documents|files)\b"#)
    /// A span is only checked where it states a distance between facts.
    static let comparisonCue = pattern(#"spaeter|frueher|differenz|unterschied|unterscheid|abstand|versetzt|verschoben|auseinander|abweich|weicht|later|earlier|difference|differ|apart|shifted"#)
    static let verdictWords: Set<String> = ["abweichung", "abweichend", "uebereinstimmung", "uebereinstimmend", "gleich", "identisch", "unterschiedlich",
                                            "widerspruch", "kein widerspruch", "keine abweichung", "stimmt ueberein", "ok", "passt",
                                            "match", "matches", "mismatch", "difference", "different", "same", "no conflict", "conflict"]

    static func matches(_ text: String, _ expression: NSRegularExpression) -> Bool {
        let folded = GermanText.fold(text)
        return expression.firstMatch(in: folded, range: NSRange(folded.startIndex..., in: folded)) != nil
    }

    static func isVerdictWord(_ cell: String) -> Bool {
        let folded = GermanText.fold(cell).trimmingCharacters(in: CharacterSet(charactersIn: " *_.!✓✗"))
        return verdictWords.contains(folded)
    }

    static func containsWord(_ word: String, in folded: String) -> Bool {
        var start = folded.startIndex
        while let range = folded.range(of: word, range: start..<folded.endIndex) {
            let before = range.lowerBound == folded.startIndex ? nil : folded[folded.index(before: range.lowerBound)]
            let after = range.upperBound == folded.endIndex ? nil : folded[range.upperBound]
            if !(before.map { $0.isLetter || $0.isNumber } ?? false) && !(after.map { $0.isLetter || $0.isNumber } ?? false) { return true }
            start = folded.index(after: range.lowerBound)
        }
        return false
    }

    static func stem(_ name: String) -> String {
        let folded = GermanText.fold(name)
        guard let dot = folded.lastIndex(of: "."), dot != folded.startIndex else { return folded }
        return String(folded[..<dot])
    }

    // MARK: Text units

    static func isTableRow(_ line: String) -> Bool { line.trimmingCharacters(in: .whitespaces).hasPrefix("|") }
    static func isSeparatorRow(_ line: String) -> Bool {
        line.range(of: #"^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$"#, options: .regularExpression) != nil
    }
    static func cells(_ row: String) -> [String] {
        var trimmed = row.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Sentences end at . ! ? before a capital, digit, quote or markup; „14.10. um“ and „Nr. 5“-like dots inside stay.
    static func sentences(_ text: String) -> [String] {
        let marked = text.replacingOccurrences(of: #"(?<=[.!?])\s+(?=[\p{Lu}„"*\[(])"#, with: "\u{1}", options: .regularExpression)
        return marked.components(separatedBy: "\u{1}").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Parts of a sentence after a dash or semicolon, with the separator that preceded each.
    static func segments(_ sentence: String) -> [(separator: String, text: String)] {
        let expression = try! NSRegularExpression(pattern: #"\s[–—-]\s|;\s"#)
        var result: [(separator: String, text: String)] = []
        var start = sentence.startIndex, separator = ""
        for match in expression.matches(in: sentence, range: NSRange(sentence.startIndex..., in: sentence)) {
            guard let range = Range(match.range, in: sentence) else { continue }
            result.append((separator, String(sentence[start..<range.lowerBound])))
            separator = String(sentence[range]); start = range.upperBound
        }
        result.append((separator, String(sentence[start...])))
        return result.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Clauses split at punctuation and conjunctions that introduce a reason or contrast.
    static func clauses(_ sentence: String) -> [String] {
        let marked = sentence.replacingOccurrences(of: #"[,;:()]|\s[–—-]\s|\b(?:da|weil|denn|aber|jedoch|sondern|waehrend|während|wobei|because|since|but|however|while|whereas)\b"#,
                                                   with: "\u{1}", options: [.regularExpression, .caseInsensitive])
        return marked.components(separatedBy: "\u{1}").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func tidy(_ lines: [String]) -> String {
        // A heading or bold label („**Abweichung:**“) whose content was removed goes too.
        let label = #"^\s*(?:#{1,6}\s+.+|\*\*[^*]+\*\*:?)\s*$"#
        var kept: [String] = []
        for (index, line) in lines.enumerated() {
            if line.range(of: label, options: .regularExpression) != nil {
                let next = lines[(index + 1)...].first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                if next.map({ $0.range(of: label, options: .regularExpression) != nil }) ?? true { continue }
            }
            kept.append(line)
        }
        var result: [String] = []
        for line in kept {
            if line.trimmingCharacters(in: .whitespaces).isEmpty, result.last?.trimmingCharacters(in: .whitespaces).isEmpty ?? true { continue }
            result.append(line)
        }
        while result.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { result.removeLast() }
        return result.joined(separator: "\n")
    }

    static func gapSentence(_ source: Source, language: String?, duplicateName: Bool) -> String {
        let name = duplicateName ? L("%@ (source %lld)", table: "Core", language: language, source.name, source.number) : source.name
        switch source.status {
        case .partial: return L("I could read only part of “%@”; the rest is unknown.", table: "Core", language: language, name)
        case .unreadable: return L("I couldn’t read any text in “%@”.", table: "Core", language: language, name)
        case .metadataOnly: return L("Of “%@” I know only the names, not the contents.", table: "Core", language: language, name)
        case .unavailable, .readable: return L("“%@” is not available, so I couldn’t read it.", table: "Core", language: language, name)
        }
    }
}
