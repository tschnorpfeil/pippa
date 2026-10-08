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
            op.source.map { ($0.lastPathComponent, op.target.path.replacingOccurrences(of: downloads.path + "/", with: "")) }
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
            "Rechnung (1).pdf": "Doppelt/Rechnung (1).pdf",
        ]
        return placed == expected && Set(plan.later.map(\.lastPathComponent)) == ["liste.txt", "Rechnung.pdf"] && plan.skipped.isEmpty && plan.pending.isEmpty && plan.remaining.isEmpty
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
        return moved != before && moved.contains("Installer (kann weg?)/Firefox 140.dmg") && moved.contains("Doppelt/Rechnung (1).pdf")
            && receipt.stayed.isEmpty && tree(downloads) == before
    }

    await checkAsync("First sort: only the 30 newest, the rest stay for \"Sort more\"") {
        let many = dir("Viele")
        for i in 0..<5 { write("alt \(i)", many.appendingPathComponent("alt-\(i).zip")) }
        // The system sets \"Date Added\" on creation; one second later the new ones are clearly newer.
        try await Task.sleep(for: .milliseconds(1100))
        for i in 0..<30 { write("neu \(i)", many.appendingPathComponent("neu-\(i).zip")) }
        let plan = try await engine.proposeSort(items: nil, scope: many, limit: 30) { _ in }
        let rest = try await engine.proposeSort(items: plan.remaining, scope: many, limit: nil) { _ in }
        let sources = Set(plan.ops.compactMap { $0.source?.lastPathComponent })
        return plan.remaining.map(\.lastPathComponent).sorted() == (0..<5).map { "alt-\($0).zip" }
            && sources.count == 30 && sources.allSatisfy { $0.hasPrefix("neu-") }
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
