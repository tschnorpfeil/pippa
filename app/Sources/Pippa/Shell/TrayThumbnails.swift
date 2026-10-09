import AppKit
import Combine
import PippaCore
import QuickLookThumbnailing
import SwiftUI

// Thumbnails of the items lying on Pippa.
//
// Quick Look renders in the background; until then the file's Finder icon stands in.
// Cached by item and modification date so a newly written result
// doesn't show the old image. The file is never modified, only read.

/// Quick Look image from the background, handed across to the main thread.
private struct ThumbnailBox: @unchecked Sendable {
    let image: CGImage?
}

@MainActor
final class TrayThumbnails: ObservableObject {
    static let shared = TrayThumbnails()

    /// Size of the cards at the pill (points); the image is requested at this size times screen scale.
    static let cardSize = CGSize(width: 64, height: 84)

    /// Counts up as soon as an image is ready (cards and SwiftUI then redraw).
    @Published private(set) var revision = 0

    private var images: [String: NSImage] = [:]
    private var pending: Set<String> = []
    private var icons: [String: NSImage] = [:]

    private init() {}

    /// Image for the item: finished thumbnail, otherwise the Finder icon for now (and the request starts).
    func image(for item: TrayItem, size: CGSize = TrayThumbnails.cardSize, scale: CGFloat? = nil) -> NSImage {
        let key = Self.key(for: item, size: size)
        if let image = images[key] { return image }
        request(item, key: key, size: size, scale: scale ?? Self.backingScale)
        return placeholder(for: item)
    }

    /// true if a real thumbnail already exists (not just the icon).
    func hasImage(for item: TrayItem, size: CGSize = TrayThumbnails.cardSize) -> Bool {
        images[Self.key(for: item, size: size)] != nil
    }

    /// Forgets images of items no longer lying on Pippa.
    func forget(keeping items: [TrayItem]) {
        let ids = Set(items.map { $0.id.uuidString })
        images = images.filter { ids.contains(Self.itemID(ofKey: $0.key)) }
        icons = icons.filter { ids.contains($0.key) }
    }

    // MARK: Internal

    private static var backingScale: CGFloat { NSScreen.main?.backingScaleFactor ?? 2 }

    private static func key(for item: TrayItem, size: CGSize) -> String {
        let modified = (try? item.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let stamp = modified.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
        return "\(item.id.uuidString)|\(stamp)|\(Int(size.width))x\(Int(size.height))"
    }

    private static func itemID(ofKey key: String) -> String {
        String(key.split(separator: "|").first ?? "")
    }

    private func placeholder(for item: TrayItem) -> NSImage {
        let id = item.id.uuidString
        if let icon = icons[id] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: item.url.path)
        icons[id] = icon
        return icon
    }

    private func request(_ item: TrayItem, key: String, size: CGSize, scale: CGFloat) {
        guard !pending.contains(key) else { return }
        pending.insert(key)
        // Access (security-scoped) only for the duration of the request.
        guard let resolved = TrayStore.resolve(item) else {
            pending.remove(key)
            return
        }
        Self.generate(url: resolved.url, scoped: resolved.scoped, size: size, scale: scale) { box in
            Task { @MainActor in
                TrayThumbnails.shared.finish(key: key, box: box, size: size)
            }
        }
    }

    private func finish(key: String, box: ThumbnailBox, size: CGSize) {
        pending.remove(key)
        guard let cg = box.image else { return }
        images[key] = NSImage(cgImage: cg, size: size)
        revision += 1
    }

    /// Continues off the main thread: the completion arrives on a Quick Look queue.
    private nonisolated static func generate(url: URL, scoped: Bool, size: CGSize, scale: CGFloat,
                                             done: @escaping @Sendable (ThumbnailBox) -> Void) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { @Sendable representation, _ in
            if scoped { url.stopAccessingSecurityScopedResource() }
            done(ThumbnailBox(image: representation?.cgImage))
        }
    }
}
