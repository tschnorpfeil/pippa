import AppKit
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// A bounded thumbnail for images and PDFs, with the Finder icon as a fallback for any file or folder.
struct NativeFileThumbnail: View {
    let url: URL
    let size: CGSize
    private let thumbnailState = State<NSImage?>(initialValue: nil)
    private var thumbnail: NSImage? { thumbnailState.wrappedValue }

    var body: some View {
        Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size.width, height: size.height)
            .clipped()
            .accessibilityHidden(true)
            .task(id: url) {
                thumbnailState.wrappedValue = nil
                guard let type = UTType(filenameExtension: url.pathExtension),
                      type.conforms(to: .image) || type.conforms(to: .pdf) else { return }
                let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2, representationTypes: .thumbnail)
                if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request),
                   !Task.isCancelled {
                    thumbnailState.wrappedValue = representation.nsImage
                }
            }
    }
}

/// Presents a file in the system Quick Look panel without opening its editing application.
struct NativeFilePreviewButton<Label: View>: View {
    let url: URL
    @ViewBuilder var label: () -> Label
    private let previewState = State<URL?>(initialValue: nil)

    var body: some View {
        Button { previewState.wrappedValue = url } label: { label() }
            .buttonStyle(.plain)
            .help(T("Preview", table: "App"))
            .accessibilityLabel(T("Preview", table: "App") + ": " + url.lastPathComponent)
            .quickLookPreview(previewState.projectedValue)
    }
}
