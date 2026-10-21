import Foundation
import ImageIO
import PDFKit
import PippaCore
import UniformTypeIdentifiers

/// Frozen synthetic pages, independent of user files, accounts and model availability.
func runFilePreparationChecks() async {
    let folder = dir("file-preparation")
    let results = dir("file-preparation-results")
    setenv("PIPPA_RESULTS_DIR", results.path, 1)
    let first = dir("file-preparation-first").appendingPathComponent("Document.pdf")
    let second = dir("file-preparation-second").appendingPathComponent("Document.pdf")
    let rotated = folder.appendingPathComponent("Rotated.pdf")
    makePDF(["First source page one", "First source page two"], at: first)
    makePDF(["Second source page"], at: second)
    makePDF(["Rotated source page"], at: rotated)
    if let document = PDFDocument(url: rotated), let page = document.page(at: 0) {
        page.rotation = 90
        _ = document.write(to: rotated)
    }
    let shapes: [(String, Int, Int, Int?)] = [("Square.png", 400, 400, nil), ("Portrait.jpg", 400, 700, nil),
                                            ("Landscape.jpg", 700, 400, nil), ("EXIF.jpg", 700, 400, 6)]
    var photos: [URL] = []
    for (name, width, height, orientation) in shapes {
        let url = folder.appendingPathComponent(name)
        ToolFixtures.writeImage(ToolFixtures.textImage([name, "PREPARATION"], width: width, height: height),
                                type: name.hasSuffix("png") ? .png : .jpeg, to: url, orientation: orientation)
        photos.append(url)
    }
    let fixtures = [first, second, rotated] + photos
    let originals = fixtures.map { ToolFixtures.identity($0) }

    check("File preparation: bounded native choices round-trip without passwords") {
        let plan = FilePreparationPlan(quality: .balanced, sizeGoal: .tenMB)
        let data = try JSONEncoder().encode(plan)
        return try JSONDecoder().decode(FilePreparationPlan.self, from: data) == plan
            && FilePreparation.accepts(fixtures) && !FilePreparation.accepts([])
            && !FilePreparation.accepts(Array(repeating: first, count: 51))
            && !FilePreparation.accepts([folder.appendingPathComponent("movie.gif")])
            && !String(decoding: data, as: UTF8.self).contains("password")
    }

    await checkAsync("File preparation: same-named PDFs preserve explicit order and every text page") {
        let sources = try [second, first].map(FilePreparationSource.capture)
        let output = try await FilePreparation.run(sources: sources, plan: .init())
        guard let file = output.files.first, let document = PDFDocument(url: file) else { return false }
        return output.consumedInputs == [second, first] && output.skipped.isEmpty && document.pageCount == 3
            && document.page(at: 0)?.string?.contains("Second source page") == true
            && document.page(at: 1)?.string?.contains("First source page one") == true
            && document.page(at: 2)?.string?.contains("First source page two") == true
            && output.note?.contains(ByteCountFormatter.string(fromByteCount: ToolFixtures.size(file), countStyle: .file)) == true
    }

    await checkAsync("File preparation: square, portrait, landscape and EXIF rotation pass visual readback") {
        let output = try await FilePreparation.run(sources: photos.map(FilePreparationSource.capture), plan: .init())
        guard let file = output.files.first, let document = PDFDocument(url: file), document.pageCount == 4 else { return false }
        let boxes = (0..<4).compactMap { document.page(at: $0)?.bounds(for: .mediaBox) }
        return boxes.count == 4 && abs(boxes[0].width - boxes[0].height) < 1
            && boxes[1].height > boxes[1].width && boxes[2].width > boxes[2].height && boxes[3].height > boxes[3].width
    }

    await checkAsync("File preparation: mixed scan and rotated text retain order, page count and rotation") {
        let inputs = [photos[0], rotated, first]
        let output = try await FilePreparation.run(sources: inputs.map(FilePreparationSource.capture), plan: .init(quality: .balanced))
        guard let file = output.files.first, let document = PDFDocument(url: file), let page = document.page(at: 1) else { return false }
        return document.pageCount == 4 && page.string?.contains("Rotated source page") == true
            && document.page(at: 2)?.string?.contains("First source page one") == true
    }

    await checkAsync("File preparation: changed input after preview is rejected, without a result") {
        let changed = folder.appendingPathComponent("Changed.pdf")
        makePDF(["Before"], at: changed)
        let source = try FilePreparationSource.capture(changed)
        makePDF(["After"], at: changed)
        let before = (try? fm.contentsOfDirectory(atPath: results.path).count) ?? 0
        do { _ = try await FilePreparation.run(sources: [source], plan: .init()); return false }
        catch FilePreparationFailure.changed(let name) {
            return name == changed.lastPathComponent && ((try? fm.contentsOfDirectory(atPath: results.path).count) ?? 0) == before
        }
    }

    await checkAsync("File preparation: unreadable source fails the whole request without silently dropping a page") {
        let bad = folder.appendingPathComponent("Unreadable.pdf")
        write("not a PDF", bad)
        let before = (try? fm.contentsOfDirectory(atPath: results.path).count) ?? 0
        do { _ = try await FilePreparation.run(sources: [first, bad].map(FilePreparationSource.capture), plan: .init()); return false }
        catch ToolFailure.unreadable(let name) {
            return name == bad.lastPathComponent && ((try? fm.contentsOfDirectory(atPath: results.path).count) ?? 0) == before
        }
    }

    await checkAsync("File preparation: a deleted persisted input cannot be resumed") {
        let removed = folder.appendingPathComponent("Removed.pdf")
        makePDF(["Temporary"], at: removed)
        let data = try JSONEncoder().encode(FilePreparationSource.capture(removed))
        try fm.removeItem(at: removed)
        let restored = try JSONDecoder().decode(FilePreparationSource.self, from: data)
        do { _ = try await FilePreparation.run(sources: [restored], plan: .init()); return false }
        catch FilePreparationFailure.changed { return true }
    }

    await checkAsync("File preparation: stop at the first progress event leaves no partial output") {
        let sources = try [first, second].map(FilePreparationSource.capture)
        let before = (try? fm.contentsOfDirectory(atPath: results.path).count) ?? 0
        let task = Task {
            try await FilePreparation.run(sources: sources, plan: .init()) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { _ = try await task.value; return false }
        catch is CancellationError { return ((try? fm.contentsOfDirectory(atPath: results.path).count) ?? 0) == before }
    }

    await checkAsync("File preparation: an unreachable size limit returns the actual verified size honestly") {
        let large = folder.appendingPathComponent("Large scan.pdf")
        ToolFixtures.noisePDF(pages: 3, at: large)
        let output = try await FilePreparation.run(sources: [FilePreparationSource.capture(large)],
                                                  plan: .init(quality: .original, sizeGoal: .fiveMB))
        guard let file = output.files.first else { return false }
        let goal = ByteCountFormatter.string(fromByteCount: 5_000_000, countStyle: .file)
        return ToolFixtures.size(file) > 5_000_000 && PDFDocument(url: file)?.pageCount == 3
            && output.note?.contains(L("The %@ limit wasn’t reached at this quality. This is the verified result; try a smaller batch or a lower quality.", table: "FilePreparation", goal)) == true
    }

    await checkAsync("File preparation: an achievable limit and smaller quality keep text searchable") {
        let output = try await FilePreparation.run(sources: [FilePreparationSource.capture(first)],
                                                  plan: .init(quality: .compact, sizeGoal: .fiveMB))
        guard let file = output.files.first, let document = PDFDocument(url: file) else { return false }
        let goal = ByteCountFormatter.string(fromByteCount: 5_000_000, countStyle: .file)
        return ToolFixtures.size(file) < 5_000_000 && document.pageCount == 2
            && document.string?.contains("First source page two") == true
            && output.note?.contains(L("Within your %@ size limit.", table: "FilePreparation", goal)) == true
    }

    await checkAsync("File preparation: locked PDFs require an ephemeral password each new run") {
        let locked = folder.appendingPathComponent("Locked.pdf")
        ToolFixtures.lockedPDF(["Private synthetic fixture"], password: "ephemeral", at: locked)
        let sources = try [locked].map(FilePreparationSource.capture)
        do { _ = try await FilePreparation.run(sources: sources, plan: .init()); return false }
        catch ToolFailure.locked { }
        let output = try await FilePreparation.run(sources: sources, plan: .init(), passwords: [locked: "ephemeral"])
        let saved = try JSONEncoder().encode(sources)
        return output.files.count == 1 && !String(decoding: saved, as: UTF8.self).contains("ephemeral")
    }

    await checkAsync("File preparation: smaller quality retains link annotations instead of dropping them") {
        let annotated = folder.appendingPathComponent("Annotated.pdf")
        makePDF(["A document with a useful link"], at: annotated)
        guard let document = PDFDocument(url: annotated), let page = document.page(at: 0) else { return false }
        let link = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 120, height: 30), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com/pippa-fixture")
        page.addAnnotation(link)
        guard document.write(to: annotated) else { return false }
        let before = ToolFixtures.identity(annotated)
        let output = try await FilePreparation.run(sources: [FilePreparationSource.capture(annotated)],
                                                  plan: .init(quality: .compact, sizeGoal: .fiveMB))
        guard let file = output.files.first, let restored = PDFDocument(url: file) else { return false }
        return restored.page(at: 0)?.annotations.contains { $0.url == link.url } == true
            && ToolFixtures.identity(annotated).sha == before.sha
    }

    check("File preparation: original bytes and metadata stay unchanged") {
        zip(fixtures, originals).allSatisfy { url, before in
            let after = ToolFixtures.identity(url)
            return before.sha == after.sha && before.fingerprint?.matches(after.fingerprint) == true
        }
    }

    await checkAsync("File preparation: Undo preserves a durable PDF edited after preparation, including after reopening the journal") {
        let support = dir("file-preparation-edited-undo")
        let store = try DurableJobStore(baseDirectory: support)
        let job = try await store.create(kind: .filePreparation, requestKey: "edited-undo", title: "Fixture")
        let run = try await store.start(id: job.id, expectedRevision: job.revision)
        let artifact = try await store.retainArtifact(from: first, run: run)
        let journal = try Executor(baseDirectory: support)
        let receipt = try await journal.recordResult([artifact.url], summary: "Fixture", detail: "")
        makePDF(["Edited after preparation", "The person's additional page stays"], at: artifact.url)
        let edited = try Data(contentsOf: artifact.url)
        let reopened = try Executor(baseDirectory: support)
        let report = try await reopened.undo(jobID: receipt.id)
        let preserved = try Data(contentsOf: artifact.url)
        return report.restored == 0 && report.conflicts.count == 1
            && report.conflicts.first?.url == artifact.url
            && preserved == edited
    }

    await checkAsync("File preparation: Undo removes an unchanged owned durable PDF and keeps its original") {
        let support = dir("file-preparation-unchanged-undo")
        let store = try DurableJobStore(baseDirectory: support)
        let job = try await store.create(kind: .filePreparation, requestKey: "unchanged-undo", title: "Fixture")
        let run = try await store.start(id: job.id, expectedRevision: job.revision)
        let artifact = try await store.retainArtifact(from: second, run: run)
        let original = try DurableFileIdentity.capture(second)
        let journal = try Executor(baseDirectory: support)
        let receipt = try await journal.recordResult([artifact.url], summary: "Fixture", detail: "")
        let report = try await journal.undo(jobID: receipt.id)
        let preserved = try DurableFileIdentity.capture(second)
        return report.restored == 1 && report.conflicts.isEmpty
            && !fm.fileExists(atPath: artifact.url.path)
            && !fm.fileExists(atPath: artifact.url.deletingLastPathComponent().path)
            && preserved == original
    }
}
