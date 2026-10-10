import AppKit
import Foundation
import Photos

// MARK: Photos (read only)

/// Search Apple Photos by what is in the pictures: Photos indexes objects, places, people and text itself, and its
/// AppleScript `search for` is the search field of the app. PhotoKit knows no such labels, so the search goes through
/// Apple Events (automation for Photos, like Mail) and the previews through PhotoKit (`PHAsset` by the same id).
///
/// - Read only: the script reads `id`, `date`, `filename`, `name`; it changes, imports and exports nothing.
/// - Photos understands only the Mac's language ("Fahrrad" on a German Mac, "bicycle" on an English one), one word works
///   best; the tool description asks the model for exactly that.
/// - [assumption] The AppleScript `id` of a media item is PhotoKit's `localIdentifier` ("UUID/L0/001"), as osxphotos uses it.
public enum PhotosLibrary {
    public static let bundleIdentifier = "com.apple.Photos"

    /// Name of the app, as people know it.
    public static var appName: String { L("Photos", table: "Core") }

    /// May Pippa ask Photos? Starts Photos invisibly first (the search needs it running). `ask: true` shows the
    /// system prompt and waits for the answer, so not on the main thread.
    public static func access(ask: Bool) async -> IntegrationAccess {
        _ = await AppleEvents.launchHidden(bundle: bundleIdentifier)
        return await AppleEvents.permission(bundle: bundleIdentifier, appName: appName, ask: ask)
    }

    // MARK: Previews (PhotoKit)

    /// May Pippa read the library itself? PhotoKit's own permission ("Fotos"), separate from the automation for the
    /// search: previews, and the newest photos. Limited access counts: then only the photos the person shared.
    public static func libraryAccess(ask: Bool) async -> IntegrationAccess {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: return .granted
        case .notDetermined:
            guard ask else { return .notDetermined }
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            return status == .authorized || status == .limited ? .granted : .denied
        default: return .denied
        }
    }

    public static func previewAccess(ask: Bool) async -> Bool { await libraryAccess(ask: ask) == .granted }

    /// System Settings → Privacy & Security → Photos.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!

    /// The newest photos and videos, newest first; with `since` only those taken from then on. No content search
    /// (PhotoKit has no labels), so no automation and Photos need not run. `total`: all that match.
    public static func recent(since: Date?, limit: Int) -> HostFetch<PhotoHit> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if let since { options.predicate = NSPredicate(format: "creationDate >= %@", since as NSDate) }
        let found = PHAsset.fetchAssets(with: options)
        let items = (0..<min(limit, found.count)).map { index in
            let asset = found.object(at: index)
            return PhotoHit(id: asset.localIdentifier, date: asset.creationDate,
                            filename: PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "")
        }
        return HostFetch(items: items, total: found.count)
    }

    /// A finished preview image; CGImage is immutable, so it may cross actors.
    public struct Preview: @unchecked Sendable {
        public let image: CGImage
    }

    /// Preview for one photo of a `PhotoCard`, at most `side` pixels on its long edge. Only from this Mac (no iCloud
    /// download); `nil` without permission, for a photo that is gone, or when Photos has no local preview.
    public static func preview(id: String, side: CGFloat) async -> Preview? {
        guard await previewAccess(ask: false),
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat   // exactly one answer
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        options.isSynchronous = false
        return await withCheckedContinuation { done in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill,
                                                  options: options) { image, _ in
                done.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil).map(Preview.init))
            }
        }
    }

    // MARK: Open in Photos

    /// Shows the photo in Photos (click on a preview). If Photos can't find it any more, Photos itself comes to the front.
    public static func show(id: String) async {
        try? await AppleEvents.perform {
            _ = try AppleEvents.call(PhotosShowScript.source, handler: "showItem", [NSAppleEventDescriptor(string: id)], appName: appName)
        }
    }
}

/// One hit of the Photos search, read only.
public struct PhotoHit: Sendable, Equatable {
    /// Photos' id of the media item (= PhotoKit `localIdentifier`), for the preview and for opening.
    public var id: String
    public var date: Date?
    public var filename: String
    /// Title the person gave the photo; often empty.
    public var title: String
    public init(id: String, date: Date?, filename: String, title: String = "") {
        self.id = id; self.date = date; self.filename = filename; self.title = title
    }
}

