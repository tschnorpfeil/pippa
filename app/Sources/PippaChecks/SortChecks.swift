import Foundation
import ImageIO
import PippaCore
import UniformTypeIdentifiers

/// Which files the model (as a replay) got to see.
final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var users: [String] = []
    func add(_ user: String) { lock.withLock { users.append(user) } }
    var count: Int { lock.withLock { users.count } }
    /// Which of the file names appeared in a request.
    func names(of candidates: [String]) -> Set<String> {
        lock.withLock { Set(candidates.filter { name in users.contains { $0.contains("Dateiname: \(name)\n") } }) }
    }
}

/// Growing plan while sorting, as the UI receives it.
final class Updates: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [Plan] = []
    private var firstAt: Date?
    func add(_ plan: Plan) { lock.withLock { plans.append(plan); if firstAt == nil { firstAt = Date() } } }
    var all: [Plan] { lock.withLock { plans } }
    var first: Date? { lock.withLock { firstAt } }
}

/// Small JPEG, with a capture date in the photo metadata when `taken` is set.
func makeImage(at url: URL, type: UTType, taken: String? = nil) {
    // Width from the name length: names of different length are not accidentally duplicates.
    let width = 4 + url.lastPathComponent.count
    let ctx = CGContext(data: nil, width: width, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: 8))
    guard let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return }
    var props: [CFString: Any] = [:]
    if let taken { props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: taken] }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    CGImageDestinationFinalize(dest)
}

/// Relative paths of all files under `folder` (without folders).
func tree(_ folder: URL) -> Set<String> {
    var out = Set<String>()
    let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey])
    while let u = e?.nextObject() as? URL {
        let rel = u.resolvingSymlinksInPath().path.replacingOccurrences(of: folder.resolvingSymlinksInPath().path + "/", with: "")
        out.insert((try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? rel + "/" : rel)
    }
    return out
}

