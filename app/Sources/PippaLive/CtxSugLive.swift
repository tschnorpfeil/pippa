import Foundation
import PDFKit
import PippaCore

/// CTX/SUG suggestion evaluation over the generated corpus (scripts/quality/make-ctxsug-corpus.swift)
/// against criteria fixed beforehand (cases file, PIPPA_CTXSUG_CASES). Mirrors TrayController:
/// rules first, Apple FM role only for a single item and only if it finishes within the line's deadline.
@MainActor
enum CtxSugLive {
    struct Cases: Decodable { let schemaVersion: Int; let cases: [Case] }
    struct Case: Decodable {
        let id: String; let `class`: String; let files: [String]; let acceptedRoles: [String]
        let finalAnyOf: [String]; let required: Bool; let forbidden: [String]; let firstVisible: String?; let note: String
    }
    struct Row: Encodable {
        let id: String; let caseClass: String; let run: Int
        let firstOffered: [String]; let firstMS: Double; let firstVerdict: String; let firstWhy: String
        let sampleChars: Int?; let sampleMS: Double; let samplePreview: String?
        let role: String?; let acceptedRole: Bool?; let classifyMS: Double?; let lateForLine: Bool
        let finalOffered: [String]; let replaced: Bool; let finalVerdict: String; let finalWhy: String
    }

    /// TrayController's refinement deadline.
    static let lineDeadlineMS = 4_000.0

    static func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

