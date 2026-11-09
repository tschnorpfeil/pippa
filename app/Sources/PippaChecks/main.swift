import AppKit
import CoreText
import CryptoKit
import Foundation
import PippaCore
import SQLite3

// Line-buffer stdout, even into a pipe (CI), so output doesn't sit in the buffer.
setvbuf(stdout, nil, _IOLBF, 0)

// Minimal check runner: `check("name") { … }`; exits non-zero on failures at the end. No network.
nonisolated(unsafe) var failures = 0
func check(_ name: String, _ body: () throws -> Bool) {
    do {
        if try body() { print("✓ \(name)") } else { failures += 1; print("✗ \(name)") }
    } catch { failures += 1; print("✗ \(name): \(error)") }
}
func checkAsync(_ name: String, _ body: () async throws -> Bool) async {
    // Announce before long checks so a hang is visible in the CI output.
    if ProcessInfo.processInfo.environment["CI"] != nil { print("… \(name)") }
    do {
        if try await body() { print("✓ \(name)") } else { failures += 1; print("✗ \(name)") }
    } catch { failures += 1; print("✗ \(name): \(error)") }
}

nonisolated(unsafe) let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("pippa-checks-\(UUID().uuidString)", isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
setenv("PIPPA_LOG_DIR", root.appendingPathComponent("log").path, 1)
// Identical copies go "to the Trash" in a folder of the run, never into the real Trash.
setenv("PIPPA_CHECK_TRASH", root.appendingPathComponent("Papierkorb").path, 1)
// Checks never depend on this Mac's system model (Apple Intelligence on or off): tidying uses recordings or nothing.
setenv("PIPPA_NO_SYSTEM_MODEL", "1", 1)

// Focused runs (PIPPA_<AREA>_CHECKS=1): one area only, for parallel work on a busy machine. The full run includes them.
func focused(_ variable: String, _ label: String, _ body: () async -> Void) async {
    guard ProcessInfo.processInfo.environment[variable] == "1" else { return }
    await body()
    print(failures == 0 ? "\(label) checks passed." : "\(label) checks failed.")
    exit(failures == 0 ? 0 : 1)
}
await focused("PIPPA_PROVIDER_CHECKS", "Provider") {
    await runInferenceChecks()
    await runProviderChecks()
}
await focused("PIPPA_RELIABILITY_CHECKS", "Reliability") {
    runSkillChecks()
    await runSheetChecks()
    await runPermissionRepairChecks()
    await runDeadlineChecks()
}
await focused("PIPPA_DURABLE_JOB_CHECKS", "Durable job") { await runDurableJobChecks() }
await focused("PIPPA_FILE_PREPARATION_CHECKS", "File preparation") { await runFilePreparationChecks() }
await focused("PIPPA_MCP_FILE_PREPARATION_CHECKS", "MCP file preparation") { await runMCPFilePreparationChecks() }
await focused("PIPPA_DOWNLOAD_CHECKS", "Download") { await runDownloadChecks() }
await focused("PIPPA_MARKDOWN_CHECKS", "Markdown") { runMarkdownChecks() }
// Mail identity, readback and insertion decisions; no native app actions.
await focused("PIPPA_LETTER_CHECKS", "Letter") { await runLetterChecks() }
// Installer only (PiSetup, fake HOME under .build/fake-home-*).
await focused("PIPPA_LOCAL_SERVER_CHECKS", "Local server") { await runTerminalAutostartChecks() }
await focused("PIPPA_SETUP_CHECKS", "Installer") { await runSetupChecks() }
// Only Pippa's MCP server (stand-in readers, no real Mail/Calendar/Excel).
await focused("PIPPA_MCP_CHECKS", "MCP") {
    await runMCPChecks()
    await runNativeReminderChecks()
}

func dir(_ name: String) -> URL {
    let u = root.appendingPathComponent(name, isDirectory: true)
    try? fm.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}
/// Small thread-safe box for values from @Sendable callbacks.
final class LockedBox<T>: @unchecked Sendable {
    private var stored: T
    private let lock = NSLock()
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func mutate(_ change: (inout T) -> Void) { lock.withLock { change(&stored) } }
}
func write(_ text: String, _ url: URL) { try? text.write(to: url, atomically: true, encoding: .utf8) }

/// Text PDF with one page per entry (CoreText), for reading, search and speed checks.
func makePDF(_ pages: [String], at url: URL) {
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
    for page in pages {
        ctx.beginPDFPage(nil)
        let attr = NSAttributedString(string: page, attributes: [.font: NSFont.systemFont(ofSize: 11)])
        let setter = CTFramesetterCreateWithAttributedString(attr)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: box.insetBy(dx: 50, dy: 50), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

let invoiceText = """
Stadtwerke Musterstadt GmbH
Hauptstraße 1, 12345 Musterstadt
Rechnung
Rechnungsnummer 2026-118734
Rechnungsdatum 02.03.2026
Strom März 2026
Gesamtbetrag 84,20 €
IBAN DE89 3704 0044 0532 0130 00
"""
let contractPages = [
    "Mietvertrag\nzwischen Hausverwaltung Berger und Max Muster\nüber die Wohnung in der Lindenstraße 5\nMusterstadt, den 14.06.2021",
    "§ 8 Kündigung\nDas Mietverhältnis läuft auf unbestimmte Zeit. Es kann von beiden Seiten mit einer Frist von drei Monaten zum Monatsende gekündigt werden.",
]

// MARK: - Names

check("Name: YYYY-MM sender kind") {
    Naming.document(date: DayDate(year: 2026, month: 3, day: 2), sender: "Stadtwerke", kind: "Rechnung", ext: "PDF") == "2026-03 Stadtwerke Rechnung.pdf"
}
check("Name: contract and draft") {
    Naming.contract(kind: "Mietvertrag", subject: "Wohnung", year: 2021, ext: "pdf") == "Mietvertrag Wohnung 2021.pdf"
        && Naming.document(date: DayDate(year: 2026, month: 4, day: 1), sender: "Hausverwaltung", kind: "Brief", ext: "docx", draft: true) == "2026-04 Hausverwaltung Brief (Entwurf).docx"
}
check("Name: photo") { Naming.photo(date: DayDate(year: 2026, month: 7, day: 14)!, number: 1, ext: "JPG") == "2026-07-14 Foto 01.jpg" }
check("Name: sanitised") { Naming.sanitize("  ../Re:chnung/ März\u{0007}  ") == "Re-chnung- März" }
check("Folder") { Naming.folder(for: .invoice, year: 2026) == "Rechnungen/2026" && Naming.folder(for: .contract, year: nil) == "Verträge" }
check("Collision gets \" (2)\"") {
    let d = dir("collision")
    write("x", d.appendingPathComponent("2026-03 Stadtwerke Rechnung.pdf"))
    var taken = Set<String>()
    let a = Naming.unique("2026-03 Stadtwerke Rechnung.pdf", in: d, taken: &taken)
    let b = Naming.unique("2026-03 Stadtwerke Rechnung.pdf", in: d, taken: &taken)
    return a.lastPathComponent == "2026-03 Stadtwerke Rechnung (2).pdf" && b.lastPathComponent == "2026-03 Stadtwerke Rechnung (3).pdf"
}

check("Case: only the same file counts as a pure rename") {
    let d = dir("case-same")
    let a = d.appendingPathComponent("brief.txt"), b = d.appendingPathComponent("anders.txt")
    write("a", a); write("b", b)
    let insensitive = (try? d.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?.volumeSupportsCaseSensitiveNames == false
    return Executor.isSameFile(a.path, a.path) && !Executor.isSameFile(a.path, b.path)
        && !Executor.isSameFile(a.path, d.appendingPathComponent("fehlt.txt").path)
        && (!insensitive || Executor.isSameFile(a.path, d.appendingPathComponent("Brief.txt").path))
}

// MARK: - Model choice

let GB: UInt64 = 1 << 30
let ornithKey = "ornith-1.5-9b-mlx-4bit"

/// A catalog model from given files (path → content), each pinned with its real size and SHA-256.
func fakeCatalogModel(key: String = "fake-1b-mlx", repo: String = "fixture-org/Fake-1B-MLX", files: [String: Data]) -> CatalogModel {
    let pinned = files.keys.sorted().map { path -> [String: Any] in
        let data = files[path]!
        return ["path": path, "size": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
    }
    let json: [String: Any] = ["key": key, "label": "Fake 1B", "repo": repo, "quant": "MLX 4-bit", "memGiB": 1, "ctx": 4096,
                               "pinned": ["revision": "test", "files": pinned]]
    return try! JSONDecoder().decode(CatalogModel.self, from: JSONSerialization.data(withJSONObject: json))
}

check("Catalog: exactly one model, Ornith 1.5 9B, every file pinned by revision, size and SHA-256") {
    let catalog = ModelCatalog.bundled()
    guard catalog.models.count == 1, let model = catalog.models.first, model.key == ornithKey,
          let pinned = model.pinned, !pinned.files.isEmpty,
          pinned.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else { return false }
    let paths = pinned.files.map(\.path)
    return pinned.files.allSatisfy { $0.size > 0 && $0.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }
        && Set(paths).count == paths.count && paths.contains("model.safetensors") && paths.contains("config.json")
        && model.approxBytes == pinned.files.reduce(0) { $0 + $1.size }
        && model.thinking == "medium"
}
check("Model: 8 GB → no local AI (online AI instead); Intel → not supported") {
    let small: Bool = { if case .failure(.unsupportedHardware) = ModelSelector.choose(physicalMemory: 8 * GB, appleSilicon: true) { return true }; return false }()
    let intel: Bool = { if case .failure(.unsupportedHardware) = ModelSelector.choose(physicalMemory: 32 * GB, appleSilicon: false) { return true }; return false }()
    return small && intel && PiSetupFlow.choice(physicalMemory: 8 * GB) == nil
}
check("Model: 16 GB → Ornith with 16K context, 24 GB and more → 32K") {
    let c16 = try? ModelSelector.choose(physicalMemory: 16 * GB, appleSilicon: true).get()
    let c24 = try? ModelSelector.choose(physicalMemory: 24 * GB, appleSilicon: true).get()
    let c64 = try? ModelSelector.choose(physicalMemory: 64 * GB, appleSilicon: true).get()
    return c16?.model.key == ornithKey && c16?.ctx == 16384
        && c24?.model.key == ornithKey && c24?.ctx == 32768 && c64?.ctx == 32768
}
check("Model: an unpinned model is unavailable (never a download without a SHA-256)") {
    var catalog = ModelCatalog.bundled()
    guard !catalog.models.isEmpty else { return false }
    catalog.models[0].pinned = nil
    if case .failure(.modelUnavailable) = ModelSelector.choose(physicalMemory: 16 * GB, appleSilicon: true, catalog: catalog) { return true }
    return false
}
check("Existing models: matching name and size, wrong content is not adopted") {
    let home = dir("existing-wrong")
    let payload = Data((0..<4096).map { UInt8($0 % 13) })
    var model = fakeCatalogModel(files: ["model.safetensors": payload])
    model.pinned!.files[0].sha256 = String(repeating: "a", count: 64)
    let folder = home.appendingPathComponent(".omlx/models/Fake-1B-MLX")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try payload.write(to: folder.appendingPathComponent("model.safetensors"))
    guard let found = ExistingModels.find(model, roots: ExistingModels.defaultRoots(home: home))[model.pinned!.files[0].sha256] else { return false }
    let models = dir("existing-wrong-models")
    let d = ModelDownloader(directory: models)
    let adopted = try d.adopt(model.pinned!.files[0], from: found.url)
    let left = try fm.contentsOfDirectory(atPath: models.path)
    return !adopted && left.isEmpty && fm.fileExists(atPath: found.url.path)
}
await checkAsync("Existing models: no download without consent after a failed adoption") {
    let home = dir("existing-no-consent")
    let payload = Data((0..<4096).map { UInt8($0 % 17) })
    var model = fakeCatalogModel(files: ["model.safetensors": payload])
    model.pinned!.files[0].sha256 = String(repeating: "b", count: 64)
    let folder = home.appendingPathComponent(".lmstudio/models/fixture-org/Fake-1B-MLX")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    try payload.write(to: folder.appendingPathComponent("model.safetensors"))
    let found = ExistingModels.find(model, roots: ExistingModels.defaultRoots(home: home))
    let models = dir("existing-no-consent-models")
    let d = ModelDownloader(directory: models)
    let rejected = LockedBox<[String]>([])
    do {
        try await d.download(model, existing: found, allowNetwork: false, rejected: { sha in rejected.mutate { $0.append(sha) } }) { _, _ in }
        return false
    } catch is ModelDownloader.AdoptionFailed {}
    // Likewise with no file found and no consent: nothing from the network.
    do { try await d.download(model, allowNetwork: false) { _, _ in }; return false }
    catch is ModelDownloader.AdoptionFailed {}
    let contents = try fm.contentsOfDirectory(atPath: models.path)
    return found.count == 1 && rejected.value == [String(repeating: "b", count: 64)] && contents.isEmpty
}
check("Download URL as in installer/hf.mjs") {
    ModelDownloader.url(repo: "ornith-ai/Ornith-1.5-9B-MLX-4bit", revision: "a48173b246ac705be75c05bedf1a0666db522d53", path: "model.safetensors").absoluteString
        == "https://huggingface.co/ornith-ai/Ornith-1.5-9B-MLX-4bit/resolve/a48173b246ac705be75c05bedf1a0666db522d53/model.safetensors"
}
await checkAsync("Existing models: <root>/<name>, <root>/<org>/<name> and the Hugging Face snapshot (symlinks resolved) are found; adopted without network, source stays") {
    let home = dir("existing-home")
    let weights = Data((0..<65_536).map { UInt8($0 % 251) })
    let config = Data(#"{"model_type": "fake"}"#.utf8)
    let model = fakeCatalogModel(files: ["model.safetensors": weights, "config.json": config])
    let hash = model.pinned!.files.first { $0.path == "model.safetensors" }!.sha256
    let roots = ExistingModels.defaultRoots(home: home)
    guard ExistingModels.find(model, roots: roots).isEmpty else { return false }
    // oMLX: <root>/<repo name>; a file of the same size under another name does not count.
    let omlx = home.appendingPathComponent(".omlx/models/Fake-1B-MLX")
    try fm.createDirectory(at: omlx, withIntermediateDirectories: true)
    try Data(repeating: 7, count: weights.count).write(to: omlx.appendingPathComponent("other.safetensors"))
    try weights.write(to: omlx.appendingPathComponent("model.safetensors"))
    let byName = ExistingModels.find(model, roots: roots)
    guard byName[hash]?.source == "oMLX", byName[hash]?.url.lastPathComponent == "model.safetensors", byName.count == 1 else { return false }
    // LM Studio: <root>/<org>/<name>.
    let lms = home.appendingPathComponent(".lmstudio/models/fixture-org/Fake-1B-MLX")
    try fm.createDirectory(at: lms, withIntermediateDirectories: true)
    try weights.write(to: lms.appendingPathComponent("model.safetensors"))
    try config.write(to: lms.appendingPathComponent("config.json"))
    let byOrg = ExistingModels.find(model, roots: roots.filter { $0.source == "LM Studio" })
    guard byOrg.count == 2, byOrg[hash]?.url.path == lms.appendingPathComponent("model.safetensors").path else { return false }
    // Hugging Face: snapshots/<rev>/model.safetensors is a symlink to blobs/<sha256>; the blob itself is found.
    let hub = home.appendingPathComponent(".cache/huggingface/hub/models--fixture-org--Fake-1B-MLX")
    try fm.createDirectory(at: hub.appendingPathComponent("blobs"), withIntermediateDirectories: true)
    try fm.createDirectory(at: hub.appendingPathComponent("snapshots/abc123"), withIntermediateDirectories: true)
    try weights.write(to: hub.appendingPathComponent("blobs/\(hash)"))
    try fm.createSymbolicLink(atPath: hub.appendingPathComponent("snapshots/abc123/model.safetensors").path, withDestinationPath: "../../blobs/\(hash)")
    let cached = ExistingModels.find(model, roots: roots.filter { $0.source == "Hugging Face" })[hash]
    guard cached?.url.resolvingSymlinksInPath().path == hub.appendingPathComponent("blobs/\(hash)").resolvingSymlinksInPath().path,
          cached?.url.lastPathComponent == hash else { return false }
    // Adopt instead of download: nothing is missing, no network needed, the source stays.
    let found = ExistingModels.find(model, roots: roots.filter { $0.source == "LM Studio" })
    let d = ModelDownloader(directory: dir("existing-models"))
    let size = Int64(weights.count + config.count)
    guard d.downloadSize(model, existing: found) == ModelDownloadSize(total: size, remaining: 0, existing: size, existingSource: "LM Studio"),
          !d.isInstalled(model) else { return false }
    try await d.download(model, existing: found, allowNetwork: false) { _, _ in }
    let sourceData = try Data(contentsOf: lms.appendingPathComponent("model.safetensors"))
    return d.isInstalled(model) && sourceData == weights && d.downloadSize(model)?.remaining == 0
}

// MARK: - Reading

check("Mail (.eml): header, text, attachments") {
    let eml = """
    From: "Hausverwaltung Berger" <info@berger.example>
    To: max@example.com
    Subject: =?utf-8?Q?Nebenkostenabrechnung_2025_f=C3=BCr_Sie?=
    Date: Mon, 6 Apr 2026 09:12:00 +0200
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="XYZ"

    --XYZ
    Content-Type: text/plain; charset=utf-8
    Content-Transfer-Encoding: quoted-printable

    Hallo, anbei die Abrechnung. Nachzahlung 312,48 =E2=82=AC.
    --XYZ
    Content-Type: application/pdf; name="Abrechnung.pdf"
    Content-Disposition: attachment; filename="Abrechnung.pdf"
    Content-Transfer-Encoding: base64

    JVBERi0=
    --XYZ--
    """
    let url = root.appendingPathComponent("mail.eml"); write(eml, url)
    let doc = TextReader.read(url)
    return doc.headers["subject"] == "Nebenkostenabrechnung 2025 für Sie" && doc.attachments == ["Abrechnung.pdf"]
        && doc.fullText.contains("312,48 €")
}
check("Mail (.eml) in Latin-1: 8bit and quoted-printable without \"KÃ¼ndigung\"") {
    let eightBit = """
    From: Stadtwerke <info@stadtwerke.example>
    Subject: =?iso-8859-1?Q?K=FCndigungsbest=E4tigung?=
    MIME-Version: 1.0
    Content-Type: text/plain; charset=iso-8859-1
    Content-Transfer-Encoding: 8bit

    Kündigung bis 31.12.2026 möglich. Gebühr 5 €.
    """
    // Latin-1 has no €: as in real mails, the data set holds the Windows-1252 byte 0x80.
    var bytes = eightBit.replacingOccurrences(of: "€", with: "").data(using: .isoLatin1)!
    bytes.insert(0x80, at: bytes.lastIndex(of: UInt8(ascii: "."))!)
    let url = root.appendingPathComponent("latin1.eml")
    try bytes.write(to: url)
    let doc = TextReader.read(url)
    let qp = MailParser.parse(Data("""
    Content-Type: multipart/alternative; boundary="b"

    --b
    Content-Type: text/plain; charset="ISO-8859-1"
    Content-Transfer-Encoding: quoted-printable

    K=FCndigung bis 31.12.2026, Gr=FC=DFe
    --b--
    """.utf8))
    return doc.fullText.contains("Kündigung bis 31.12.2026 möglich. Gebühr 5 €.") && !doc.fullText.contains("Ã")
        && doc.headers["subject"] == "Kündigungsbestätigung"
        && qp.body == "Kündigung bis 31.12.2026, Grüße"
}
check("PDF: text per page with page number") {
    let url = root.appendingPathComponent("vertrag.pdf")
    makePDF(contractPages, at: url)
    let doc = TextReader.read(url)
    return doc.pages.count == 2 && doc.pages[1].contains("drei Monaten") && doc.isPaged
}
check("PDF: lines in reading order (PDFKit put the last paragraph line first)") {
    // Same typesetting as in the test corpus (Helvetica 10.5 pt, 60 pt margin); `page.string` returned here
    // "Vermieterin nötig." before "Kleintiere sind erlaubt. …", so the verbatim quote was no longer in the text.
    let url = root.appendingPathComponent("order.pdf")
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    let page = "§ 4 Kaution\nDie Mieterin leistet eine Mietsicherheit in Höhe von drei Monatsmieten, also 2.460,00 €. Die Kaution kann in drei gleichen monatlichen Teilzahlungen erbracht werden.\n\n§ 5 Schönheitsreparaturen\nDie Mieterin übernimmt keine Schönheitsreparaturen. Kleine Instandhaltungen bis 100,00 € je Einzelfall trägt die Mieterin, höchstens jedoch 8 % der Jahresgrundmiete.\n\n§ 6 Tierhaltung\nKleintiere sind erlaubt. Für Hunde und Katzen ist die vorherige schriftliche Zustimmung der Vermieterin nötig."
    let attr = NSAttributedString(string: page, attributes: [.font: NSFont(name: "Helvetica", size: 10.5)!])
    CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attr), CFRange(location: 0, length: 0),
                                         CGPath(rect: box.insetBy(dx: 60, dy: 60), transform: nil), nil), ctx)
    ctx.endPDFPage(); ctx.closePDF()
    let text = TextReader.read(url).fullText
    let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return flat.contains("Für Hunde und Katzen ist die vorherige schriftliche Zustimmung der Vermieterin nötig.")
        && flat.range(of: "Kleintiere sind erlaubt.")!.lowerBound < flat.range(of: "Vermieterin nötig.")!.lowerBound
        && text.hasPrefix("§ 4 Kaution")
}
check("OCR: columns (label left, amount right) become lines again") {
    // This is how Vision returns a receipt: all labels first, then all amounts (origin bottom left).
    let pieces: [(rect: CGRect, text: String)] = [
        (CGRect(x: 0.1, y: 0.50, width: 0.3, height: 0.02), "SUMME EUR"),
        (CGRect(x: 0.1, y: 0.47, width: 0.2, height: 0.02), "Bar"),
        (CGRect(x: 0.1, y: 0.60, width: 0.4, height: 0.02), "Ibuprofen 400 akut"),
        (CGRect(x: 0.7, y: 0.601, width: 0.1, height: 0.02), "5,95"),
        (CGRect(x: 0.7, y: 0.499, width: 0.1, height: 0.02), "23,45"),
        (CGRect(x: 0.7, y: 0.471, width: 0.1, height: 0.02), "30,00"),
    ]
    let lines = TextReader.lineRows(pieces)
    return lines == ["Ibuprofen 400 akut 5,95", "SUMME EUR 23,45", "Bar 30,00"]
}

// MARK: - Mail and scripts (read only, no real apps)

check("Mail from Apple Mail becomes .eml, which the normal reader understands") {
    let m = MailMessage(subject: "Nebenkosten 2025 – Nachzahlung", sender: "Hausverwaltung Berger <info@berger-hv.de>",
                        date: Date(timeIntervalSince1970: 1_790_000_000), body: "Zahlbar bis 31.10.2026.\nGrüße", attachmentNames: ["Abrechnung.pdf", "Plan \"neu\".pdf"])
    let parsed = MailParser.parse(Data(m.emlText.utf8))
    return parsed.headers["subject"] == "Nebenkosten 2025 – Nachzahlung" && parsed.body == "Zahlbar bis 31.10.2026.\nGrüße"
        && parsed.attachments == ["Abrechnung.pdf", "Plan 'neu'.pdf"] && m.fileName == "Nebenkosten 2025 – Nachzahlung.eml"
}

await checkAsync("Script for reading mail compiles (nothing is sent)") {
    let result = await MainActor.run { IntegrationScripts.compileAll() }
    // Excel is missing from the result when Excel isn't installed (CI); its script is then not compiled.
    return result["Mail"] == true && result["MailReply"] == true && result["MailSearch"] == true && (result["Excel"] ?? true)
        && result["PhotosSearch"] == true && result["PhotosShow"] == true
        && result["Safari"] == true && result["FrontDocument"] == true && (result["Chrome"] ?? true)
        && Set(result.keys).isSubset(of: ["Mail", "MailReply", "MailSearch", "Excel", "PhotosSearch", "PhotosShow", "Safari", "Chrome", "FrontDocument"])
}

// MARK: - Found in real runs

check("Download: file size freshly read (resume otherwise looped forever at the same spot)") {
    let f = root.appendingPathComponent("grow.part")
    try Data(count: 100).write(to: f)
    _ = try f.resourceValues(forKeys: [.fileSizeKey])          // fills the URL cache
    let h = try FileHandle(forWritingTo: f); try h.seekToEnd(); try h.write(contentsOf: Data(count: 50)); try h.close()
    return ModelDownloader.fileSize(f) == 150 && ModelDownloader.fileSize(root.appendingPathComponent("fehlt")) == -1
}

// MARK: - Messages

check("System errors in our own words, never the system's wording") {
    let noAccess = L("I don’t have access to that.", table: "Core"), noSpace = L("There’s no space left.", table: "Core")
    return SystemError.reason(errno: EACCES) == noAccess && SystemError.reason(errno: EPERM) == noAccess
        && SystemError.reason(errno: ENOENT) == L("The file is no longer there.", table: "Core")
        && SystemError.reason(errno: EEXIST) == L("There’s already a file with that name.", table: "Core")
        && SystemError.reason(errno: EXDEV) == L("It’s on a different drive.", table: "Core") && SystemError.reason(errno: ENOSPC) == noSpace
        && SystemError.reason(errno: EIO) == L("That didn’t work just now.", table: "Core")
        && SystemError.reason(CocoaError(.fileWriteNoPermission)) == noAccess
        && SystemError.reason(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                      userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])) == noSpace
}

runDateEvidenceChecks()
runMailSingularChecks()
runAmountHintChecks()
runErrorMessageChecks()
runMarkdownChecks()
runLocalizationChecks()
runSkillChecks()
await runInferenceChecks()
await runToolChecks()
await runOCRChecks()
await runDeadlineChecks()
await runJournalChecks()
await runDurableJobChecks()
await runFilePreparationChecks()
await runMCPFilePreparationChecks()
await runLetterChecks()
await runSheetChecks()
await runProviderChecks()
await runCalendarChecks()
runCalendarStoreChecks()
await runResultCardChecks()
runPressureChecks()
await runSetupChecks()
await runMCPChecks()
await runNativeReminderChecks()
await runPermissionRepairChecks()
await runDownloadHangChecks()

print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
