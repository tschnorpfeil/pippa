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
    private var opaque: [String: CGRect] = [:]

    private init() {}

    /// Image for the item: finished thumbnail, otherwise the Finder icon for now (and the request starts).
    /// Folders and packages (apps) always show their icon: a picture of a folder icon is no preview.
    func image(for item: TrayItem, size: CGSize = TrayThumbnails.cardSize, scale: CGFloat? = nil) -> NSImage {
        if Self.isFolder(item) { return placeholder(for: item) }
        let key = Self.key(for: item, size: size)
        if let image = images[key] { return image }
        request(item, key: key, size: size, scale: scale ?? Self.backingScale)
        return placeholder(for: item)
    }

    /// Part of the icon that isn't transparent, in unit coordinates (origin bottom left), for the remove button
    /// to sit on the folder's real corner instead of its empty margin.
    func opaqueBounds(for item: TrayItem) -> CGRect {
        let id = item.id.uuidString
        if let rect = opaque[id] { return rect }
        let rect = Self.opaqueBounds(of: placeholder(for: item))
        opaque[id] = rect
        return rect
    }

    nonisolated static func isFolder(_ item: TrayItem) -> Bool {
        if item.url.hasDirectoryPath { return true }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: item.url.path, isDirectory: &directory) && directory.boolValue
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
        opaque = opaque.filter { ids.contains($0.key) }
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

    /// Alpha scan on a 32 × 32 rendering; the whole square if nothing can be read.
    private static func opaqueBounds(of image: NSImage) -> CGRect {
        let side = 32
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        var minX = side, minY = side, maxX = -1, maxY = -1
        for row in 0..<side {
            for column in 0..<side where data[row * side + column] > 40 {
                // Row 0 of the bitmap is the top of the image.
                let y = side - 1 - row
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let unit = CGFloat(side)
        return CGRect(x: CGFloat(minX) / unit, y: CGFloat(minY) / unit,
                      width: CGFloat(maxX - minX + 1) / unit, height: CGFloat(maxY - minY + 1) / unit)
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
