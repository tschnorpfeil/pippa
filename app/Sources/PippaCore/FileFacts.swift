import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Identity of a file at the time of the preview: device + inode, size, modification time.
public struct FileFingerprint: Sendable, Codable, Hashable {
    public var device: UInt64
    public var inode: UInt64
    public var size: UInt64
    public var mtime: Double

    public init(device: UInt64, inode: UInt64, size: UInt64, mtime: Double) {
        self.device = device; self.inode = inode; self.size = size; self.mtime = mtime
    }

    /// Without resolving symlinks (lstat).
    public static func of(_ url: URL) -> FileFingerprint? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        let size = (st.st_mode & S_IFMT) == S_IFDIR ? 0 : UInt64(st.st_size)
        return FileFingerprint(device: UInt64(UInt32(bitPattern: st.st_dev)), inode: UInt64(st.st_ino), size: size, mtime: mtime)
    }

    /// The same file, unchanged?
    public func matches(_ other: FileFingerprint?) -> Bool {
        guard let other else { return false }
        return device == other.device && inode == other.inode && size == other.size && abs(mtime - other.mtime) < 0.001
    }
}

/// Quick metadata of a file, without a model.
public struct FileFacts: Sendable {
    public var url: URL
    public var type: UTType
    public var size: Int64
    public var created: Date?
    public var modified: Date?
    public var captureDate: Date?          // EXIF DateTimeOriginal
    public var cameraModel: String?
    public var pdfTitle: String?
    public var pdfPageCount: Int?

    public var isImage: Bool { type.conforms(to: .image) }

    /// EXIF times carry no time zone: read in the system's, as a new formatter's default would. Never changed after it is made.
    private static let exifTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    public static func read(_ url: URL) -> FileFacts {
        let type = UTType(filenameExtension: url.pathExtension.lowercased()) ?? .data
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
        var facts = FileFacts(url: url, type: type, size: Int64(values?.fileSize ?? 0),
                              created: values?.creationDate, modified: values?.contentModificationDate)
        if type.conforms(to: .image), !isCloudPlaceholder(url), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            if let raw = (exif?[kCGImagePropertyExifDateTimeOriginal] ?? tiff?[kCGImagePropertyTIFFDateTime]) as? String {
                facts.captureDate = exifTime.date(from: raw)
            }
            facts.cameraModel = tiff?[kCGImagePropertyTIFFModel] as? String
        }
        if type.conforms(to: .pdf), !isCloudPlaceholder(url), let doc = PDFDocument(url: url) {
            facts.pdfPageCount = doc.pageCount
            facts.pdfTitle = (doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespaces)
        }
        return facts
    }

    /// iCloud file that is not loaded locally.
    public static func isCloudPlaceholder(_ url: URL) -> Bool {
        if url.lastPathComponent.hasPrefix(".") && url.pathExtension == "icloud" { return true }
        guard let v = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              v.isUbiquitousItem == true else { return false }
        return v.ubiquitousItemDownloadingStatus != .current
    }
}
