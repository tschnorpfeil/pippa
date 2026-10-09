import AppKit
import CoreText
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

if ProcessInfo.processInfo.environment["PIPPA_DOWNLOAD_CHECKS"] == "1" {
    await runDownloadChecks()
    print(failures == 0 ? "Download checks passed." : "Download checks failed.")
    exit(failures == 0 ? 0 : 1)
}

// Installer only (PiSetup, fake HOME under .build/fake-home-*); the full run includes it.
if ProcessInfo.processInfo.environment["PIPPA_SETUP_CHECKS"] == "1" {
    await runSetupChecks()
    print(failures == 0 ? "Installer checks passed." : "Installer checks failed.")
    exit(failures == 0 ? 0 : 1)
}

// Only Pippa's MCP server (stand-in readers, no real Mail/Calendar/Excel); the full run includes it.
if ProcessInfo.processInfo.environment["PIPPA_MCP_CHECKS"] == "1" {
    await runMCPChecks()
    await runR2Checks()
    await runR3Checks()
    print(failures == 0 ? "MCP checks passed." : "MCP checks failed.")
    exit(failures == 0 ? 0 : 1)
}

// Only the R10 checks (own online service as Pi provider); the full run includes them.
if ProcessInfo.processInfo.environment["PIPPA_R7_CHECKS"] == "1" {
    await runR7Checks()
    print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
    exit(failures == 0 ? 0 : 1)
}
if ProcessInfo.processInfo.environment["PIPPA_R7B_CHECKS"] == "1" {
    await runR6Checks()
    await runR7bChecks()
    print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
    exit(failures == 0 ? 0 : 1)
}
if ProcessInfo.processInfo.environment["PIPPA_W4A_CHECKS"] == "1" {
    await runW4aChecks()
    print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
    exit(failures == 0 ? 0 : 1)
}
if ProcessInfo.processInfo.environment["PIPPA_R6_CHECKS"] == "1" {
    await runR6Checks()
    print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
    exit(failures == 0 ? 0 : 1)
}
if ProcessInfo.processInfo.environment["PIPPA_R10_CHECKS"] == "1" {
    await runR10Checks()
    print(failures == 0 ? "R10 checks passed." : "R10 checks failed.")
    exit(failures == 0 ? 0 : 1)
}

// Only the migration from the old sandbox container (fake HOME); the full run includes it.
if ProcessInfo.processInfo.environment["PIPPA_LEGACY_CHECKS"] == "1" {
    runLegacyMigrationChecks()
    print(failures == 0 ? "Migration checks passed." : "Migration checks failed.")
    exit(failures == 0 ? 0 : 1)
}

// Only the Thought Line checks (fast, for parallel work on a busy machine); the full run includes them.
if ProcessInfo.processInfo.environment["PIPPA_THOUGHT_CHECKS"] == "1" {
    await runThoughtLineChecks()
    runWorkStepChecks()
    runColdStartChecks()
    print(failures == 0 ? "Thought Line checks passed." : "Thought Line checks failed.")
    exit(failures == 0 ? 0 : 1)
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

// MARK: - German patterns

check("Date: DD.MM.YYYY") { GermanText.parseDate("Rechnungsdatum 02.03.2026") == DayDate(year: 2026, month: 3, day: 2) }
check("Date: \"12. März 2026\"") { GermanText.parseDate("am 12. März 2026 erhalten") == DayDate(year: 2026, month: 3, day: 12) }
check("Date: ISO and two-digit years") {
    GermanText.parseDate("2026-08-14") == DayDate(year: 2026, month: 8, day: 14) && GermanText.parseDate("1.4.26") == DayDate(year: 2026, month: 4, day: 1)
}
check("Date: 31.02. is discarded") { GermanText.parseDate("31.02.2026") == nil }
check("Date: DD.MM.YYYY output") { DayDate(year: 2026, month: 3, day: 2)!.german == "02.03.2026" && DayDate(year: 2026, month: 3, day: 2)!.yearMonth == "2026-03" }
check("Amount: 1.234,56 €") { GermanText.parseAmount("1.234,56 €") == Decimal(string: "1234.56") }
check("Amount: EUR 84,20 and 84,20") { GermanText.parseAmount("EUR 84,20") == Decimal(string: "84.2") && GermanText.parseAmount("84,20") == Decimal(string: "84.2") }
check("Amount: nonsense yields nil") { GermanText.parseAmount("drei Euro") == nil && GermanText.parseAmount("12,3,4") == nil }
check("Amount found in text") { GermanText.amounts(in: "Gesamtbetrag 1.234,56 € inkl. 19 % MwSt").map(\.value) == [Decimal(string: "1234.56")!] }
check("Amount formatted") { GermanText.formatAmount(Decimal(string: "1234.5")!) == "1.234,50 €" }
check("IBAN recognised") { GermanText.ibans(in: invoiceText).first == "DE89 3704 0044 0532 0130 00" }
check("Keywords: invoice / contract") {
    Keywords.category(text: invoiceText, fileName: "Scan.pdf") == .invoice
        && Keywords.category(text: contractPages.joined(separator: "\n"), fileName: "Dokument (3).pdf") == .contract
}
check("Sender from the letterhead") { Heuristics.sender(text: invoiceText) == "Stadtwerke Musterstadt" }
check("Invoice amount without a model, with evidence") {
    let r = Heuristics.invoiceAmount(text: invoiceText)
    return r?.amount == Decimal(string: "84.2") && r?.sure == true && r?.evidence == "Gesamtbetrag 84,20 €"
}

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

// MARK: - Path guard

check("Path guard: symlink escape rejected") {
    let scope = dir("guard/scope"), outside = dir("guard/outside")
    write("geheim", outside.appendingPathComponent("geheim.txt"))
    try fm.createSymbolicLink(at: scope.appendingPathComponent("ausgang"), withDestinationURL: outside)
    let g = PathGuard(scope: scope)
    return !g.contains(scope.appendingPathComponent("ausgang/geheim.txt"))
        && !g.contains(scope.appendingPathComponent("ausgang/neu/datei.txt"))
        && !g.contains(scope.appendingPathComponent("../outside/geheim.txt"))
        && g.contains(scope.appendingPathComponent("Rechnungen/2026/a.pdf"))
        && !g.contains(scope)
}

// MARK: - Apply and undo

let journalBase = dir("support")
let executor = try Executor(baseDirectory: journalBase)

await checkAsync("Apply and undo: originals back, empty folders gone") {
    let scope = dir("apply")
    let a = scope.appendingPathComponent("Scan_20260312.pdf"), b = scope.appendingPathComponent("IMG_4821.jpg")
    write("a", a); write("b", b)
    let rech = scope.appendingPathComponent("Rechnungen/2026", isDirectory: true)
    let plan = Plan(scope: scope, ops: [
        PlanOp(kind: .mkdir, source: nil, target: scope.appendingPathComponent("Rechnungen", isDirectory: true), reason: "", certainty: .sure),
        PlanOp(kind: .mkdir, source: nil, target: rech, reason: "", certainty: .sure),
        PlanOp(kind: .move, source: a, target: rech.appendingPathComponent("2026-03 Stadtwerke Rechnung.pdf"), reason: "", certainty: .sure, fingerprint: FileFingerprint.of(a)),
        PlanOp(kind: .move, source: b, target: scope.appendingPathComponent("Fotos/2026/2026-07-14 Foto 01.jpg"), reason: "", certainty: .sure, fingerprint: FileFingerprint.of(b)),
    ], skipped: [])
    let report = try await executor.apply(plan)
    let moved = fm.fileExists(atPath: rech.appendingPathComponent("2026-03 Stadtwerke Rechnung.pdf").path)
        && fm.fileExists(atPath: scope.appendingPathComponent("Fotos/2026/2026-07-14 Foto 01.jpg").path)
        && !fm.fileExists(atPath: a.path) && !fm.fileExists(atPath: b.path)
    guard moved, report.receipt.summary == L("%lld files tidied", table: "Core", 2), report.createdFolders.count == 4 else { return false }
    let undo = try await executor.undo(jobID: report.receipt.id)
    let restored = (try? String(contentsOf: a, encoding: .utf8)) == "a" && (try? String(contentsOf: b, encoding: .utf8)) == "b"
    let leftovers = try fm.contentsOfDirectory(atPath: scope.path).sorted()
    return restored && undo.conflicts.isEmpty && leftovers == ["IMG_4821.jpg", "Scan_20260312.pdf"]
}

check("Deselection in the organise preview: only the selected items, new folders only with selected content") {
    let scope = URL(fileURLWithPath: "/tmp/abwahl", isDirectory: true)
    let rech = PlanOp(kind: .mkdir, source: nil, target: scope.appendingPathComponent("Rechnungen", isDirectory: true), reason: "", certainty: .sure)
    let year = PlanOp(kind: .mkdir, source: nil, target: scope.appendingPathComponent("Rechnungen/2026", isDirectory: true), reason: "", certainty: .sure)
    let short = PlanOp(kind: .mkdir, source: nil, target: scope.appendingPathComponent("Rech", isDirectory: true), reason: "", certainty: .sure)
    let a = PlanOp(kind: .move, source: scope.appendingPathComponent("a.pdf"), target: scope.appendingPathComponent("Rechnungen/2026/a.pdf"), reason: "", certainty: .sure)
    let b = PlanOp(kind: .move, source: scope.appendingPathComponent("b.pdf"), target: scope.appendingPathComponent("Rech/b.pdf"), reason: "", certainty: .sure)
    let ops = [rech, year, short, a, b]
    // "Rech" is not a parent folder of "Rechnungen/…"; when deselected it stays out.
    return Executor.selected(ops, excluding: [b.id]).map(\.id) == [rech.id, year.id, a.id]
        && Executor.selected(ops, excluding: []).map(\.id) == ops.map(\.id)
        && Executor.selected(ops, excluding: [a.id, b.id]).isEmpty
}

await checkAsync("Organise with deselection: journal, receipt and undo only for what ran") {
    let scope = dir("apply-selected"), support = dir("apply-selected-support")
    let a = scope.appendingPathComponent("a.pdf"), b = scope.appendingPathComponent("b.jpg"), c = scope.appendingPathComponent("c.pdf")
    write("a", a); write("b", b); write("c", c)
    let rech = scope.appendingPathComponent("Rechnungen", isDirectory: true), fotos = scope.appendingPathComponent("Fotos", isDirectory: true)
    let moveA = PlanOp(kind: .move, source: a, target: rech.appendingPathComponent("a.pdf"), reason: "", certainty: .sure, fingerprint: FileFingerprint.of(a))
    let moveB = PlanOp(kind: .move, source: b, target: fotos.appendingPathComponent("b.jpg"), reason: "", certainty: .sure, fingerprint: FileFingerprint.of(b))
    let moveC = PlanOp(kind: .move, source: c, target: rech.appendingPathComponent("c.pdf"), reason: "", certainty: .sure, fingerprint: FileFingerprint.of(c))
    let plan = Plan(scope: scope, ops: [
        PlanOp(kind: .mkdir, source: nil, target: rech, reason: "", certainty: .sure),
        PlanOp(kind: .mkdir, source: nil, target: fotos, reason: "", certainty: .sure),
        moveA, moveB, moveC,
    ], skipped: [])
    let ex = try Executor(baseDirectory: support)
    let report = try await ex.apply(plan, excluding: [moveB.id, moveC.id])
    // Deselected: stays where it is, and no empty folder is created for "Fotos" (deselected content only).
    guard report.receipt.summary == L("1 file tidied", table: "Core"), report.done.contains(moveA.id),
          !report.done.contains(moveB.id), !report.done.contains(moveC.id), report.skipped.isEmpty,
          fm.fileExists(atPath: rech.appendingPathComponent("a.pdf").path), fm.fileExists(atPath: b.path), fm.fileExists(atPath: c.path),
          !fm.fileExists(atPath: fotos.path) else { return false }
    var db: OpaquePointer?
    guard sqlite3_open(support.appendingPathComponent("journal.sqlite").path, &db) == SQLITE_OK else { return false }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT COALESCE(source, '') || ' ' || target FROM ops WHERE job=?", -1, &statement, nil) == SQLITE_OK else { return false }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, report.receipt.id.uuidString, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    var journal: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW { journal.append(String(cString: sqlite3_column_text(statement, 0))) }
    guard !journal.isEmpty, journal.allSatisfy({ !$0.contains("b.jpg") && !$0.contains("c.pdf") && !$0.contains("Fotos") }) else { return false }
    let undo = try await ex.undo(jobID: report.receipt.id)
    let left = try fm.contentsOfDirectory(atPath: scope.path).sorted()
    // Exactly that one file and its new folder come back.
    return undo.restored == 2 && undo.conflicts.isEmpty && left == ["a.pdf", "b.jpg", "c.pdf"]
}

await checkAsync("Undo leaves foreign files and their folders alone") {
    let scope = dir("apply2")
    let a = scope.appendingPathComponent("a.txt"); write("a", a)
    let plan = Plan(scope: scope, ops: [PlanOp(kind: .move, source: a, target: scope.appendingPathComponent("Sonstiges/a.txt"), reason: "", certainty: .sure)], skipped: [])
    let report = try await executor.apply(plan)
    write("fremd", scope.appendingPathComponent("Sonstiges/fremd.txt"))
    try await executor.undo(jobID: report.receipt.id)
    return fm.fileExists(atPath: a.path) && fm.fileExists(atPath: scope.appendingPathComponent("Sonstiges/fremd.txt").path)
}

await checkAsync("Undo protects same-size changes and keeps partial jobs in history") {
    let scope = dir("undo-modified"), support = dir("undo-modified-support")
    let a = scope.appendingPathComponent("a.txt"), b = scope.appendingPathComponent("b.txt")
    let target = scope.appendingPathComponent("moved.txt")
    write("before", a); write("second", b)
    let ex = try Executor(baseDirectory: support)
    let report = try await ex.apply(Plan(scope: scope, ops: [
        PlanOp(kind: .move, source: a, target: target, reason: "", certainty: .sure),
        PlanOp(kind: .move, source: b, target: scope.appendingPathComponent("second.txt"), reason: "", certainty: .sure),
    ], skipped: []))
    let before = FileFingerprint.of(target)!
    let handle = try FileHandle(forWritingTo: target)
    try handle.write(contentsOf: Data("edited".utf8)); try handle.close()
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: before.mtime + 10)], ofItemAtPath: target.path)
    guard FileFingerprint.of(target)?.inode == before.inode else { return false }
    let undo = try await ex.undo(jobID: report.receipt.id)
    let reopened = try Executor(baseDirectory: support)
    let history = await reopened.recentJobs()
    guard undo.restored == 1, undo.conflicts.count == 1, history.map(\.id) == [report.receipt.id],
          !fm.fileExists(atPath: a.path), fm.fileExists(atPath: b.path),
          try String(contentsOf: target, encoding: .utf8) == "edited" else { return false }
    // Once the conflict is resolved, the retained receipt can finish its remaining operation.
    try Data("before".utf8).write(to: target)
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: before.mtime)], ofItemAtPath: target.path)
    let retried = try await reopened.undo(jobID: report.receipt.id)
    let after = await reopened.recentJobs()
    return retried.restored == 1 && retried.conflicts.isEmpty && after.isEmpty
}
await checkAsync("Undo doesn't discard an edited export of the same size") {
    let scope = dir("undo-export-modified")
    let ex = try Executor(baseDirectory: dir("undo-export-support"))
    let r = try await ex.createFile(Data("before".utf8), named: "export.txt", in: scope, summary: { _ in "Export" }, detail: "")
    let target = r.revealURL!, before = FileFingerprint.of(r.revealURL!)!
    let handle = try FileHandle(forWritingTo: target)
    try handle.write(contentsOf: Data("edited".utf8)); try handle.close()
    try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: before.mtime + 10)], ofItemAtPath: target.path)
    let undo = try await ex.undo(jobID: r.id)
    let remaining = try String(contentsOf: target, encoding: .utf8)
    return undo.restored == 0 && undo.conflicts.count == 1 && remaining == "edited"
}
await checkAsync("Foreign change since the preview: operation is skipped") {
    let scope = dir("foreign")
    let a = scope.appendingPathComponent("a.txt"), b = scope.appendingPathComponent("b.txt")
    write("a", a); write("b", b)
    let plan = Plan(scope: scope, ops: [
        PlanOp(kind: .rename, source: a, target: scope.appendingPathComponent("A neu.txt"), reason: "", certainty: .sure, fingerprint: FileFingerprint.of(a)),
        PlanOp(kind: .rename, source: b, target: scope.appendingPathComponent("B neu.txt"), reason: "", certainty: .sure, fingerprint: FileFingerprint.of(b)),
    ], skipped: [])
    write("a geändert, länger", a)
    let report = try await executor.apply(plan)
    return fm.fileExists(atPath: a.path) && fm.fileExists(atPath: scope.appendingPathComponent("B neu.txt").path)
        && report.skipped.count == 1 && report.skipped[0].why == L("It changed since the preview, so it stays where it is.", table: "Core")
}

