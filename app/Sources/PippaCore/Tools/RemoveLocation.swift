import Foundation
import ImageIO

/// A fresh PNG made only from upright pixels. No source EXIF, GPS, IPTC, XMP or auxiliary images are copied.
/// PNG preserves decoded pixels, transparency and their display color profile. This removes location/camera tags,
/// not visible location clues or arbitrary information in a custom color profile. The original stays unchanged.
enum RemoveLocation {
    static func run(_ inputs: [URL], progress: @escaping @Sendable (ToolProgress) -> Void) async throws -> ToolOutput {
        var output = try await ToolRun.eachFile(.removeLocation, inputs: inputs,
            skipWhy: L("I can only remove location from photos.", table: "Tools"), progress: progress) { url, folder in
            try Task.checkCancellation()
            try NativeFileLimits.check(url)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ToolFailure.unreadable(name: url.lastPathComponent) }
            try NativeFileLimits.checkImage(source, url: url)
            guard let image = ToolImages.fullImage(source) else { throw ToolFailure.unreadable(name: url.lastPathComponent) }
            try Task.checkCancellation()
            let temp = ResultFile.temp(in: folder)
            defer { try? FileManager.default.removeItem(at: temp) }
            try ToolImages.write(image, type: .png, properties: [:], to: temp)
            guard let result = CGImageSourceCreateWithURL(temp as CFURL, nil), CGImageSourceGetCount(result) == 1 else {
                throw ToolFailure.unreadable(name: url.lastPathComponent)
            }
            let properties = ToolImages.properties(result)
            for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
                guard properties[key as String] == nil else { throw ToolFailure.unreadable(name: url.lastPathComponent) }
            }
            // ImageIO synthesizes these three EXIF values from the new pixels. Every other EXIF/IPTC/XMP tag,
            // including arbitrary XMP namespaces and iio:hasXMP, makes verification fail closed.
            // The image's color profile is separate from this tag tree and is retained for faithful display.
            if let metadata = CGImageSourceCopyMetadataAtIndex(result, 0, nil),
               let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] {
                for tag in tags {
                    let namespace = CGImageMetadataTagCopyNamespace(tag) as String? ?? ""
                    let name = CGImageMetadataTagCopyName(tag) as String? ?? ""
                    guard namespace == kCGImageMetadataNamespaceExif as String,
                          ["PixelXDimension", "PixelYDimension", "ColorSpace"].contains(name) else {
                        throw ToolFailure.unreadable(name: url.lastPathComponent)
                    }
                }
            }
            try Task.checkCancellation()
            return try ResultFile.place(temp, as: ResultNaming.name(for: .removeLocation, inputs: [url]), in: folder)
        }
        output.note = L("New PNG copies without location or camera metadata. The originals are unchanged.", table: "Tools")
        return output
    }
}

/// Bound native decoding before allocating a full image. Multi-frame sources are rejected, never silently flattened.
public enum NativeFileLimits {
    public static let bytes: Int64 = 200_000_000
    public static let pixels: Int64 = 60_000_000
    public static let pages = 200
    public static let textBytes = 2_000_000

    static func check(_ url: URL) throws {
        if FileFacts.isCloudPlaceholder(url) {
            throw ToolFailure.cannotProcess(name: url.lastPathComponent, reason: L("Download this file to the Mac first.", table: "Tools"))
        }
        guard ToolFiles.size(url) <= bytes else {
            throw ToolFailure.cannotProcess(name: url.lastPathComponent, reason: L("This file exceeds the 200 MB limit. Nothing was exported.", table: "Tools"))
        }
    }

    static func checkImage(_ source: CGImageSource, url: URL) throws {
        guard CGImageSourceGetCount(source) == 1 else {
            throw ToolFailure.cannotProcess(name: url.lastPathComponent, reason: L("This image has multiple frames or pages. Export a single image first.", table: "Tools"))
        }
        let properties = ToolImages.properties(source)
        let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.int64Value ?? 0
        let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.int64Value ?? 0
        guard width > 0, height > 0, width <= pixels, height <= pixels, width <= pixels / height else {
            throw ToolFailure.cannotProcess(name: url.lastPathComponent, reason: L("This image exceeds the 60 megapixel limit or has invalid dimensions.", table: "Tools"))
        }
    }
}
