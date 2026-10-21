import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import PippaCore
import UniformTypeIdentifiers

func runNativeToolChecks() async {
    let folder = dir("native-tools")
    let photo = folder.appendingPathComponent("Location.jpg")
    let pdf = folder.appendingPathComponent("Letter.pdf")
    let locked = folder.appendingPathComponent("Locked.pdf")
    let broken = folder.appendingPathComponent("Broken.jpg")
    let frames = folder.appendingPathComponent("Pages.tiff")
    let large = folder.appendingPathComponent("Too large.pdf")
    let many = folder.appendingPathComponent("Many pages.pdf")
    let xmp = folder.appendingPathComponent("Hidden location.jpg")
    let image = ToolFixtures.textImage(["Pippa 4711", "Invoice 84.20"], width: 1200, height: 1600)!
    let dest = CGImageDestinationCreateWithURL(photo as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 52.52, kCGImagePropertyGPSLatitudeRef: "N",
                                       kCGImagePropertyGPSLongitude: 13.405, kCGImagePropertyGPSLongitudeRef: "E"],
        kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCity: "Fixture City", kCGImagePropertyIPTCSubLocation: "Fixture Street"],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Fixture location"],
    ] as CFDictionary)
    let wrote = CGImageDestinationFinalize(dest)
    let metadata = CGImageMetadataCreateMutable()
    let registered = CGImageMetadataRegisterNamespaceForPrefix(metadata, "https://pippa.test/fixture/" as CFString, "pippaFixture" as CFString, nil)
    let tagged = CGImageMetadataSetValueWithPath(metadata, nil, "pippaFixture:Location" as CFString, "Fixture hidden location" as CFString)
    let xmpDestination = CGImageDestinationCreateWithURL(xmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImageAndMetadata(xmpDestination, image, metadata, nil)
    let wroteXMP = CGImageDestinationFinalize(xmpDestination)
    makePDF(["First page: 84.20 EUR.", "Last page: nothing omitted."], at: pdf)
    ToolFixtures.lockedPDF(["Protected fixture."], password: "pw", at: locked)
    write("not an image", broken)
    let multi = CGImageDestinationCreateWithURL(frames as CFURL, UTType.tiff.identifier as CFString, 2, nil)!
    CGImageDestinationAddImage(multi, image, nil); CGImageDestinationAddImage(multi, image, nil)
    let wroteFrames = CGImageDestinationFinalize(multi)
    makePDF(Array(repeating: "Fixture page.", count: NativeFileLimits.pages + 1), at: many)
    fm.createFile(atPath: large.path, contents: Data())
    if let handle = try? FileHandle(forWritingTo: large) { try? handle.truncate(atOffset: UInt64(NativeFileLimits.bytes + 1)); try? handle.close() }
    let original = ToolFixtures.identity(photo)
    func resultFolders() -> Set<String> { Set((try? fm.contentsOfDirectory(atPath: ResultsFolder.directory.path)) ?? []) }
    func rejection(_ tool: ToolID, _ file: URL) async -> String? {
        do { _ = try await OneAnswerTools.run(tool, inputs: [file]); return nil }
        catch { return error.localizedDescription }
    }

    check("Native tools: photo fixture really contains location and multiple-image fixture has two pages") {
        let src = CGImageSourceCreateWithURL(photo as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        return wrote && wroteFrames && props?[kCGImagePropertyGPSDictionary as String] != nil
            && props?[kCGImagePropertyIPTCDictionary as String] != nil
            && OneAnswerTools.accepts(.extractText, pdf) && OneAnswerTools.accepts(.extractText, photo)
            && OneAnswerTools.accepts(.removeLocation, photo) && !OneAnswerTools.accepts(.removeLocation, pdf)
    }
    await checkAsync("Remove location: new upright PNG without GPS or camera tags, unique outputs and original unchanged") {
        let first = try await OneAnswerTools.run(.removeLocation, inputs: [photo, photo])
        let again = try await OneAnswerTools.run(.removeLocation, inputs: [photo])
        guard first.files.count == 2, let file = first.files.first, let second = again.files.first,
              let src = CGImageSourceCreateWithURL(file as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return false }
        let pixels = ToolFixtures.pixelSize(file)
        return Set(first.files + again.files).count == 3 && file != second && first.consumedInputs == [photo, photo]
            && ResultsFolder.contains(file) && ToolFixtures.imageType(file) == UTType.png.identifier
            && pixels.width == 1600 && pixels.height == 1200 && pixels.orientation == 1
            && props[kCGImagePropertyGPSDictionary as String] == nil && props[kCGImagePropertyIPTCDictionary as String] == nil
            && Set((props[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]).keys)
                .isSubset(of: ["ColorSpace", "PixelXDimension", "PixelYDimension"])
            && ToolFixtures.identity(photo).sha == original.sha && first.note != nil
    }
    await checkAsync("Remove location: custom-namespace XMP location is present in the fixture and absent in the copy") {
        guard registered, tagged, wroteXMP, let source = CGImageSourceCreateWithURL(xmp as CFURL, nil),
              let before = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              CGImageMetadataCopyStringValueWithPath(before, nil, "pippaFixture:Location" as CFString) as String? == "Fixture hidden location" else { return false }
        let output = try await OneAnswerTools.run(.removeLocation, inputs: [xmp])
        guard let copy = CGImageSourceCreateWithURL(output.files[0] as CFURL, nil) else { return false }
        guard let after = CGImageSourceCopyMetadataAtIndex(copy, 0, nil), let tags = CGImageMetadataCopyTags(after) as? [CGImageMetadataTag] else { return true }
        return tags.allSatisfy {
            CGImageMetadataTagCopyNamespace($0) as String? == kCGImageMetadataNamespaceExif as String
                && ["ColorSpace", "PixelXDimension", "PixelYDimension"].contains(CGImageMetadataTagCopyName($0) as String? ?? "")
        }
    }
    await checkAsync("Extract text: all PDF pages are present, source and method explicit, results unique") {
        let output = try await OneAnswerTools.run(.extractText, inputs: [pdf, pdf])
        guard output.files.count == 2, Set(output.files).count == 2 else { return false }
        let text = try String(contentsOf: output.files[0], encoding: .utf8)
        return text.contains("First page: 84.20 EUR.") && text.contains("Last page: nothing omitted.")
            && text.contains("Letter.pdf") && text.contains(L("Embedded PDF text", table: "Tools"))
            && output.files.allSatisfy { $0.pathExtension == "txt" && ResultsFolder.contains($0) }
            && output.consumedInputs == [pdf, pdf] && output.note != nil
    }
    await checkAsync("Remove location: transparency survives the location-free copy") {
        let transparent = folder.appendingPathComponent("Transparent.png")
        guard let context = CGContext(data: nil, width: 24, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              ToolFixtures.writeImage(context.makeImage(), type: .png, to: transparent) else { return false }
        let output = try await OneAnswerTools.run(.removeLocation, inputs: [transparent])
        guard let source = CGImageSourceCreateWithURL(output.files[0] as CFURL, nil),
              let copy = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let sample = CGContext(data: nil, width: 24, height: 24, bitsPerComponent: 8, bytesPerRow: 24 * 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        sample.draw(copy, in: CGRect(x: 0, y: 0, width: 24, height: 24))
        return sample.data?.load(fromByteOffset: 3, as: UInt8.self) == 0
    }
    await checkAsync("Extract text: photo OCR is labelled and preserves recognizable fixture text") {
        let upright = folder.appendingPathComponent("Readable.png")
        guard ToolFixtures.writeImage(image, type: .png, to: upright) else { return false }
        let output = try await OneAnswerTools.run(.extractText, inputs: [upright])
        let text = try String(contentsOf: output.files[0], encoding: .utf8)
        return text.contains("4711") && text.contains(L("Recognized from image (OCR; please check)", table: "Tools"))
    }
    await checkAsync("Extract text: mixed PDF keeps native text, OCR page text and an explicit blank-page marker") {
        let mixed = folder.appendingPathComponent("Mixed.pdf")
        let scanned = folder.appendingPathComponent("Scan.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 450, height: 600)
        guard let canvas = CGContext(scanned as CFURL, mediaBox: &bounds, nil) else { return false }
        canvas.beginPDFPage(nil); canvas.draw(image, in: bounds); canvas.endPDFPage()
        canvas.closePDF()
        guard let document = PDFDocument(url: pdf), let scan = PDFDocument(url: scanned)?.page(at: 0),
              let scanCopy = scan.copy() as? PDFPage else { return false }
        document.removePage(at: 1)
        document.insert(scanCopy, at: 1)
        let blank = PDFPage(); blank.setBounds(bounds, for: .mediaBox)
        document.insert(blank, at: 2)
        guard document.write(to: mixed) else { return false }
        let output = try await OneAnswerTools.run(.extractText, inputs: [mixed])
        let text = try String(contentsOf: output.files[0], encoding: .utf8)
        return text.contains("First page: 84.20 EUR.") && text.contains("4711")
            && text.contains(L("Embedded PDF text", table: "Tools"))
            && text.contains(L("Page %lld — %@", table: "Tools", 3, L("Recognized from image (OCR; please check)", table: "Tools")))
            && text.contains(L("No readable text was recognized on this page.", table: "Tools"))
    }
    await checkAsync("Extract text: blank images return an explicit no-text reason without a misleading empty artifact") {
        let blank = folder.appendingPathComponent("Blank.png")
        guard ToolFixtures.writeImage(ToolFixtures.textImage([], width: 400, height: 400), type: .png, to: blank) else { return false }
        let before = resultFolders()
        let reason = await rejection(.extractText, blank)
        return reason?.contains(L("No readable text was found. No text file was created.", table: "Tools")) == true
            && resultFolders() == before
    }
    await checkAsync("Extract text: protected PDF asks for password, wrong password fails, correct password exports") {
        do { _ = try await OneAnswerTools.run(.extractText, inputs: [locked]); return false }
        catch ToolFailure.locked(let url) { guard url == locked else { return false } }
        do { _ = try await OneAnswerTools.run(.extractText, inputs: [locked], passwords: [locked: "wrong"]); return false }
        catch ToolFailure.wrongPassword { }
        let output = try await OneAnswerTools.run(.extractText, inputs: [locked], passwords: [locked: "pw"])
        return try String(contentsOf: output.files[0], encoding: .utf8).contains("Protected fixture.")
    }
    await checkAsync("Native tools: unreadable, oversized, too many pages and multi-frame inputs leave no partial artifacts") {
        let before = resultFolders()
        guard await rejection(.removeLocation, broken) != nil,
              await rejection(.extractText, large)?.contains("200 MB") == true,
              await rejection(.extractText, many)?.contains("200") == true,
              await rejection(.removeLocation, frames) != nil,
              await rejection(.extractText, frames) != nil else { return false }
        return resultFolders() == before
    }
    await checkAsync("Native tools: cancellation after the first completed file removes the entire run") {
        for (tool, file) in [(ToolID.extractText, pdf), (.removeLocation, photo)] {
            let before = resultFolders()
            let task = Task {
                try await OneAnswerTools.run(tool, inputs: [file, file]) { progress in
                    if progress.done == 1 { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            do { _ = try await task.value; return false }
            catch is CancellationError { }
            guard resultFolders() == before else { return false }
        }
        return ToolFixtures.identity(photo).sha == original.sha
    }
}