await checkAsync("Target outside and symlink target are not executed") {
    let scope = dir("escape/scope"), outside = dir("escape/outside")
    try fm.createSymbolicLink(at: scope.appendingPathComponent("raus"), withDestinationURL: outside)
    let a = scope.appendingPathComponent("a.txt"); write("a", a)
    let plan = Plan(scope: scope, ops: [PlanOp(kind: .move, source: a, target: scope.appendingPathComponent("raus/a.txt"), reason: "", certainty: .sure)], skipped: [])
    let report = try await executor.apply(plan)
    let outsideEmpty = try fm.contentsOfDirectory(atPath: outside.path).isEmpty
    return fm.fileExists(atPath: a.path) && outsideEmpty && report.skipped.count == 1
}

await checkAsync("Collision on apply: \" (2)\" instead of overwriting") {
    let scope = dir("exec-collision")
    let a = scope.appendingPathComponent("a.txt"); write("neu", a)
    write("alt", scope.appendingPathComponent("Ziel.txt"))
    let report = try await executor.apply(Plan(scope: scope, ops: [PlanOp(kind: .rename, source: a, target: scope.appendingPathComponent("Ziel.txt"), reason: "", certainty: .sure)], skipped: []))
    let old = try String(contentsOf: scope.appendingPathComponent("Ziel.txt"), encoding: .utf8)
    let new = try String(contentsOf: scope.appendingPathComponent("Ziel (2).txt"), encoding: .utf8)
    return old == "alt" && new == "neu" && report.done.count == 1
}

await checkAsync("Crash: started, not finished → pendingRecovery, then resume") {
    let scope = dir("crash")
    let a = scope.appendingPathComponent("a.txt"); write("a", a)
    let job = try await executor.simulateCrash(scope: scope, source: a, target: scope.appendingPathComponent("Sonstiges/a.txt"))
    let pending = await executor.pendingRecovery()
    guard pending.contains(where: { $0.id == job }) else { return false }
    // New executor on the same journal (as after a restart)
    let restarted = try Executor(baseDirectory: journalBase)
    guard await restarted.pendingRecovery().contains(where: { $0.id == job }) else { return false }
    _ = try await restarted.resume(jobID: job)
    let after = await restarted.pendingRecovery()
    return !after.contains(where: { $0.id == job }) && fm.fileExists(atPath: scope.appendingPathComponent("Sonstiges/a.txt").path)
}

