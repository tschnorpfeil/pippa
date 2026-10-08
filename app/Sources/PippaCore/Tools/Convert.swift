import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// "As JPG" / "As PNG" / "As PDF": one file per image, full size, upright (EXIF applied), first image only.
enum Convert {
    static func run(_ tool: ToolID, inputs: [URL], progress: @escaping @Sendable (ToolProgress) -> Void) async throws -> ToolOutput {
        try await ToolRun.eachFile(tool, inputs: inputs, skipWhy: L("I can only convert images.", table: "Tools"),
                                   progress: progress) { url, folder in
            switch tool {
            case .asPDF: return try await MakePDF.single(url, folder: folder)
            case .asPNG: return try image(url, as: .png, folder: folder)
            default: return try image(url, as: .jpeg, folder: folder)
            }
        }
    }

    static func image(_ url: URL, as type: UTType, folder: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let full = ToolImages.fullImage(source) else { throw ToolFailure.unreadable(name: url.lastPathComponent) }
        var props = ToolImages.cleaned(ToolImages.properties(source), dropGPS: false)
        if type == .jpeg { props[kCGImageDestinationLossyCompressionQuality as String] = 0.9 }
        let temp = ResultFile.temp(in: folder)
        try ToolImages.write(type == .jpeg ? ToolImages.opaque(full) : full, type: type, properties: props, to: temp)
        let tool: ToolID = type == .png ? .asPNG : .asJPEG
        return try ResultFile.place(temp, as: ResultNaming.name(for: tool, inputs: [url]), in: folder)
    }
}