/// "Tidy Downloads": first without a model by kind, name, photo metadata and identical content, then read, model only for the unclear.
func runSortChecks() async {
    let downloads = dir("Vorsortieren")
    makeImage(at: downloads.appendingPathComponent("IMG_0001.jpg"), type: .jpeg, taken: "2024:05:03 10:00:00")
    makeImage(at: downloads.appendingPathComponent("logo.png"), type: .png)
    makeImage(at: downloads.appendingPathComponent("Bildschirmfoto 2026-01-02 um 10.00.00.png"), type: .png)
    write("dmg", downloads.appendingPathComponent("Firefox 140.dmg"))
    write("pkg", downloads.appendingPathComponent("Treiber.pkg"))
    write("zip", downloads.appendingPathComponent("Urlaub.zip"))
    write("mp3", downloads.appendingPathComponent("Lied.mp3"))
    write("mov", downloads.appendingPathComponent("Clip.mov"))
    write("?", downloads.appendingPathComponent("daten.xyz"))
    write("Einkaufsliste: Milch, Brot, Äpfel", downloads.appendingPathComponent("liste.txt"))
    makePDF([invoiceText], at: downloads.appendingPathComponent("Rechnung.pdf"))
    try? fm.copyItem(at: downloads.appendingPathComponent("Rechnung.pdf"), to: downloads.appendingPathComponent("Rechnung (1).pdf"))
    let asked = Asked()
    let engine = LocalEngine(baseDirectory: dir("support-vorsortieren"), modelEnabled: false)
    await engine.setModelReplay { _, user in asked.add(user); return nil }
    let updates = Updates()

    await checkAsync("Pre-sort: images, photos, screenshot, installer, archive, music, video, duplicates, invoice, list, unknown") {
        let plan = try await engine.proposeSort(items: nil, scope: downloads, limit: PreSort.firstRunLimit) { updates.add($0) }
        let placed = Dictionary(uniqueKeysWithValues: plan.ops.filter { $0.kind != .mkdir }.compactMap { op in
            op.source.map { ($0.lastPathComponent, op.kind == .trash ? "Papierkorb" : op.target.path.replacingOccurrences(of: downloads.path + "/", with: "")) }
        })
        for (k, v) in placed.sorted(by: { $0.key < $1.key }) { print("   \(k) → \(v)") }
        let expected = [
            "IMG_0001.jpg": "Fotos/2024/2024-05-03 Foto 01.jpg",
            "logo.png": "Bilder/logo.png",
            "Bildschirmfoto 2026-01-02 um 10.00.00.png": "Bildschirmfotos/Bildschirmfoto 2026-01-02 um 10.00.00.png",
            "Firefox 140.dmg": "Installer (kann weg?)/Firefox 140.dmg",
            "Treiber.pkg": "Installer (kann weg?)/Treiber.pkg",
            "Urlaub.zip": "Archive/Urlaub.zip",
            "Lied.mp3": "Musik/Lied.mp3",
            "Clip.mov": "Videos/Clip.mov",
            "daten.xyz": "Sonstiges/daten.xyz",
            "Rechnung (1).pdf": "Papierkorb",   // identical copy: to the Trash, the clean name stays
        ]
        let copy = plan.ops.first { $0.source?.lastPathComponent == "Rechnung (1).pdf" }
        return placed == expected && copy?.kind == .trash && copy?.reason.contains("Rechnung.pdf") == true && Set(plan.later.map(\.lastPathComponent)) == ["liste.txt", "Rechnung.pdf"] && plan.skipped.isEmpty && plan.pending.isEmpty && plan.remaining.isEmpty
            && plan.ops.allSatisfy { $0.certainty == .sure } && asked.count == 2
    }

    await checkAsync("Pre-sort: preview appears immediately (documents still open), then grows, deselections stay valid") {
        let plans = updates.all
        guard let first = plans.first, let last = plans.last, plans.count >= 2 else { return false }
        let firstNames = Set(first.ops.compactMap { $0.source?.lastPathComponent })
        let logo = { (p: Plan) in p.ops.first { $0.source?.lastPathComponent == "logo.png" }?.id }
        return Set(first.pending.map(\.lastPathComponent)) == ["liste.txt", "Rechnung.pdf"]
            && firstNames.contains("logo.png") && firstNames.contains("Rechnung (1).pdf") && !firstNames.contains("Rechnung.pdf")
            && last.pending.isEmpty && logo(first) != nil && logo(first) == logo(last)
    }

    await checkAsync("Pre-sort: approve and undo restore everything (installers, duplicates, photos, new folders)") {
        let before = tree(downloads)
        let plan = try await engine.proposeSort(folder: downloads)
        let receipt = try await engine.apply(plan, excluding: [])
        let moved = tree(downloads)
        try await engine.undo(receipt)
        if tree(downloads) != before { print("   Difference: \(tree(downloads).symmetricDifference(before).sorted())") }
        if !receipt.stayed.isEmpty { print("   Stayed in place: \(receipt.stayed)") }
        return moved != before && moved.contains("Installer (kann weg?)/Firefox 140.dmg") && !moved.contains("Rechnung (1).pdf")
            && moved.contains("Rechnung.pdf") && !moved.contains(where: { $0.hasPrefix("Doppelt") })
            && receipt.stayed.isEmpty && tree(downloads) == before
    }

    await checkAsync("Duplicates: whole-content hash, the clean or older name stays, browser copies \"Name (1).ext\" found") {
        let folder = dir("Doppelte")
        // The browser copy arrived first (older), the clean name later: the clean name stays anyway.
        write("Kontoauszug März", folder.appendingPathComponent("Auszug (1).txt"))
        try await Task.sleep(for: .milliseconds(1100))
        write("Kontoauszug März", folder.appendingPathComponent("Auszug.txt"))
        // Two plain names, same content: the older stays.
        write("Foto-Rohdaten 1234", folder.appendingPathComponent("aaa.dat"))
        try await Task.sleep(for: .milliseconds(1100))
        write("Foto-Rohdaten 1234", folder.appendingPathComponent("bbb.dat"))
        // Same size and name pattern, different content: no duplicate.
        write("Rechnung Nummer 01", folder.appendingPathComponent("Beleg.txt"))
        write("Rechnung Nummer 02", folder.appendingPathComponent("Beleg Kopie.txt"))
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let copies = Dictionary(uniqueKeysWithValues: PreSort.duplicates(in: urls).map { ($0.key.lastPathComponent, $0.value.lastPathComponent) })
        print("   \(copies)")
        let names = ["Rechnung (1).pdf", "Rechnung-1.pdf", "Rechnung Kopie.pdf", "Rechnung copy 2.pdf", "Rechnung copy.pdf"]
        return copies == ["Auszug (1).txt": "Auszug.txt", "bbb.dat": "aaa.dat"]
            && names.allSatisfy(PreSort.looksLikeCopy)
            && !["Rechnung.pdf", "Rechnung 2024.pdf", "Scan (Seite).pdf", "Kopierer.pdf"].contains(where: PreSort.looksLikeCopy)
    }

    await checkAsync("First sort: an everyday folder in one go, only a folder above \(PreSort.firstRunLimit) files leaves the oldest for \"Sort more\"") {
        let limit = PreSort.firstRunLimit
        // An everyday folder (well below the limit): everything in the first round, nothing left over.
        let everyday = dir("Alltag")
        for i in 0..<40 { write("datei \(i)", everyday.appendingPathComponent("paket-\(i).zip")) }
        let whole = try await engine.proposeSort(items: nil, scope: everyday, limit: limit) { _ in }
        // A really big folder: the newest `limit` first, the 5 oldest for the second round.
        let many = dir("Viele")
        for i in 0..<5 { write("alt \(i)", many.appendingPathComponent("alt-\(i).zip")) }
        // The system sets \"Date Added\" on creation; one second later the new ones are clearly newer.
        try await Task.sleep(for: .milliseconds(1100))
        for i in 0..<limit { write("neu \(i)", many.appendingPathComponent("neu-\(i).zip")) }
        let plan = try await engine.proposeSort(items: nil, scope: many, limit: limit) { _ in }
        let rest = try await engine.proposeSort(items: plan.remaining, scope: many, limit: nil) { _ in }
        let sources = Set(plan.ops.compactMap { $0.source?.lastPathComponent })
        return limit >= 300 && whole.remaining.isEmpty && whole.ops.filter { $0.kind == .move }.count == 40
            && plan.remaining.map(\.lastPathComponent).sorted() == (0..<5).map { "alt-\($0).zip" }
            && sources.count == limit && sources.allSatisfy { $0.hasPrefix("neu-") }
            && rest.remaining.isEmpty && rest.ops.filter { $0.kind == .move }.count == 5
    }

    await checkAsync("Pre-sort: 300 files without a model") {
        let big = dir("Dreihundert")
        for i in 0..<300 {
            switch i % 6 {
            case 0: makeImage(at: big.appendingPathComponent("bild-\(i).png"), type: .png)
            case 1: write("installer \(i)", big.appendingPathComponent("app-\(i).dmg"))
            case 2: write("archiv \(i)", big.appendingPathComponent("paket-\(i).zip"))
            case 3: write("Notiz \(i): bitte Blumen gießen", big.appendingPathComponent("notiz-\(i).txt"))
            case 4: makePDF([invoiceText.replacingOccurrences(of: "84,20", with: "\(i),00")], at: big.appendingPathComponent("rechnung-\(i).pdf"))
            default: write("musik \(i)", big.appendingPathComponent("lied-\(i).mp3"))
            }
        }
        let start = Date()
        let askedBefore = asked.count
        let progress = Updates()
        let plan = try await engine.proposeSort(items: nil, scope: big, limit: nil) { progress.add($0) }
        let total = Date().timeIntervalSince(start)
        let first = progress.first.map { $0.timeIntervalSince(start) } ?? total
        print(String(format: "   first preview after %.2f s, done after %.2f s (%.0f ms per file)", first, total, total * 1000 / 300))
        print("   steps: \(plan.ops.filter { $0.kind != .mkdir }.count), later: \(plan.later.count), skipped: \(plan.skipped.count), model calls: \(asked.count - askedBefore)")
        return plan.ops.filter { $0.kind != .mkdir }.count == 200 && plan.later.count == 100 && plan.pending.isEmpty && first < 3 && total < 20 && asked.count - askedBefore == 100
    }

    await runSortWithoutModelChecks()
}