await checkAsync("Journal records the folder release; a folder with foreign content stays open instead of \"undone\"") {
    let scope = dir("bookmark-scope"), support = dir("bookmark-support")
    let a = scope.appendingPathComponent("a.txt"); write("a", a)
    let ex = try Executor(baseDirectory: support)
    let report = try await ex.apply(Plan(scope: scope, ops: [
        PlanOp(kind: .mkdir, source: nil, target: scope.appendingPathComponent("Ablage", isDirectory: true), reason: "", certainty: .sure),
        PlanOp(kind: .move, source: a, target: scope.appendingPathComponent("Ablage/a.txt"), reason: "", certainty: .sure),
    ], skipped: []))
    guard await ex.hasBookmark(jobID: report.receipt.id) else { return false }
    write("fremd", scope.appendingPathComponent("Ablage/fremd.txt"))
    let restarted = try Executor(baseDirectory: support)
    let undo = try await restarted.undo(jobID: report.receipt.id)
    let states = try await restarted.opStates(jobID: report.receipt.id)
    let state = await restarted.jobState(jobID: report.receipt.id)
    return fm.fileExists(atPath: a.path) && undo.restored == 1 && undo.conflicts.count == 1
        && undo.conflicts[0].url.lastPathComponent == "Ablage" && states.first == "done" && state == "partly-undone"
}
await checkAsync("Old journal without release column: gets migrated, undo keeps working") {
    let scope = dir("legacy-scope"), support = dir("legacy-support")
    let source = scope.appendingPathComponent("alt.txt"), target = scope.appendingPathComponent("neu.txt")
    write("x", target)
    var db: OpaquePointer?
    guard sqlite3_open(support.appendingPathComponent("journal.sqlite").path, &db) == SQLITE_OK else { return false }
    let job = UUID().uuidString
    let fp = String(decoding: try JSONEncoder().encode(FileFingerprint.of(target)!), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
    let sql = """
        CREATE TABLE jobs(id TEXT PRIMARY KEY, kind TEXT, scope TEXT, summary TEXT, detail TEXT, reveal TEXT, state TEXT, plan TEXT, created REAL);
        CREATE TABLE ops(job TEXT, seq INTEGER, op_id TEXT, kind TEXT, source TEXT, target TEXT, state TEXT, fp TEXT, note TEXT, PRIMARY KEY(job, seq));
        INSERT INTO jobs VALUES('\(job)','sort','\(scope.path)','1 Datei geordnet','','\(scope.path)','done',NULL,1);
        INSERT INTO ops VALUES('\(job)',1,NULL,'rename','\(source.path)','\(target.path)','done','\(fp)',NULL);
        """
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { sqlite3_close(db); return false }
    sqlite3_close(db)
    let ex = try Executor(baseDirectory: support)
    let undo = try await ex.undo(jobID: UUID(uuidString: job)!)
    _ = try Executor(baseDirectory: support)   // second open: the migration happens only once
    let bookmarked = await ex.hasBookmark(jobID: UUID(uuidString: job)!)
    return undo.restored == 1 && fm.fileExists(atPath: source.path) && !fm.fileExists(atPath: target.path) && !bookmarked
}
await checkAsync("After restart: interrupted table removes its temp file, entries in apps are completed") {
    let folder = dir("export-crash"), support = dir("export-crash-support")
    let ex = try Executor(baseDirectory: support)
    let export = try await ex.simulateExportCrash(in: folder, named: "Rechnungen.csv")
    let entry = try await ex.beginExternal(.reminders, label: "Zahnarzt").job
    let restarted = try Executor(baseDirectory: support)
    let pending = await restarted.pendingRecovery()
    let leftovers = try fm.contentsOfDirectory(atPath: folder.path)
    let exportState = await restarted.jobState(jobID: export), entryState = await restarted.jobState(jobID: entry)
    return pending.isEmpty && leftovers.isEmpty && exportState == "failed" && entryState == "abandoned"
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

// MARK: - Export

check("ZIP: CRC-32") { ZipWriter.crc32(Data("123456789".utf8)) == 0xCBF4_3926 }

// MARK: - Search and evidence

check("FTS5 (trigram) finds the passage with the phrase") {
    let index = try SearchIndex()
    try index.add(file: URL(fileURLWithPath: "/x/a.pdf"), page: 1, text: invoiceText)
    try index.add(file: URL(fileURLWithPath: "/x/m.pdf"), page: 2, text: contractPages[1])
    try index.add(file: URL(fileURLWithPath: "/x/m.pdf"), page: 1, text: contractPages[0])
    let hits = try index.search("Wie lange ist die Kündigungsfrist?")
    let hits2 = try index.search("Rechnungsnummer 2026-118734")
    return hits.first?.page == 2 && hits.first?.text.contains("drei Monaten") == true && hits2.first?.file.lastPathComponent == "a.pdf"
}
// MARK: - Fixed context

check("Persona + rules under 500 tokens (per task)") {
    let sizes = Prompts.Task.allCases.map { Prompts.estimateTokens(Prompts.system($0)) }
    print("   fixed contexts: \(sizes) tokens (estimated)")
    return Prompts.persona.contains("Pippa") && sizes.allSatisfy { $0 < Prompts.budget }
}
check("Strict schema for the one fixed task (tidy classification): every required field declared, no open objects") {
    func valid(_ value: Any) -> Bool {
        if let list = value as? [Any] { return list.allSatisfy(valid) }
        guard let object = value as? [String: Any] else { return true }
        if object["type"] as? String == "object" {
            guard let props = object["properties"] as? [String: Any], let required = object["required"] as? [String],
                  Set(required) == Set(props.keys), object["additionalProperties"] as? Bool == false else { return false }
        }
        return object.values.allSatisfy(valid)
    }
    return [Prompts.classifySchema].allSatisfy {
        guard let schema = try? JSONSerialization.jsonObject(with: Data($0.utf8)) else { return false }
        return valid(schema)
    }
}

// MARK: - Model choice

let GB: UInt64 = 1 << 30
/// The bundled catalog, with a stand-in pin for table models that are not pinned yet (only so the table itself can be
/// checked; "Default model is pinned" checks the real pins).
let tableCatalog: ModelCatalog = {
    var catalog = ModelCatalog.bundled()
    for index in catalog.models.indices where catalog.models[index].pinned == nil && ModelSelector.tableKeys.contains(catalog.models[index].key) {
        catalog.models[index].pending = nil
        let json = #"{"revision": "check", "files": [{"path": "stand-in.gguf", "size": 1, "sha256": "\#(String(repeating: "0", count: 64))"}]}"#
        catalog.models[index].pinned = try? JSONDecoder().decode(CatalogModel.Pinned.self, from: Data(json.utf8))
    }
    return catalog
}()
func pick(_ gb: UInt64, _ preference: ModelPreference = .standard) -> ModelChoice? {
    try? ModelSelector.choose(physicalMemory: gb * GB, preference: preference, appleSilicon: true, catalog: tableCatalog).get()
}
check("Default model is pinned: every table model has revision, path, size and SHA256 (scripts/pin-model.sh)") {
    let catalog = ModelCatalog.bundled()
    let unpinned = ModelSelector.tableKeys.filter { key in
        guard let model = catalog.model(key), model.pending == nil, let pinned = model.pinned, !pinned.files.isEmpty,
              pinned.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else { return true }
        return !pinned.files.allSatisfy { $0.size > 0 && $0.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }
    }
    if !unpinned.isEmpty { print("   not pinned: \(unpinned.joined(separator: ", ")) → scripts/pin-model.sh <key> <hf-repo>") }
    return unpinned.isEmpty
}
check("Model: 8 GB → qwen3.5-4b-q4, also with \"More thorough\" saved (no choice below 24 GB)") {
    pick(8)?.model.key == "qwen3.5-4b-q4" && pick(8, .thorough)?.model.key == "qwen3.5-4b-q4"
        && !ModelSelector.offersThorough(physicalMemory: 8 * GB)
}
check("Model: 16 GB → k2-horizon-7b, ctx 16384, ctx-checkpoints 4, cache-ram 0; no \"More thorough\"") {
    let c = pick(16)
    return c?.model.key == "k2-horizon-7b" && c?.ctx == 16384 && c?.extra["ctx-checkpoints"] == "4" && c?.extra["cache-ram"] == "0"
        && pick(16, .thorough)?.model.key == "k2-horizon-7b" && !ModelSelector.offersThorough(physicalMemory: 16 * GB)
        && (c?.model.memGiB ?? 99) <= ModelSelector.budgetGiB(physicalMemory: 16 * GB)
}
check("Model: K2 Horizon 7B does not fit 8 GB; low thinking via the template, XML tool calls") {
    let k2 = tableCatalog.model("k2-horizon-7b")
    return (k2?.memGiB ?? 0) > ModelSelector.budgetGiB(physicalMemory: 8 * GB)
        && k2?.extra?["chat-template-kwargs"]?.description == #"{"reasoning_effort":"low","tool_call_format":"xml"}"#
}
check("Model: 24 GB → k2-horizon-7b, ctx 32768; \"More thorough\" → qwen3.6-35b-a3b-iq3 within the memory budget") {
    let c = pick(24), t = pick(24, .thorough)
    return c?.model.key == "k2-horizon-7b" && c?.ctx == 32768 && ModelSelector.offersThorough(physicalMemory: 24 * GB)
        && t?.model.key == "qwen3.6-35b-a3b-iq3" && t?.ctx == 32768
        && (t?.model.memGiB ?? 99) <= ModelSelector.budgetGiB(physicalMemory: 24 * GB)
}
check("Model: 32 and 64 GB → k2-horizon-7b; \"More thorough\" → qwen3.6-35b-a3b-iq3") {
    [32, 64].allSatisfy { gb in
        pick(UInt64(gb))?.model.key == "k2-horizon-7b" && pick(UInt64(gb), .thorough)?.model.key == "qwen3.6-35b-a3b-iq3"
            && ModelSelector.offersThorough(physicalMemory: UInt64(gb) * GB)
    }
}
check("Model: an unpinned table model is unavailable (never a download without a SHA256)") {
    var catalog = tableCatalog
    if let index = catalog.models.firstIndex(where: { $0.key == "k2-horizon-7b" }) { catalog.models[index].pinned = nil }
    if case .failure(.modelUnavailable) = ModelSelector.choose(physicalMemory: 16 * GB, appleSilicon: true, catalog: catalog) { return true }
    return false
}
check("Model: Intel → not supported") {
    if case .failure(.unsupportedHardware) = ModelSelector.choose(physicalMemory: 32 * GB, appleSilicon: false) { return true }
    return false
}
check("Model: table only; `named` only for measurements and models.json (both table rows keep their settings)") {
    let auto = pick(16)
    let same = ModelSelector.named("k2-horizon-7b", physicalMemory: 16 * GB, catalog: tableCatalog)
    let thorough = ModelSelector.named("qwen3.6-35b-a3b-iq3", physicalMemory: 24 * GB, catalog: tableCatalog)
    let other = ModelSelector.named("qwen3.5-9b-q4", physicalMemory: 16 * GB, catalog: tableCatalog)
    return same == auto && thorough == pick(24, .thorough) && other?.model.key == "qwen3.5-9b-q4" && other?.ctx == 16384
        && other?.extra["cache-ram"] == "0"
        && ModelSelector.named("gibt-es-nicht", physicalMemory: 16 * GB) == nil
}
check("Model: \"Pippa's knowledge\" is saved in settings.json; old files and unknown values mean Standard, the port stays") {
    let base = dir("model-preference")
    try PippaSettings(llamaPort: 41_234).save(to: base)
    let fresh = PippaSettings.load(from: base).preference
    try PippaSettings.savePreference(.thorough, to: base)
    let saved = PippaSettings.load(from: base)
    try PippaSettings.savePreference(.standard, to: base)
    let back = PippaSettings.load(from: base)
    write(#"{"llamaPort": 41234, "modelPreference": "riesig", "modelOverride": "x"}"#, base.appendingPathComponent("settings.json"))
    let unknown = PippaSettings.load(from: base)
    return fresh == .standard && saved.preference == .thorough && saved.llamaPort == 41_234
        && back.preference == .standard && back.modelPreference == nil && back.llamaPort == 41_234
        && unknown.preference == .standard && unknown.llamaPort == 41_234
}
await checkAsync("Model: old stock (24 GB, Qwen3.6 35B Q3) is no longer adopted but left untouched") {
    let base = dir("adopt-installed")
    let models = LocalEngine.modelsDirectory(base: base)
    try fm.createDirectory(at: models, withIntermediateDirectories: true)
    let file = ModelCatalog.bundled().model("qwen3.6-35b-a3b-q3")!.pinned!.files[0]
    let url = models.appendingPathComponent(file.path)
    fm.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(file.size)) // sparse file, takes no space
    try handle.close()
    write(file.sha256, url.appendingPathExtension("ok"))
    try PippaSettings().save(to: base)
    let engine = LocalEngine(baseDirectory: base, physicalMemory: 24 * GB, integrations: DemoIntegrations())
    defer { Task { await engine.shutdown() } }
    let size = await engine.modelDownloadSize      // K2 Horizon 7B missing: the one download question
    let kept = fm.fileExists(atPath: url.path) && fm.fileExists(atPath: url.appendingPathExtension("ok").path)
    let settings = String(decoding: (try? Data(contentsOf: base.appendingPathComponent("settings.json"))) ?? Data(), as: UTF8.self)
    try? fm.removeItem(at: url)
    // Without a pin there is no size (and no download at all); "Default model is pinned" reports that on its own.
    let pinned = ModelCatalog.bundled().model("k2-horizon-7b")?.pinned != nil
    return (size != nil || !pinned) && kept && !settings.contains("qwen3.6")
}
await checkAsync("Existing models: LM Studio, Ollama, Hugging Face detected, adopted without network, source stays") {
    let home = dir("existing-home")
    let payload = Data((0..<65_536).map { UInt8($0 % 251) })
    let probe = home.appendingPathComponent("probe")
    try payload.write(to: probe)
    let hash = try ModelDownloader.sha256(of: probe)
    let json = """
    {"sampling": {}, "models": [
      {"key": "a", "label": "A", "repo": "r/a", "quant": "q", "memGiB": 1, "ctx": 4096, "rank": 1,
       "pinned": {"revision": "x", "files": [{"path": "sub/a.gguf", "size": \(payload.count), "sha256": "\(hash)"}]}}]}
    """
    let catalog = try JSONDecoder().decode(ModelCatalog.self, from: Data(json.utf8))
    let model = catalog.model("a")!
    let roots = ExistingModels.defaultRoots(home: home)
    guard ExistingModels.find(catalog, roots: roots).isEmpty else { return false }
    // LM Studio: name as on Hugging Face; a same-size file with a different name doesn't count.
    let lms = home.appendingPathComponent(".lmstudio/models/r/a-GGUF")
    try fm.createDirectory(at: lms, withIntermediateDirectories: true)
    try Data(repeating: 7, count: payload.count).write(to: lms.appendingPathComponent("b.gguf"))
    try payload.write(to: lms.appendingPathComponent("a.gguf"))
    let found = ExistingModels.find(catalog, roots: roots)
    guard found[hash]?.source == "LM Studio", found[hash]?.url.lastPathComponent == "a.gguf" else { return false }
    // Ollama: named by content.
    let ollama = home.appendingPathComponent(".ollama/models/blobs")
    try fm.createDirectory(at: ollama, withIntermediateDirectories: true)
    try payload.write(to: ollama.appendingPathComponent("sha256-\(hash)"))
    guard ExistingModels.find(catalog, roots: roots.filter { $0.source == "Ollama" })[hash] != nil else { return false }
    // Hugging Face: snapshots/…/a.gguf is a symlink to blobs/<sha256>.
    let hub = home.appendingPathComponent(".cache/huggingface/hub/models--r--a")
    try fm.createDirectory(at: hub.appendingPathComponent("blobs"), withIntermediateDirectories: true)
    try fm.createDirectory(at: hub.appendingPathComponent("snapshots/x"), withIntermediateDirectories: true)
    try payload.write(to: hub.appendingPathComponent("blobs/\(hash)"))
    try fm.createSymbolicLink(atPath: hub.appendingPathComponent("snapshots/x/a.gguf").path, withDestinationPath: "../../blobs/\(hash)")
    guard ExistingModels.find(catalog, roots: roots.filter { $0.source == "Hugging Face" })[hash] != nil else { return false }
    // Adopt instead of download: nothing is missing, no network needed, the source stays.
    let d = ModelDownloader(directory: dir("existing-models"))
    let size = Int64(payload.count)
    guard d.downloadSize(model, existing: found) == ModelDownloadSize(total: size, remaining: 0, existing: size, existingSource: "LM Studio"),
          d.isAvailable(model, existing: found), !d.isInstalled(model) else { return false }
    try await d.download(model, existing: found) { _, _ in }
    let source = lms.appendingPathComponent("a.gguf")
    let sourceData = try Data(contentsOf: source)
    return d.isInstalled(model) && sourceData == payload && d.downloadSize(model)?.remaining == 0
}
check("Existing models: matching name, wrong content is not adopted") {
    let home = dir("existing-wrong")
    let payload = Data((0..<4096).map { UInt8($0 % 13) })
    let hash = String(repeating: "a", count: 64)
    let json = """
    {"sampling": {}, "models": [
      {"key": "a", "label": "A", "repo": "r/a", "quant": "q", "memGiB": 1, "ctx": 4096, "rank": 1,
       "pinned": {"revision": "x", "files": [{"path": "a.gguf", "size": \(payload.count), "sha256": "\(hash)"}]}}]}
    """
    let catalog = try JSONDecoder().decode(ModelCatalog.self, from: Data(json.utf8))
    let lms = home.appendingPathComponent(".lmstudio/models")
    try fm.createDirectory(at: lms, withIntermediateDirectories: true)
    try payload.write(to: lms.appendingPathComponent("a.gguf"))
    guard let found = ExistingModels.find(catalog, roots: ExistingModels.defaultRoots(home: home))[hash] else { return false }
    let models = dir("existing-wrong-models")
    let d = ModelDownloader(directory: models)
    let adopted = try d.adopt(catalog.model("a")!.pinned!.files[0], from: found.url)
    let left = try fm.contentsOfDirectory(atPath: models.path)
    return !adopted && left.isEmpty && fm.fileExists(atPath: found.url.path)
}
await checkAsync("Existing models: no download without consent after a failed adoption") {
    let home = dir("existing-no-consent")
    let payload = Data((0..<4096).map { UInt8($0 % 17) })
    let json = """
    {"sampling": {}, "models": [
      {"key": "a", "label": "A", "repo": "r/a", "quant": "q", "memGiB": 1, "ctx": 4096, "rank": 1,
       "pinned": {"revision": "x", "files": [{"path": "a.gguf", "size": \(payload.count), "sha256": "\(String(repeating: "b", count: 64))"}]}}]}
    """
    let catalog = try JSONDecoder().decode(ModelCatalog.self, from: Data(json.utf8))
    let lms = home.appendingPathComponent(".lmstudio/models")
    try fm.createDirectory(at: lms, withIntermediateDirectories: true)
    try payload.write(to: lms.appendingPathComponent("a.gguf"))
    let found = ExistingModels.find(catalog, roots: ExistingModels.defaultRoots(home: home))
    let models = dir("existing-no-consent-models")
    let d = ModelDownloader(directory: models)
    let rejected = LockedBox<[String]>([])
    do {
        try await d.download(catalog.model("a")!, existing: found, allowNetwork: false, rejected: { sha in rejected.mutate { $0.append(sha) } }) { _, _ in }
        return false
    } catch is ModelDownloader.AdoptionFailed {}
    // Likewise with no file found and no consent: nothing from the network.
    do { try await d.download(catalog.model("a")!, allowNetwork: false) { _, _ in }; return false }
    catch is ModelDownloader.AdoptionFailed {}
    let contents = try fm.contentsOfDirectory(atPath: models.path)
    return rejected.value == [String(repeating: "b", count: 64)] && contents.isEmpty
}
check("Existing models: llama.cpp name only with exactly the repo prefix") {
    let home = dir("existing-llamacpp")
    let size = 2048
    let json = """
    {"sampling": {}, "models": [
      {"key": "a", "label": "A", "repo": "owner/a-GGUF", "quant": "q", "memGiB": 1, "ctx": 4096, "rank": 1,
       "pinned": {"revision": "x", "files": [{"path": "a.gguf", "size": \(size), "sha256": "\(String(repeating: "c", count: 64))"}]}}]}
    """
    let catalog = try JSONDecoder().decode(ModelCatalog.self, from: Data(json.utf8))
    let cache = home.appendingPathComponent("Library/Caches/llama.cpp")
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    try Data(count: size).write(to: cache.appendingPathComponent("old_a.gguf"))
    let roots = ExistingModels.defaultRoots(home: home)
    guard ExistingModels.find(catalog, roots: roots).isEmpty else { return false }
    try Data(count: size).write(to: cache.appendingPathComponent("owner_a-GGUF_a.gguf"))
    return ExistingModels.find(catalog, roots: roots).first?.value.source == "llama.cpp"
}
check("Download URL as in installer/hf.mjs") {
    ModelDownloader.url(repo: "unsloth/Qwen3.5-4B-GGUF", revision: "e87f176479d0855a907a41277aca2f8ee7a09523", path: "Qwen3.5-4B-Q4_K_M.gguf").absoluteString
        == "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf"
}
check("Server arguments: local only, key only in the environment, jinja, catalogue values") {
    let c = pick(16)!
    let args = LlamaServer.arguments(choice: c, model: URL(fileURLWithPath: "/m.gguf"), port: 9000, supported: nil)
    let s = args.joined(separator: " ")
    let env = LlamaServer.environment(apiKey: "geheim-k", base: ["PATH": "/usr/bin"])
    return s.contains("--host 127.0.0.1") && !s.contains("--api-key") && !s.contains("geheim-k")
        && env["LLAMA_API_KEY"] == "geheim-k" && env["PATH"] == "/usr/bin" && s.contains("--jinja") && s.contains("--ctx-size 16384")
        && s.contains("--ctx-checkpoints 4") && s.contains("--cache-ram 0") && s.contains("--top-k 0") && s.contains("--no-webui")
        && s.contains("--reasoning off") && s.contains(#"--chat-template-kwargs {"reasoning_effort":"low","tool_call_format":"xml"}"#)
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
        && doc.fullText.contains("312,48 €") && Heuristics.sender(text: doc.fullText, headers: doc.headers) == "Hausverwaltung Berger"
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
        && Deadlines.find(in: doc).contains { $0.date == DayDate(year: 2026, month: 12, day: 31) }
}
check("PDF: text per page with page number") {
    let url = root.appendingPathComponent("vertrag.pdf")
    makePDF(contractPages, at: url)
    let doc = TextReader.read(url)
    return doc.pages.count == 2 && doc.pages[1].contains("drei Monaten") && doc.capped().contains("[S. 2]")
}

// MARK: - Flows without a model (pattern variant)

let folder = dir("Downloads")
makePDF([invoiceText], at: folder.appendingPathComponent("Scan_20260312.pdf"))
makePDF(contractPages, at: folder.appendingPathComponent("Dokument (3).pdf"))
write("Notizen zum Urlaub", folder.appendingPathComponent("notizen.txt"))
makePDF([""], at: folder.appendingPathComponent("scan0047.pdf"))   // no text
let engine = LocalEngine(baseDirectory: dir("support-engine"), modelEnabled: false)

await checkAsync("Overview: categories add up to the file count") {
    let o = try await engine.overview(of: .files([folder]))
    print("   \(o.title) · \(o.subtitle) · \(o.categories.map { "\($0.count) \($0.name)" }.joined(separator: ", "))")
    return o.title == "Downloads" && o.subtitle == L("%lld files", table: "Core", 4) && o.categories.reduce(0) { $0 + $1.count } == 4
        && o.categories.contains { $0.name == DocCategory.other.label && $0.count == 4 } && o.actions.contains(.invoiceTable)
}

// Semantics now come from Pi; this intake checks native naming and the evidence limit.
await engine.setModelReplay { task, user in
    switch task {
    case .classify:
        if user.contains("Stadtwerke") { return #"{"kategorie":"rechnung","absender":"Stadtwerke Musterstadt","art":"Rechnung","datum":"02.03.2026","betreff":"","entwurf":false,"beleg":"Rechnung"}"#.replacingOccurrences(of: "2026", with: user.contains("2025") ? "2025" : "2026") }
        if user.contains("Mietvertrag") { return #"{"kategorie":"vertrag","absender":"Hausverwaltung Berger","art":"Mietvertrag","datum":"14.06.2021","betreff":"Wohnung","entwurf":false,"beleg":"Mietvertrag"}"# }
        return #"{"kategorie":"sonstiges","absender":"","art":"","datum":"","betreff":"","entwurf":false,"beleg":""}"#
    }
}

await checkAsync("Organise: plan with names from code, unreadable files stay") {
    let plan = try await engine.proposeSort(folder: folder)
    let names = plan.ops.filter { $0.kind != .mkdir }.map { $0.target.path.replacingOccurrences(of: folder.path + "/", with: "") }.sorted()
    print("   " + names.joined(separator: " | "))
    return names.contains("Rechnungen/2026/2026-03 Stadtwerke Musterstadt Rechnung.pdf")
        && names.contains("Verträge/Mietvertrag Wohnung 2021.pdf")
        && plan.skipped.contains { $0.url.lastPathComponent == "scan0047.pdf" }
        && plan.ops.filter { $0.kind == .mkdir }.count == 4
}

await checkAsync("Organise apply and undo through the engine") {
    let before = try fm.contentsOfDirectory(atPath: folder.path).sorted()
    let plan = try await engine.proposeSort(folder: folder)
    let receipt = try await engine.apply(plan, excluding: [])
    try await engine.undo(receipt)
    return try fm.contentsOfDirectory(atPath: folder.path).sorted() == before
}

await checkAsync("Organise: no second \"Rechnungen/Jahr\" inside the folder \"Rechnungen\"") {
    let inner = dir("Nachsortieren/Rechnungen")
    makePDF([invoiceText], at: inner.appendingPathComponent("Scan_20260312.pdf"))
    let plan = try await engine.proposeSort(folder: inner)
    let year = dir("Nachsortieren/Rechnungen/2026")
    makePDF([invoiceText], at: year.appendingPathComponent("scan2.pdf"))
    let again = try await engine.proposeSort(folder: year)
    let names = plan.ops.map { $0.target.path.replacingOccurrences(of: inner.path + "/", with: "") }
    let againNames = again.ops.map { $0.target.path.replacingOccurrences(of: year.path + "/", with: "") }
    print("   " + (names + againNames).joined(separator: " | "))
    return names.contains("2026/2026-03 Stadtwerke Musterstadt Rechnung.pdf") && !names.contains { $0.hasPrefix("Rechnungen") }
        && againNames.count == 1 && againNames[0].hasPrefix("2026-03 Stadtwerke") && !again.ops.contains { $0.kind == .mkdir }
}

await checkAsync("Organise: in \"Rechnungen/2026\" an invoice from 2025 stays here, no \"Rechnungen/2025\" inside") {
    let year = dir("Nachsortieren2/Rechnungen/2026")
    makePDF([invoiceText.replacingOccurrences(of: "2026", with: "2025")], at: year.appendingPathComponent("alt.pdf"))
    let plan = try await engine.proposeSort(folder: year)
    let names = plan.ops.map { $0.target.path.replacingOccurrences(of: year.path + "/", with: "") }
    print("   " + names.joined(separator: " | "))
    return names.count == 1 && names[0].hasPrefix("2025-03 Stadtwerke") && !plan.ops.contains { $0.kind == .mkdir }
}

await checkAsync("Overview of 50 files under 15 s") {
    let big = dir("Gross")
    for i in 0..<50 {
        if i % 2 == 0 { makePDF([invoiceText.replacingOccurrences(of: "84,20", with: "\(i),00")], at: big.appendingPathComponent("r\(i).pdf")) }
        else { write("Notiz \(i)", big.appendingPathComponent("n\(i).txt")) }
    }
    let start = Date()
    let o = try await engine.overview(of: .files([big]))
    let seconds = Date().timeIntervalSince(start)
    print(String(format: "   %.2f s for %@", seconds, o.subtitle))
    return seconds < 15 && o.subtitle == L("%lld files", table: "Core", 50)
}

await checkAsync("StubEngine returns the sample data") {
    let stub = StubEngine(delay: 0)
    let o = try await stub.overview(of: .files([URL(fileURLWithPath: "/Users/x/Downloads")]))
    return o.subtitle == L("%lld files", table: "Core", 47)
}

// MARK: - Deadlines (patterns only, fixed "today")

let oct5 = DayDate(year: 2026, month: 10, day: 5)!
check("Deadline: \"bis 31.10.2026\", invoice date doesn't count") {
    let text = "Stadtwerke Musterstadt\nRechnungsdatum 02.03.2026\nBitte zahlen Sie den Betrag bis 31.10.2026. Vielen Dank."
    let d = Deadlines.find(pages: [text], isPaged: false, source: nil, today: oct5)
    return d.count == 1 && d[0].kind == .payment && d[0].date == DayDate(year: 2026, month: 10, day: 31) && d[0].certainty == .sure
        && d[0].title == "Zahlen bis 31.10.2026" && d[0].quote == "Bitte zahlen Sie den Betrag bis 31.10.2026." && GermanText.isVerbatim(d[0].quote, in: text)
}
check("Deadline: document date and past dates are dropped") {
    let text = "Datum: 31.10.2026\nZahlbar bis 01.09.2026."
    return Deadlines.find(pages: [text], isPaged: false, source: nil, today: oct5).isEmpty
}
check("Deadline: \"zahlbar innerhalb von 14 Tagen\" from the letter date, uncertain") {
    let text = "Rechnungsdatum 01.10.2026\nDer Betrag ist zahlbar innerhalb von 14 Tagen ohne Abzug."
    let d = Deadlines.find(pages: [text], isPaged: false, source: nil, today: oct5)
    return d.count == 1 && d[0].date == DayDate(year: 2026, month: 10, day: 15) && d[0].certainty == .unsure
        && d[0].kind == .payment && d[0].note?.contains("01.10.2026") == true
}
check("Deadline: \"innerhalb eines Monats nach Bekanntgabe Einspruch\"") {
    let text = "Bescheid vom 10.09.2026\nGegen diesen Bescheid kann innerhalb eines Monats nach Bekanntgabe Einspruch eingelegt werden."
    let d = Deadlines.find(pages: [text], isPaged: false, source: nil, today: DayDate(year: 2026, month: 10, day: 1)!)
    return d.count == 1 && d[0].kind == .objection && d[0].date == DayDate(year: 2026, month: 10, day: 10)
}
check("Deadline: notice period with contract end yields a date") {
    let text = "Die Laufzeit endet am 31.12.2026. Der Vertrag kann mit einer Frist von drei Monaten zum Monatsende gekündigt werden."
    let d = Deadlines.find(pages: [text], isPaged: false, source: nil, today: DayDate(year: 2026, month: 8, day: 1)!)
    let cancel = d.first { $0.kind == .cancellation }
    return cancel?.date == DayDate(year: 2026, month: 9, day: 30) && cancel?.certainty == .unsure
        && d.contains { $0.kind == .contractEnd && $0.date == DayDate(year: 2026, month: 12, day: 31) }
}
check("Deadline: notice period without contract end, with page and hint") {
    let d = Deadlines.find(pages: contractPages, isPaged: true, source: URL(fileURLWithPath: "/x/Mietvertrag.pdf"), today: oct5)
    return d.count == 1 && d[0].date == nil && d[0].title == "Kündigungsfrist: 3 Monate zum Monatsende" && d[0].location == "S. 2"
        && d[0].note == "Wer heute kündigt, ist zum 31.01.2027 raus." && GermanText.isVerbatim(d[0].quote, in: contractPages[1])
}
check("Deadline: sentence doesn't end at \"3. Oktober\"") {
    let text = "Bitte zahlen Sie bis zum 3. Oktober 2026 den Betrag. Danke."
    let d = Deadlines.find(pages: [text], isPaged: false, source: nil, today: DayDate(year: 2026, month: 9, day: 1)!)
    return d.first?.quote == "Bitte zahlen Sie bis zum 3. Oktober 2026 den Betrag."
}
check("Deadline: direct debit and appointment") {
    let text = "Der Betrag wird am 15.10.2026 abgebucht.\n\nIhr Termin ist am 20.10.2026 um 10 Uhr."
    let d = Deadlines.find(pages: [text], isPaged: false, source: nil, today: oct5)
    return d.map(\.kind) == [.debit, .appointment]
}
check("Date arithmetic: month end, quarter, 31st + 1 month") {
    let jan31 = DayDate(year: 2026, month: 1, day: 31)!
    return jan31.adding(months: 1) == DayDate(year: 2026, month: 2, day: 28) && jan31.endOfQuarter == DayDate(year: 2026, month: 3, day: 31)
        && DayDate(year: 2024, month: 2, day: 3)!.endOfMonth == DayDate(year: 2024, month: 2, day: 29) && jan31.adding(days: 1) == DayDate(year: 2026, month: 2, day: 1)
}
check("Entry: title, evidence as note, reminder three days before payment") {
    let d = Deadline(kind: .payment, date: DayDate(year: 2026, month: 10, day: 31), title: "Zahlen bis 31.10.2026",
                     quote: "Bitte zahlen Sie bis 31.10.2026.", source: URL(fileURLWithPath: "/x/Rechnung.pdf"), location: "S. 1", certainty: .sure)
    let e = CalendarEntryBuilder.entry(for: d, target: .reminder, sender: "Stadtwerke", fallback: oct5, today: oct5)
    let soon = CalendarEntryBuilder.with(e, date: DayDate(year: 2026, month: 10, day: 6)!, today: oct5)
    let quoted = L("“%@”", table: "Analysis", "Bitte zahlen Sie bis 31.10.2026.")
    let from = L("From: %@", table: "Analysis", "Rechnung.pdf, " + L("Page %@", table: "Analysis", "1"))
    return e.title == L("Pay invoice", table: "Analysis") + " (Stadtwerke)" && e.date == DayDate(year: 2026, month: 10, day: 31) && e.alertDay == DayDate(year: 2026, month: 10, day: 28)
        && e.notes.hasPrefix(quoted) && e.notes.contains(from) && soon.alertDay == oct5
}
check("Entry: without a date the chosen date applies") {
    let d = Deadline(kind: .cancellation, date: nil, title: "Kündigungsfrist: 3 Monate", quote: "…", source: nil, location: nil, certainty: .unsure)
    let e = CalendarEntryBuilder.entry(for: d, target: .calendar, sender: nil, fallback: oct5, today: oct5)
    return e.date == oct5 && e.title == L("Cancel contract", table: "Analysis") && e.integration == .calendar
}

// MARK: - Mail (read only, no real apps)

check("Mail from Apple Mail becomes .eml, which the normal reader understands") {
    let m = MailMessage(subject: "Nebenkosten 2025 – Nachzahlung", sender: "Hausverwaltung Berger <info@berger-hv.de>",
                        date: Date(timeIntervalSince1970: 1_790_000_000), body: "Zahlbar bis 31.10.2026.\nGrüße", attachmentNames: ["Abrechnung.pdf", "Plan \"neu\".pdf"])
    let parsed = MailParser.parse(Data(m.emlText.utf8))
    return parsed.headers["subject"] == "Nebenkosten 2025 – Nachzahlung" && parsed.body == "Zahlbar bis 31.10.2026.\nGrüße"
        && parsed.attachments == ["Abrechnung.pdf", "Plan 'neu'.pdf"] && Heuristics.sender(text: "", headers: parsed.headers) == "Hausverwaltung Berger"
        && m.fileName == "Nebenkosten 2025 – Nachzahlung.eml"
}
check("Pippa sends nothing: no Notes integration, no Notes exception") {
    guard Integration.allCases == [.reminders, .calendar, .mail], Integration(rawValue: "notes") == nil else { return false }
    var url = URL(fileURLWithPath: fm.currentDirectoryPath)
    for _ in 0..<5 where !fm.fileExists(atPath: url.appendingPathComponent("app/Packaging/Pippa.entitlements").path) { url.deleteLastPathComponent() }
    // Nothing to check without the repo folder.
    guard let entitlements = try? String(contentsOf: url.appendingPathComponent("app/Packaging/Pippa.entitlements"), encoding: .utf8) else { return true }
    // Without the sandbox there are no Apple Events exceptions any more, only the Hardened Runtime entitlement.
    return !entitlements.contains("com.apple.Notes") && entitlements.contains("com.apple.security.automation.apple-events")
        && !entitlements.contains("<key>com.apple.security.app-sandbox</key>")
}
check("Shell: no counter badge, a ⌃⌥ Space shortcut as default") {
    var url = URL(fileURLWithPath: fm.currentDirectoryPath)
    for _ in 0..<5 where !fm.fileExists(atPath: url.appendingPathComponent("app/Sources/Pippa/App/Hotkey.swift").path) { url.deleteLastPathComponent() }
    let sources = url.appendingPathComponent("app/Sources/Pippa")
    // Nothing to check without the repo folder.
    guard let hotkey = try? String(contentsOf: sources.appendingPathComponent("App/Hotkey.swift"), encoding: .utf8),
          let layers = try? String(contentsOf: sources.appendingPathComponent("Shell/ShellLayers.swift"), encoding: .utf8),
          let model = try? String(contentsOf: sources.appendingPathComponent("App/AppModel.swift"), encoding: .utf8) else { return true }
    return hotkey.contains("static let standard: Hotkey = .controlOptionSpace") && hotkey.contains("?? .standard")
        && !hotkey.contains("keepEarlierDefault") && !layers.contains("BadgeView") && !model.contains("waitingCount")
}

/// Like DemoIntegrations, but on undo every entry counts as changed in the meantime.
final class ChangedIntegrations: AppIntegrations, @unchecked Sendable {
    let base = DemoIntegrations(granted: true)
    func access(_ i: Integration) async -> IntegrationAccess { await base.access(i) }
    func requestAccess(_ i: Integration) async -> IntegrationAccess { await base.requestAccess(i) }
    func add(_ e: CalendarEntry, tag: URL) async throws -> CreatedItem { try await base.add(e, tag: tag) }
    func remove(_ item: CreatedItem) async throws -> RemoveResult { .changed }
    func selectedMail() async throws -> MailMessage? { nil }
}

let demo = DemoIntegrations(granted: true)
let linkedEngine = LocalEngine(baseDirectory: dir("support-integrations"), modelEnabled: false, integrations: demo)
let sampleEntry = CalendarEntry(target: .reminder, title: "Zahlen · Stadtwerke", date: DayDate(year: 2026, month: 10, day: 31)!, notes: "„…“", alertDay: DayDate(year: 2026, month: 10, day: 29)!)

await checkAsync("Enter reminder: in the journal, undo removes it") {
    let receipt = try await linkedEngine.addEntry(sampleEntry)
    let created = demo.createdCount
    try await linkedEngine.undo(receipt)
    return created == 1 && demo.createdCount == 0 && receipt.summary == L("Added to Reminders", table: "Core") && receipt.undoDetail != nil
}
await checkAsync("Nothing is entered without permission") {
    let locked = DemoIntegrations()
    let e = LocalEngine(baseDirectory: dir("support-locked"), modelEnabled: false, integrations: locked)
    do { _ = try await e.addEntry(sampleEntry); return false } catch let err as PippaError {
        let pending = await e.pendingRecovery()
        return err == .accessDenied(L("Reminders", table: "Core")) && locked.createdCount == 0 && pending.isEmpty
    }
}
await checkAsync("Entry changed in the meantime stays on undo") {
    let e = LocalEngine(baseDirectory: dir("support-changed"), modelEnabled: false, integrations: ChangedIntegrations())
    let r = try await e.addEntry(sampleEntry)
    do { try await e.undo(r); return false } catch let err as PippaError {
        guard case .undoIncomplete(let restored, let conflicts, let list) = err else { return false }
        return restored == 0 && conflicts == 1 && list.first?.why == L("It has changed since then, so it stays.", table: "Core") && !err.changedSomething
    }
}
await checkAsync("Overview of a letter offers deadlines; the date comes from the code's patterns, no model") {
    let f = dir("brief").appendingPathComponent("Brief.txt")
    write("Stadtwerke Musterstadt\nRechnungsdatum 02.03.2026\nRechnung\nBitte zahlen Sie den Betrag von 84,20 € bis 31.12.2099.", f)
    let o = try await linkedEngine.overview(of: .files([f]))
    return o.actions.first == .deadlines && o.deadlines.allSatisfy { $0.date == DayDate(year: 2099, month: 12, day: 31) }
}
await checkAsync("StubEngine: mail from sample data") {
    let stub = StubEngine(delay: 0)
    let denied = (try? await stub.selectedMail()) == nil
    _ = await stub.requestIntegrationAccess(.mail)
    let mail = try await stub.selectedMail()
    return denied && mail?.attachmentNames == ["Nebenkosten 2025.pdf"]
}
await checkAsync("Script for reading mail compiles (nothing is sent)") {
    let result = await MainActor.run { IntegrationScripts.compileAll() }
    // Excel is missing from the result when Excel isn't installed (CI); its script is then not compiled.
    return result["Mail"] == true && result["MailReply"] == true && result["MailSearch"] == true && (result["Excel"] ?? true)
        && Set(result.keys).isSubset(of: ["Mail", "MailReply", "MailSearch", "Excel"])
}


// MARK: - Real run (PippaLive): bugs found along the way

check("Download: file size freshly read (resume otherwise looped forever at the same spot)") {
    let f = root.appendingPathComponent("grow.part")
    try Data(count: 100).write(to: f)
    _ = try f.resourceValues(forKeys: [.fileSizeKey])          // fills the URL cache
    let h = try FileHandle(forWritingTo: f); try h.seekToEnd(); try h.write(contentsOf: Data(count: 50)); try h.close()
    return ModelDownloader.fileSize(f) == 150 && ModelDownloader.fileSize(root.appendingPathComponent("fehlt")) == -1
}
check("Models folder via PIPPA_MODELS_DIR") {
    let base = URL(fileURLWithPath: "/x/Support")
    return LocalEngine.modelsDirectory(base: base).path == "/x/Support/models"
        && LocalEngine.modelsDirectory(base: base, environment: ["PIPPA_MODELS_DIR": "/scratch/m"]).path == "/scratch/m"
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
        && Heuristics.invoiceAmount(text: lines.joined(separator: "\n")).map { $0.amount == Decimal(string: "23.45") && $0.sure } == true
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
    return GermanText.isVerbatim("Für Hunde und Katzen ist die vorherige schriftliche Zustimmung der Vermieterin nötig.", in: text)
        && text.hasPrefix("§ 4 Kaution")
}
check("Quote check: ligatures, hyphens, page markers") {
    let src = "Die Kündigungs-\nfrist beträgt drei Monate. Die Mieterin ﬁndet den Schlüssel."
    return GermanText.isVerbatim("Die Kündigungsfrist beträgt drei Monate.", in: src)
        && GermanText.isVerbatim("Die Kündigungs- frist beträgt drei Monate.", in: src)
        && GermanText.isVerbatim("Die Mieterin findet den Schlüssel.", in: src)
        && !GermanText.isVerbatim("Die Kündigungsfrist beträgt zwei Monate.", in: src)
}
check("Sender: without \"med. dent.\", cut at a word boundary") {
    Heuristics.sender(text: "Zahnarztpraxis Dr. med. dent. Julia Hoffmann\nBahnhofplatz 2 · 88131 Lindau\nRechnung") == "Zahnarztpraxis Dr. Julia Hoffmann"
        && Naming.sanitize("Gemeinschaftspraxis für Allgemeinmedizin Lindau Nord", maxLength: 40) == "Gemeinschaftspraxis für Allgemeinmedizin"
}
check("Subject: \"Hausverwaltung\" is not \"Haus\"") {
    Heuristics.subject(text: "Mietvertrag zwischen Hausverwaltung Berger und Max Muster") == nil
        && Heuristics.subject(text: "Mietvertrag zwischen Hausverwaltung Berger und Max Muster über die Wohnung Lindenstraße 5") == "Wohnung"
}
check("Kind: \"Mobilfunkvertrag\" instead of \"Kündigung\" from a later section") {
    let text = "Vodafone GmbH\nVertragszusammenfassung Mobilfunkvertrag\nTarif GigaMobil S\n" + String(repeating: "Leistungsbeschreibung. ", count: 10) + "\nKündigung\nDer Vertrag kann mit einer Frist von einem Monat gekündigt werden."
    return Keywords.kind(text: text, fileName: "Vertrag Mobilfunk.pdf") == "Mobilfunkvertrag"
        && Keywords.kind(text: "Vertrag über Gartenpflege\n" + String(repeating: "x ", count: 300) + "\n§ 7 Kündigung", fileName: "a.pdf") == "Vertrag"
}
check("Amount: back payment instead of total cost, receipt total") {
    let letter = "Gesamtkosten Ihrer Wohnung 2.592,48 €\nabzüglich Ihrer Vorauszahlungen (12 × 190,00 €) 2.280,00 €\nNachzahlung 312,48 €"
    let bon = "Zwischensumme 20,00\nSUMME EUR 23,45\nBar 30,00"
    return Heuristics.invoiceAmount(text: letter).map { $0.amount == Decimal(string: "312.48") && $0.sure } == true
        && Heuristics.invoiceAmount(text: bon).map { $0.amount == Decimal(string: "23.45") && $0.sure } == true
}
check("Deadline: \"Einwände … innerhalb von zwölf Monaten\" is an objection, not a payment term") {
    let today = DayDate(year: 2026, month: 10, day: 5)!
    let d = Deadlines.find(pages: ["Lindau, 22.09.2026\nNebenkostenabrechnung\nEinwände gegen diese Abrechnung können Sie innerhalb von zwölf Monaten nach Zugang erheben."],
                           isPaged: true, source: nil, today: today)
    return d.count == 1 && d[0].kind == .objection && d[0].date == DayDate(year: 2027, month: 9, day: 22)
}
check("Sentences: not cut off at \"2.460,00\" or \"31.10.2026\"") {
    let s = Deadlines.sentences(in: "Bitte zahlen Sie bis zum 31.10.2026 auf unser Konto. Danke.")
    return s == ["Bitte zahlen Sie bis zum 31.10.2026 auf unser Konto.", "Danke."]
}
check("Model JSON: text around the object and fences are tolerated") {
    struct J: Decodable { var a: Int }
    return LocalEngine.decodeModelJSON(J.self, from: Data("{\"a\":1}".utf8))?.a == 1
        && LocalEngine.decodeModelJSON(J.self, from: Data("```json\n{\"a\":2}\n```".utf8))?.a == 2
        && LocalEngine.decodeModelJSON(J.self, from: Data("{\"a\":".utf8)) == nil
}

// Intake fixtures: how a model answers (schema output). The code checks and decides.
let replayDir = dir("replay")
write("Sommerfest im Kleingartenverein Aeschach e.V.\nSamstag, 12. September 2026, ab 14 Uhr\nUnser Angebot: Kaffee und Kuchen, Flohmarkt.", replayDir.appendingPathComponent("download.txt"))
write("Stadtwerke Musterstadt GmbH\nRechnungsdatum 02.03.2026\nRechnung Strom\nNettobetrag 70,76 €\nGesamtbetrag 84,20 €", replayDir.appendingPathComponent("Rechnung.txt"))
write("Mietvertrag\nzwischen Hausverwaltung Berger und Max Muster\nMusterstadt, den 14.06.2021\nKündigung mit drei Monaten Frist.", replayDir.appendingPathComponent("Vertrag.txt"))
// Invoice without a recognisable date: unclear, so Pippa asks the model.
write("Stadtwerke Musterstadt GmbH\nRechnung Strom\nGesamtbetrag 84,20 €", replayDir.appendingPathComponent("Strom.txt"))
let replayEngine = LocalEngine(baseDirectory: dir("support-replay"), modelEnabled: false)
let classified = Asked()
await replayEngine.setModelReplay { task, user in
    switch task {
    case .classify:
        classified.add(user)
        if user.contains("download.txt") { return #"{"kategorie":"brief","absender":"Kleingartenverein Aeschach","art":"Einladung","datum":"12.09.2026","betreff":"Sommerfest","entwurf":true}"# }
        if user.contains("Rechnung.txt") || user.contains("Strom.txt") { return #"{"kategorie":"vertrag","absender":"Stadtwerke Musterstadt GmbH","art":"Rechnung","datum":"02.03.2026","betreff":"Strom","entwurf":false}"# }
        return #"{"kategorie":"vertrag","absender":"Hausverwaltung Berger","art":"Mietvertrag","datum":"14.06.2021","betreff":"Wohnung","entwurf":false}"#
    }
}
await checkAsync("Intake: model classification without keywords or against the keywords → please review, no invented draft") {
    let plan = try await replayEngine.proposeSort(folder: replayDir)
    func op(_ name: String) -> PlanOp? { plan.ops.first { $0.source?.lastPathComponent == name } }
    guard let flyer = op("download.txt"), let unclearBill = op("Strom.txt"), let bill = op("Rechnung.txt"), let lease = op("Vertrag.txt") else { return false }
    // The patterns file clear cases (invoice with sender and date, lease) on their own; only unclear ones reach the model.
    let asked = classified.names(of: ["download.txt", "Strom.txt", "Rechnung.txt", "Vertrag.txt"])
    print("   model asked for: \(asked.sorted())")
    return flyer.certainty == .unsure && !flyer.target.lastPathComponent.contains("Entwurf") && flyer.target.path.contains("/Verträge/")
        && unclearBill.certainty == .unsure && unclearBill.target.path.contains("/Verträge/")
        && bill.certainty == .unsure && bill.target.path.contains("/Verträge/")
        && lease.certainty == .unsure && lease.target.lastPathComponent == "Mietvertrag 2021.txt"
        && asked == ["download.txt", "Strom.txt", "Rechnung.txt", "Vertrag.txt"]
}
check("Image: receipt scan is a receipt, camera photo stays a photo") {
    // OCR of a receipt (as TextReader returns it after assembling the lines).
    let bon = "Apotheke am Markt\nMaximilianstraße 9\n88131 Lindau\n14.08.2026 10:41 Kasse 2\nIbuprofen 400 akut 5,95\nSUMME EUR 23,45\nBar 30,00"
    let poster = "SOMMERFEST\nSamstag ab 14 Uhr"
    return Heuristics.looksLikeReceipt(text: bon)
        && Heuristics.imageCategory(captureDate: nil, cameraModel: nil, ocrText: bon) == .invoice
        && Heuristics.imageCategory(captureDate: Date(), cameraModel: "iPhone 15", ocrText: bon) == .photo
        && Heuristics.imageCategory(captureDate: nil, cameraModel: nil, ocrText: poster) == .photo
        && Heuristics.imageCategory(captureDate: nil, cameraModel: nil, ocrText: nil) == .photo
        && !Heuristics.looksLikeReceipt(text: "Urlaub am See\nSchöne Grüße")
}


// MARK: - Messages, history, deadline titles

check("Message after organising: \"In 4 Ordnern · 1 bleibt liegen\", zeros drop out") {
    let fourAndOne = L("In %lld folders", table: "Core", 4) + " · " + L("1 stays put", table: "Core")
    return Executor.detail(folders: 4, stayed: 1) == fourAndOne && Executor.detail(folders: 1, stayed: 0) == L("In 1 folder", table: "Core")
        && Executor.detail(folders: 0, stayed: 2) == L("%lld stay put", table: "Core", 2) && Executor.detail(folders: 0, stayed: 0) == L("Nothing changed", table: "Core")
}
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
await checkAsync("Organise without write permission: file stays, reason in German, in the message") {
    let scope = dir("readonly")
    let locked = scope.appendingPathComponent("Gesperrt", isDirectory: true)
    try fm.createDirectory(at: locked, withIntermediateDirectories: true)
    let a = locked.appendingPathComponent("a.txt"), b = scope.appendingPathComponent("b.txt")
    write("a", a); write("b", b)
    try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
    let ex = try Executor(baseDirectory: dir("support-readonly"))
    let report = try await ex.apply(Plan(scope: scope, ops: [
        PlanOp(kind: .move, source: a, target: scope.appendingPathComponent("Sonstiges/a.txt"), reason: "", certainty: .sure),
        PlanOp(kind: .move, source: b, target: scope.appendingPathComponent("Sonstiges/b.txt"), reason: "", certainty: .sure),
    ], skipped: []))
    let r = report.receipt
    let noAccess = L("I don’t have access to that.", table: "Core")
    let detail = L("In 1 folder", table: "Core") + " · " + L("1 stays put", table: "Core")
    return r.summary == L("1 file tidied", table: "Core") && r.detail == detail
        && r.stayed == [FileReason(name: "a.txt", why: noAccess)]
        && report.skipped.count == 1 && report.skipped[0].why == noAccess
}
await checkAsync("History: completed jobs, newest first; gone after undo") {
    let scope = dir("history")
    let a = scope.appendingPathComponent("a.txt"), b = scope.appendingPathComponent("b.txt")
    write("a", a); write("b", b)
    let e = LocalEngine(baseDirectory: dir("support-history"), modelEnabled: false)
    let first = try await e.apply(Plan(scope: scope, ops: [PlanOp(kind: .move, source: a, target: scope.appendingPathComponent("X/a.txt"), reason: "", certainty: .sure)], skipped: []), excluding: [])
    let second = try await e.apply(Plan(scope: scope, ops: [PlanOp(kind: .move, source: b, target: scope.appendingPathComponent("Y/b.txt"), reason: "", certainty: .sure)], skipped: []), excluding: [])
    let jobs = await e.recentJobs(limit: 10)
    guard jobs.map(\.id) == [second.id, first.id], jobs[1].summary == L("1 file tidied", table: "Core"), jobs[1].detail == L("In 1 folder", table: "Core"), jobs[0].date != nil else { return false }
    try await e.undo(jobs[1])
    let after = await e.recentJobs(limit: 10)
    let stub = await StubEngine(delay: 0).recentJobs(limit: 5)
    return after.map(\.id) == [second.id] && fm.fileExists(atPath: a.path) && stub.isEmpty
}
check("Abort midway: the error carries the undoable part") {
    let r = JobReceipt(id: UUID(), summary: "3 Dateien geordnet", detail: "In 1 Ordner", revealURL: nil)
    let e = PippaError.partial(receipt: r, why: "Kein Platz mehr frei.")
    return e.changedSomething && e.receipt == r && !PippaError.modelFailed.changedSomething && PippaError.modelFailed.receipt == nil
        && e.localizedDescription == L("Stopped partway through: %@ %@, and that can be undone.", table: "Core", "Kein Platz mehr frei.", "3 Dateien geordnet")
        && PippaError.undoIncomplete(restored: 2, conflicts: 1, notRestored: [FileReason(name: "a.pdf", why: "Die Datei ist nicht mehr da.")]).changedSomething
}
check("Deadlines: meaningful titles from kind and sender, never a file name") {
    let today = DayDate(year: 2026, month: 10, day: 5)!
    func find(_ text: String, _ name: String) -> [Deadline] {
        Deadlines.find(in: DocumentText(url: URL(fileURLWithPath: "/x/\(name)"), pages: [text], isPaged: true, usedOCR: false, headers: [:]), today: today)
    }
    let lease = find("Mietvertrag\nzwischen Hausverwaltung Berger und Anna Becker\nDas Mietverhältnis kann mit einer Kündigungsfrist von drei Monaten zum Monatsende gekündigt werden.", "download.pdf")
    let letter = find("Hausverwaltung Berger GmbH\nLindau, 22.09.2026\nNebenkostenabrechnung 2025\nBitte überweisen Sie die Nachzahlung von 312,48 € bis zum 31.10.2026.", "Dokument (3).pdf")
    let tax = find("Finanzamt Lindau\nSteuerbescheid für 2025\nDatum 01.10.2026\nGegen diesen Bescheid können Sie bis zum 02.11.2026 Einspruch einlegen.", "scan.pdf")
    let mail = find("Zahnarztpraxis Dr. Hoffmann\nWir bestätigen Ihren Termin am 15.10.2026 um 10:30 Uhr.", "Mail.eml")
    let titles = [lease.first?.reminderTitle(), letter.first(where: { $0.kind == .payment })?.reminderTitle(sender: "Hausverwaltung Berger"),
                  tax.first?.reminderTitle(), mail.first?.reminderTitle()]
    let expected: [String?] = [L("Cancel %@", table: "Analysis", "Mietvertrag") + " (Hausverwaltung Berger)",
                               L("Pay the utilities balance", table: "Analysis") + " (Hausverwaltung Berger)",
                               L("Object to %@", table: "Analysis", "Steuerbescheid") + " (Finanzamt Lindau)",
                               L("Appointment with %@", table: "Analysis", "Zahnarztpraxis Dr. Hoffmann")]
    return titles == expected
        && !titles.contains { ($0 ?? "").contains(".pdf") || ($0 ?? "").contains("download") }
}
check("Deadlines: reminder 14 days before cancelling/objection, 3 before payment, 1 before appointment; note without \"Bitte prüfen\"") {
    let today = DayDate(year: 2026, month: 1, day: 1)!
    func entry(_ kind: Deadline.Kind) -> CalendarEntry {
        CalendarEntryBuilder.entry(for: Deadline(kind: kind, date: DayDate(year: 2026, month: 3, day: 31), title: "", quote: "…", source: nil, location: nil, certainty: .sure),
                                   target: .reminder, sender: nil, fallback: today, today: today)
    }
    let moved = CalendarEntryBuilder.with(entry(.cancellation), date: DayDate(year: 2026, month: 6, day: 30)!, today: today)
    let rel = Deadlines.find(pages: ["Lindau, 22.09.2026\nZahlbar innerhalb von 14 Tagen."], isPaged: false, source: nil, today: DayDate(year: 2026, month: 9, day: 23)!)
    return entry(.cancellation).alertDay == DayDate(year: 2026, month: 3, day: 17) && entry(.objection).alertDay == DayDate(year: 2026, month: 3, day: 17)
        && entry(.payment).alertDay == DayDate(year: 2026, month: 3, day: 28) && entry(.appointment).alertDay == DayDate(year: 2026, month: 3, day: 30)
        && moved.alertDay == DayDate(year: 2026, month: 6, day: 16)
        && rel.first?.note == "14 Tage ab dem Briefdatum 22.09.2026 gerechnet." && !CalendarEntryBuilder.notes(for: rel[0]).contains("Bitte prüfen")
}
check("Tone: no jargon, no English, no status codes in messages") {
    let r = JobReceipt(id: UUID(), summary: "1 Datei geordnet", detail: "", revealURL: nil)
    let errors: [PippaError] = [.scopeMissing, .outsideScope, .unknownJob, .undoIncomplete(restored: 1, conflicts: 1), .modelUnavailable, .modelFailed,
                                .downloadFailed("Antwort 503"), .downloadFailed("Keine neuen Daten."), .checksumMismatch, .serverMissing,
                                .writeFailed(SystemError.reason(errno: ENOSPC)), .nothingToExport, .accessDenied("Kalender"), .appNotOpen("Mail"),
                                .entryFailed(""), .notAvailable, .partial(receipt: r, why: "Das ging gerade nicht.")]
    let texts = errors.compactMap(\.errorDescription) + [EPERM, ENOENT, EEXIST, EXDEV, ENOSPC, EIO].map { SystemError.reason(errno: $0) }
        + [Executor.detail(folders: 3, stayed: 2)]
    let bad = try NSRegularExpression(pattern: #"(?i)server|modell|token|http|json|verändert|übersprungen|error|failed|permission|denied|\b\d{3}\b"#)
    let offenders = texts.filter { bad.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
    if !offenders.isEmpty { print("   ", offenders) }
    return offenders.isEmpty && PippaError.downloadFailed("Antwort 503").errorDescription == L("The download isn’t working right now. I’ll try again shortly.", table: "Core")
        && !texts.contains { $0.hasSuffix(" ") }
}

runConversationChecks()
runChatContextChecks()
await runP0ContextChecks()
runPromptAttachmentChecks()
runPasteChecks()
runConversationReopenChecks()
runPillPlacementChecks()
await runInferenceChecks()
runSourceFidelityChecks()
runSkillChecks()
await runProposalChecks()
runErrorMessageChecks()
await runSortChecks()
await runTaskLogChecks()
runLocalizationChecks()
await runToolChecks()
await runOCRChecks()
await runTrayChecks()
runActionChecks()
runSuggestionSampleChecks()
runAnswerChecks()
await runTrayFlowChecks()
await runLetterChecks()
await runSheetChecks()
await runSubscriptionChecks()
await runAgentBridgeChecks()
await runCalendarChecks()
runCalendarStoreChecks()
await runThoughtLineChecks()
runWorkStepChecks()
runColdStartChecks()
await runSetupChecks()
await runMCPChecks()
await runR2Checks()
await runR10Checks()
await runR3Checks()
await runR6Checks()
await runR7Checks()
await runR7bChecks()
await runW4aChecks()
await runTextScaleChecks()
runLegacyMigrationChecks()

print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
