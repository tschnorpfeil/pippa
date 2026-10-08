import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

// Thumbnails for file rows in previews (tidy preview): images and PDFs show what they are,
// everything else keeps the drawn document icon. Quick Look renders in the background;
// the icon stands in until then and whenever no image comes back. The file is only read.

/// Quick Look images by file, size and modification date, shared by all rows.
@MainActor
final class FileThumbnails {
    static let shared = FileThumbnails()

    private let cache = NSCache<NSString, NSImage>()
    private var running: [String: Task<NSImage?, Never>] = [:]

    private init() { cache.countLimit = 400 }

    /// Only images and PDFs get a thumbnail; other kinds would only show a bigger icon.
    static func wantsThumbnail(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .pdf)
    }

    func cached(_ url: URL, side: CGFloat) -> NSImage? { cache.object(forKey: Self.key(url, side: side) as NSString) }

    /// The thumbnail, rendered once per file and size; `nil` if Quick Look has none.
    func image(for url: URL, side: CGFloat) async -> NSImage? {
        let key = Self.key(url, side: side)
        if let image = cache.object(forKey: key as NSString) { return image }
        if let task = running[key] { return await task.value }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let task = Task<NSImage?, Never> {
            let size = CGSize(width: side, height: side)
            let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
            guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
            return rep.nsImage
        }
        running[key] = task
        let image = await task.value
        running[key] = nil
        if let image { cache.setObject(image, forKey: key as NSString) }
        return image
    }

    private static func key(_ url: URL, side: CGFloat) -> String {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(url.path)|\(Int(modified?.timeIntervalSince1970 ?? 0))|\(Int(side))"
    }
}

/// Row icon: a small thumbnail for images and PDFs (enlarged on hover), otherwise the document icon.
struct FileThumbnail: View {
    var url: URL?
    var width: CGFloat = 20
    /// Side of the enlarged preview on hover.
    var hoverSide: CGFloat = 240

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // @State is not available without Xcode (macro plugin): storage by hand.
    private let imageState = State<NSImage?>(initialValue: nil)
    private let hoveringState = State(initialValue: false)
    private let showsLargeState = State(initialValue: false)
    private let largeState = State<NSImage?>(initialValue: nil)
    private var image: NSImage? { imageState.wrappedValue }
    private var hovering: Bool { hoveringState.wrappedValue }
    private var large: NSImage? { largeState.wrappedValue }

    private var height: CGFloat { width * 1.2 }

    var body: some View {
        if let url, FileThumbnails.wantsThumbnail(url) {
            thumbnail(url)
        } else {
            DocIcon(kind: DocIcon.kind(for: url), width: width)
        }
    }

    @ViewBuilder
    private func thumbnail(_ url: URL) -> some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width - 2, height: height - 2)
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    .padding(1)
                    .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Theme.sheet))
                    .shadow(color: Color.black.opacity(0.18), radius: 1.5, x: 0, y: 0.5)
                    .transition(.opacity)
            } else {
                DocIcon(kind: DocIcon.kind(for: url), width: width)
            }
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
        .task(id: url) {
            imageState.wrappedValue = FileThumbnails.shared.cached(url, side: width * 2)
            guard image == nil else { return }
            let rendered = await FileThumbnails.shared.image(for: url, side: width * 2)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { imageState.wrappedValue = rendered }
        }
        .onHover { inside in hoveringState.wrappedValue = inside }
        .task(id: hovering) {
            // A short pause: passing over the list with the mouse does not open a popover per row.
            guard hovering, image != nil else { showsLargeState.wrappedValue = false; return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, hovering else { return }
            largeState.wrappedValue = await FileThumbnails.shared.image(for: url, side: hoverSide)
            guard !Task.isCancelled, hovering, large != nil else { return }
            showsLargeState.wrappedValue = true
        }
        .popover(isPresented: showsLargeState.projectedValue, arrowEdge: .trailing) {
            if let large {
                Image(nsImage: large)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: hoverSide, maxHeight: hoverSide)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(10)
                    .accessibilityHidden(true)
            }
        }
    }
}