/// First launch: the knowledge is still loading (no model, no server). Sorting works anyway; whatever only the model could settle
/// stays in place (`Plan.later`), nothing is guessed, nothing hangs, no error.
func runSortWithoutModelChecks() async {
    let folder = dir("Ohne Modell")
    makeImage(at: folder.appendingPathComponent("logo.png"), type: .png)
    write("dmg", folder.appendingPathComponent("Firefox 140.dmg"))
    makePDF([invoiceText], at: folder.appendingPathComponent("Rechnung.pdf"))
    write("Einkaufsliste: Milch, Brot, Äpfel", folder.appendingPathComponent("liste.txt"))
    // A kind (\"offer\") but no sender: the destination is only clear with a model.
    write("Angebot\nFür die Renovierung der Küche bieten wir an: Fliesen, Arbeit, Material.", folder.appendingPathComponent("Angebot Küche.txt"))
    let engine = LocalEngine(baseDirectory: dir("support-ohne-modell"), modelEnabled: false)
    let updates = Updates()

    await checkAsync("Without model: sorting runs, unclear items stay in place (\"more precisely later\"), nothing guessed") {
        let status = await engine.modelStatus
        let start = Date()
        let plan = try await engine.proposeSort(items: nil, scope: folder, limit: PreSort.firstRunLimit) { updates.add($0) }
        let seconds = Date().timeIntervalSince(start)
        let sources = Set(plan.ops.compactMap { $0.source?.lastPathComponent })
        if status == .ready { print("   Model state unexpected: ready") }
        return Set(plan.later.map(\.lastPathComponent)) == ["Angebot Küche.txt", "Rechnung.pdf", "liste.txt"]
            && sources == ["logo.png", "Firefox 140.dmg"]
            && plan.pending.isEmpty && plan.skipped.isEmpty && seconds < 10
            && Set(updates.all.last?.later.map(\.lastPathComponent) ?? []) == ["Angebot Küche.txt", "Rechnung.pdf", "liste.txt"]
    }

    await checkAsync("Without model: approving leaves the document for later untouched, undo restores everything") {
        let before = tree(folder)
        let plan = try await engine.proposeSort(items: nil, scope: folder, limit: nil) { _ in }
        let receipt = try await engine.apply(plan, excluding: [])
        let after = tree(folder)
        try await engine.undo(receipt)
        return after.contains("Angebot Küche.txt") && after.contains("Bilder/logo.png") && tree(folder) == before
    }

    await checkAsync("Model does not answer (replay empty): document stays in place instead of a \"please check\" guess") {
        let silent = LocalEngine(baseDirectory: dir("support-ohne-antwort"), modelEnabled: false)
        let asked = Asked()
        await silent.setModelReplay { _, user in asked.add(user); return nil }
        let plan = try await silent.proposeSort(items: nil, scope: folder, limit: nil) { _ in }
        return Set(plan.later.map(\.lastPathComponent)) == ["Angebot Küche.txt", "Rechnung.pdf", "liste.txt"] && asked.names(of: ["Angebot Küche.txt"]) == ["Angebot Küche.txt"]
            && !plan.ops.contains { $0.source?.lastPathComponent == "Angebot Küche.txt" }
    }

    await checkAsync("Sample engine without knowledge: Word document waits, rest appears in the preview") {
        let stub = StubEngine(delay: 0.01, status: .notInstalled)
        let plan = try await stub.proposeSort(items: nil, scope: folder, limit: nil) { _ in }
        return plan.later.count == 1 && plan.later[0].pathExtension == "docx"
            && !plan.ops.contains { $0.source?.pathExtension == "docx" } && plan.ops.contains { $0.kind == .move }
    }
}