/// A Photos search as a card in the conversation (`ResultCard.photos`): previews in a grid, click opens the photo in Photos. Built by Pippa's
/// own MCP server from what it read (never from model text); the model only gets the count and the dates.
public struct PhotoCard: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        /// Photos' id: `PhotosLibrary.preview(id:side:)` and `PhotosLibrary.show(id:)`.
        public var id: String
        public var date: Date?
        /// "Sa., 3. Aug. 2024" in the app language; empty without a date.
        public var dateLabel: String
        /// The person's title, else the file name: for VoiceOver and as a fallback without preview.
        public var label: String
        public init(id: String, date: Date?, dateLabel: String, label: String) {
            self.id = id; self.date = date; self.dateLabel = dateLabel; self.label = label
        }
    }
    /// The search word as sent to Photos ("Fahrrad"); empty for the newest photos.
    public var query: String
    public var items: [Item]
    public var total: Int
    /// Pippa may show previews (PhotoKit). `false`: the card shows date and label instead, and clicking still opens Photos.
    public var previews: Bool
    /// "Fotos auf diesem Mac · 23 gefunden": quiet footer.
    public var footer: String
    /// More photos than shown, and where to see all of them.
    public var truncatedNote: String?
    /// The most photos one search shows (`photos_search` limit).
    public static let maxItems = 30

    public init(query: String, items: [Item], total: Int, previews: Bool, footer: String, truncatedNote: String?) {
        self.query = query; self.items = Array(items.prefix(Self.maxItems)); self.total = total; self.previews = previews
        self.footer = footer; self.truncatedNote = truncatedNote
    }
}

enum PhotosSearchScript {
    /// The search text goes in as a parameter, never into the script text. At most `maxCount` hits are read.
    /// `missing value` is checked before `as text` (which would turn it into the words "missing value").
    static let source = """
    on searchPhotos(q, maxCount)
        tell application id "com.apple.Photos"
            with timeout of 30 seconds
                set found to (search for q)
            end timeout
            set total to count of found
            set n to total
            if n > maxCount then set n to maxCount
            set out to {}
            repeat with i from 1 to n
                set m to item i of found
                set theDate to missing value
                set theFile to ""
                set theName to ""
                try
                    set theDate to date of m
                end try
                try
                    set v to filename of m
                    if v is not missing value then set theFile to v as text
                end try
                try
                    set v to name of m
                    if v is not missing value then set theName to v as text
                end try
                set end of out to {(id of m) as text, theDate, theFile, theName}
            end repeat
            return {total, out}
        end tell
    end searchPhotos
    """

    static func search(_ query: String, limit: Int) async throws -> HostFetch<PhotoHit> {
        try await AppleEvents.perform { () throws -> HostFetch<PhotoHit> in
            let reply = try AppleEvents.call(source, handler: "searchPhotos",
                                             [NSAppleEventDescriptor(string: query), NSAppleEventDescriptor(int32: Int32(limit))],
                                             appName: PhotosLibrary.appName)
            let parts = AppleEvents.items(reply)
            guard parts.count == 2 else { return HostFetch(items: [], total: 0) }
            let items = AppleEvents.items(parts[1]).compactMap { row -> PhotoHit? in
                let f = AppleEvents.items(row)
                guard f.count == 4, let id = f[0].stringValue, !id.isEmpty else { return nil }
                return PhotoHit(id: id, date: f[1].dateValue, filename: f[2].stringValue ?? "", title: f[3].stringValue ?? "")
            }
            // [assumption] Photos' order is not by date: newest first, like the app's search shows them.
            let sorted = items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            return HostFetch(items: sorted, total: Int(parts[0].int32Value))
        }
    }
}

/// Opening only: `spotlight` shows the item in Photos, changes nothing.
enum PhotosShowScript {
    static let source = """
    on showItem(theID)
        tell application id "com.apple.Photos"
            activate
            try
                spotlight media item id theID
            end try
        end tell
    end showItem
    """
}