    static func run(arguments: [String]) async throws {
        let env = ProcessInfo.processInfo.environment
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } }
        let useFM = arguments.contains("--apple-fm")
        let repeats = max(1, Int(value("--repeat") ?? "1") ?? 1)
        let corpus = URL(fileURLWithPath: value("--corpus") ?? ".build/quality/ctxsug-corpus", relativeTo: cwd)
        let casesURL = URL(fileURLWithPath: env["PIPPA_CTXSUG_CASES"] ?? "app/Fixtures/ctxsug-cases.json", relativeTo: cwd)
        let spec = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: casesURL))
        guard spec.schemaVersion == 1 else { throw NSError(domain: "CtxSug", code: 1) }
        let skills = PippaSkill.load(from: cwd.appendingPathComponent("runtime/pippa-skills", isDirectory: true), german: true)
        let labelled = Set(skills.filter { $0.title != nil }.map(\.name))
        let backed = labelled.union(ToolID.allCases.map(\.rawValue)).union(["tidy", "invoice-table"])
        let only = value("--only").map { Set($0.split(separator: ",").map(String.init)) }

        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        print("# ctxsug suggestions · \(useFM ? "rules + apple-fm" : "rules only") · repeats \(repeats) · \(spec.cases.count) cases · skills \(labelled.sorted().joined(separator: ","))")
        let clock = ContinuousClock()
        var rows: [Row] = []
        for run in 1...repeats {
            for item in spec.cases where only?.contains(item.id) ?? true {
                let urls = item.files.map { name -> URL in
                    name.hasSuffix("/") ? corpus.appendingPathComponent(String(name.dropLast()), isDirectory: true) : corpus.appendingPathComponent(name)
                }
                guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                    print("MISSING \(item.id): run scripts/quality/make-ctxsug-corpus.swift first"); continue
                }
                let firstStart = clock.now
                let first = ThingActions.offered(for: urls, records: [], skills: skills, role: .unknown).map(\.id)
                let firstMS = ms(clock.now - firstStart)

                let sampleStart = clock.now
                let sample = urls.count == 1 ? DocumentSuggestions.sample(for: urls[0]) : nil
                let sampleMS = ms(clock.now - sampleStart)

                var role: DocumentRole?
                var classifyMS: Double?
                if useFM, urls.count == 1 {
                    let start = clock.now
                    role = await DocumentSuggestions.classify(urls)
                    classifyMS = ms(clock.now - start)
                }
                let late = (classifyMS ?? 0) > lineDeadlineMS
                let effective = late ? DocumentRole.unknown : (role ?? .unknown)
                let final = ThingActions.offered(for: urls, records: [], skills: skills, role: effective).map(\.id)
                let firstJudge = judge(first, item, backed: backed, final: false)
                let finalJudge = judge(final, item, backed: backed, final: true)
                let preview = sample.map { String($0.replacingOccurrences(of: "\n", with: " ⏎ ").prefix(140)) }
                let row = Row(id: item.id, caseClass: item.class, run: run, firstOffered: first, firstMS: firstMS,
                              firstVerdict: firstJudge.0, firstWhy: firstJudge.1, sampleChars: sample?.count, sampleMS: sampleMS,
                              samplePreview: preview, role: role?.rawValue, acceptedRole: role.map { item.acceptedRoles.contains($0.rawValue) },
                              classifyMS: classifyMS, lateForLine: late, finalOffered: final, replaced: final != first,
                              finalVerdict: finalJudge.0, finalWhy: finalJudge.1)
                rows.append(row)
                print(String(decoding: try encoder.encode(row), as: UTF8.self))
            }
        }
        summarize(rows, useFM: useFM)
    }

    /// Returns verdict PASS/WEAK/FAIL and the reason, per the cases file "judging" section.
    static func judge(_ offered: [String], _ item: Case, backed: Set<String>, final: Bool) -> (String, String) {
        let visible = Array(offered.prefix(2))
        var fails: [String] = []
        let forbidden = offered.filter { item.forbidden.contains($0) }
        if !forbidden.isEmpty { fails.append("forbidden " + forbidden.joined(separator: ",")) }
        let unbacked = offered.filter { !backed.contains($0) }
        if !unbacked.isEmpty { fails.append("unbacked " + unbacked.joined(separator: ",")) }
        if let expected = item.firstVisible, offered.first != expected { fails.append("first is \(offered.first ?? "none"), expected \(expected)") }
        let hit = item.finalAnyOf.isEmpty || item.finalAnyOf.contains { visible.contains($0) }
        if final && item.required && !hit { fails.append("missing visible " + item.finalAnyOf.joined(separator: "|")) }
        if !fails.isEmpty { return ("FAIL", fails.joined(separator: "; ")) }
        if !hit { return ("WEAK", "none of " + item.finalAnyOf.joined(separator: "|") + " visible") }
        return ("PASS", "")
    }

    static func summarize(_ rows: [Row], useFM: Bool) {
        func pct(_ values: [Double], _ p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        }
        print("\n# Summary by class (first = rules, final = \(useFM ? "FM within deadline" : "rules"))")
        let classes = Array(Set(rows.map(\.caseClass))).sorted()
        for c in classes {
            let r = rows.filter { $0.caseClass == c }
            func count(_ key: KeyPath<Row, String>, _ v: String) -> Int { r.filter { $0[keyPath: key] == v }.count }
            print(String(format: "%-16@ n=%2d  first P/W/F %2d/%2d/%2d  final P/W/F %2d/%2d/%2d", c as NSString, r.count,
                         count(\.firstVerdict, "PASS"), count(\.firstVerdict, "WEAK"), count(\.firstVerdict, "FAIL"),
                         count(\.finalVerdict, "PASS"), count(\.finalVerdict, "WEAK"), count(\.finalVerdict, "FAIL")))
        }
        let times = rows.compactMap(\.classifyMS)
        let first = rows.map(\.firstMS), samples = rows.map(\.sampleMS)
        print(String(format: "first actions ms: median %.2f p90 %.2f max %.2f", pct(first, 0.5), pct(first, 0.9), first.max() ?? 0))
        print(String(format: "sample ms: median %.2f p90 %.2f max %.2f", pct(samples, 0.5), pct(samples, 0.9), samples.max() ?? 0))
        if !times.isEmpty {
            print(String(format: "classify ms (n=%d): median %.0f p90 %.0f max %.0f; late for line (>4 s): %d; replaced actions: %d",
                         times.count, pct(times, 0.5), pct(times, 0.9), times.max() ?? 0, rows.filter(\.lateForLine).count, rows.filter(\.replaced).count))
        }
        for row in rows where row.finalVerdict != "PASS" || row.firstVerdict == "FAIL" {
            print("\(row.finalVerdict.padding(toLength: 4, withPad: " ", startingAt: 0)) \(row.id) run \(row.run): first \(row.firstOffered) [\(row.firstVerdict) \(row.firstWhy)] → role \(row.role ?? "-") final \(row.finalOffered) \(row.finalWhy)")
        }
    }
}
