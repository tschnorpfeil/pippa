import AppKit
import PippaCore
import UniformTypeIdentifiers

/// Staging area for items that don't arrive as files (mails from Apple Mail, images, text).
enum Inbox {
    static var directory: URL {
        #if DEBUG
        if let snapshot = ProcessInfo.processInfo.environment["PIPPA_SNAPSHOT"], !snapshot.isEmpty {
            return URL(fileURLWithPath: snapshot, isDirectory: true).appendingPathComponent("inbox", isDirectory: true)
        }
        #endif
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Pippa/Inbox", isDirectory: true)
    }

    /// A fresh subfolder per drop so nothing collides.
    static func freshFolder() throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent(stamp + "-" + String(UUID().uuidString.prefix(4)), isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Reads what was dragged onto Pippa: files, file promises (Mail), images, links, text.
enum DropReader {
    static let types: [NSPasteboard.PasteboardType] =
        [.fileURL, .URL, .string, .tiff, .png] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }

    struct Result {
        var payload: DropPayload
        var items: [URL]
    }

    @MainActor
    static func read(_ pb: NSPasteboard, imageName: String = "Bild.png", completion: @escaping @MainActor (Result?) -> Void) {
        // 1. Real files and folders
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return completion(Result(payload: .files(urls), items: urls))
        }
        // 2. File promises (e.g. mails from Apple Mail arrive as .eml)
        if let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver], !receivers.isEmpty,
           let folder = try? Inbox.freshFolder() {
            receivePromises(receivers, into: folder, completion: completion)
            return
        }
        // 3. Images
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff).flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }),
           let folder = try? Inbox.freshFolder() {
            let url = folder.appendingPathComponent(imageName)
            if (try? data.write(to: url)) != nil {
                return completion(Result(payload: .files([url]), items: [url]))
            }
        }
        // 4. Links
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], let link = urls.first, !link.isFileURL {
            let saved = saveText(link.absoluteString, name: "Link.txt")
            return completion(Result(payload: .link(link), items: saved.map { [$0] } ?? []))
        }
        // 5. Text
        if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme,
               ["http", "https"].contains(scheme.lowercased()) {
                let saved = saveText(url.absoluteString, name: "Link.txt")
                return completion(Result(payload: .link(url), items: saved.map { [$0] } ?? []))
            }
            let saved = saveText(text, name: "Text.txt")
            return completion(Result(payload: .text(text), items: saved.map { [$0] } ?? []))
        }
        completion(nil)
    }

    private static func saveText(_ text: String, name: String) -> URL? {
        guard let folder = try? Inbox.freshFolder() else { return nil }
        let url = folder.appendingPathComponent(name)
        return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
    }

    @MainActor
    private static func receivePromises(_ receivers: [NSFilePromiseReceiver], into folder: URL,
                                        completion: @escaping @MainActor (Result?) -> Void) {
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        let collector = PromiseCollector(expected: receivers.count)
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { url, error in
                collector.add(error == nil ? url : nil) { urls in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            completion(urls.isEmpty ? nil : Result(payload: .files(urls), items: urls))
                        }
                    }
                }
            }
        }
    }
}

/// Collects the files of several promises until all have arrived.
private final class PromiseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var urls: [URL] = []

    init(expected: Int) { remaining = expected }

    func add(_ url: URL?, whenDone: ([URL]) -> Void) {
        let finished: [URL]? = lock.withLock {
            if let url { urls.append(url) }
            remaining -= 1
            return remaining == 0 ? urls : nil
        }
        if let finished { whenDone(finished) }
    }
}
