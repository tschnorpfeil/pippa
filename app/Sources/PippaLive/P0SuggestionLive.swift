import Foundation
import AppKit
import PippaCore

/// Small synthetic regression corpus, never a production acceptance estimate.
@MainActor
enum P0SuggestionLive {
    struct Corpus: Decodable { let schemaVersion: Int; let scope: String; let cases: [Case] }
    struct Case: Decodable {
        let id: String; let files: [File]; let acceptedRoles: [String]
        let eligible: [String]; let forbidden: [String]; let note: String; let expectsSample: Bool
    }
    struct File: Decodable { let name: String; let text: String; let kind: String }
    struct Row: Encodable {
        let id: String; let mode: String; let role: String; let acceptedRole: Bool
        let actions: [String]; let missingEligible: [String]; let forbiddenOffered: [String]
        let abstained: Bool; let samplePresent: Bool; let expectedSample: Bool
        let extractionMS: Double; let classificationIncludingExtractionMS: Double?
        let totalMS: Double; let note: String
    }
    static func ms(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
    static func run(useAppleFM: Bool = false) async throws {
        let env = ProcessInfo.processInfo.environment
        let corpusURL = URL(fileURLWithPath: env["PIPPA_SUGGESTION_CORPUS"] ?? "app/Fixtures/p0-suggestions.json")
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: corpusURL))
        guard corpus.schemaVersion == 1 else { throw NSError(domain: "P0Suggestions", code: 1) }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(".build/quality/p0-suggestions/" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Stable capability fixture; exercises the production eligibility logic without installation-dependent skill discovery.
        let skills = ["brief-verstehen", "antwort-schreiben", "zusammenfassen", "tabelle-pruefen"].compactMap { name in
            PippaSkill.parse("---\nname: \(name)\ndescription: Lokale Korpusfähigkeit\npippa-label: \(name)\npippa-suggest: text\n---\nAnleitung.\n", folder: name, german: false)
        }
        guard skills.count == 4 else { throw NSError(domain: "P0Suggestions", code: 2) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        print("# \(corpus.scope)")
        print("# extractionMS = independent bounded sample probe; classificationIncludingExtractionMS includes classify's own sample read. totalMS = classify + candidates (probe excluded). Rules totalMS = candidates only. No confidence estimate. unknown may also mean unavailable Apple FM.")
        let clock = ContinuousClock()
        for item in corpus.cases {
            let folder = root.appendingPathComponent(item.id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let urls = try item.files.map { file -> URL in
                if file.kind == "link" { return URL(string: file.name)! }
                let url = folder.appendingPathComponent(file.name)
                if file.kind == "pdf" {
                    // NSTextView writes vector text into the PDF extraction layer.
                    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
                    view.string = file.text; view.font = NSFont.systemFont(ofSize: 14)
                    try view.dataWithPDF(inside: view.bounds).write(to: url)
                } else if file.kind == "image" {
                    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
                } else if file.kind == "binary" { try Data([0xff, 0xfe, 0x00]).write(to: url) }
                else { try file.text.write(to: url, atomically: true, encoding: .utf8) }
                return url
            }
            let extractionStart = clock.now
            let sample = urls.count == 1 ? DocumentSuggestions.sample(for: urls[0]) : nil
            let extractionMS = ms(clock.now - extractionStart)
            for mode in useAppleFM ? ["rules", "apple-fm-hybrid"] : ["rules"] {
                let start = clock.now
                let role = mode == "rules" ? DocumentRole.unknown : await DocumentSuggestions.classify(urls)
                let classificationMS = mode == "rules" ? nil : ms(clock.now - start)
                let actions = ThingActions.candidates(for: urls, skills: skills, role: role).map(\.id)
                let row = Row(id: item.id, mode: mode, role: role.rawValue,
                              acceptedRole: item.acceptedRoles.contains(role.rawValue), actions: actions,
                              missingEligible: item.eligible.filter { !actions.contains($0) },
                              forbiddenOffered: item.forbidden.filter { actions.contains($0) }, abstained: role == .unknown,
                              samplePresent: sample != nil, expectedSample: item.expectsSample,
                              extractionMS: extractionMS, classificationIncludingExtractionMS: classificationMS,
                              totalMS: ms(clock.now - start), note: item.note)
                print(String(decoding: try encoder.encode(row), as: UTF8.self))
            }
        }
    }
}
