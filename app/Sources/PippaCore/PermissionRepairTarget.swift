import Foundation

/// A code-verified access denial may offer one known macOS privacy pane. No model text or URL is accepted.
public enum PermissionRepairTarget: String, Codable, Sendable, CaseIterable {
    case filesAndFolders, removableVolumes, photos, automation, calendar, reminders

    public var settingsURL: URL {
        let anchor = switch self {
        case .filesAndFolders: "Privacy_FilesAndFolders"
        case .removableVolumes: "Privacy_RemovableVolume"
        case .photos: "Privacy_Photos"
        case .automation: "Privacy_Automation"
        case .calendar: "Privacy_Calendars"
        case .reminders: "Privacy_Reminders"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    public init(integration: Integration) {
        self = switch integration {
        case .calendar: .calendar
        case .reminders: .reminders
        case .mail: .automation
        }
    }

    /// Only protected locations suggest a privacy repair. Ordinary UNIX file permissions do not imply a TCC denial.
    /// Call only after receiving an actual filesystem permission error, never for missing or unreadable-format files.
    public static func forDeniedFile(at url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Self? {
        guard url.isFileURL else { return nil }
        let path = url.standardizedFileURL.path
        let roots = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage", "Dropbox"]
        if roots.contains(where: { relative in
            let root = home.appendingPathComponent(relative, isDirectory: true).standardizedFileURL.path
            return path == root || path.hasPrefix(root + "/")
        }) { return .filesAndFolders }
        if path.hasPrefix("/Volumes/"),
           let volume = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey]),
           volume.volumeIsInternal == false, volume.volumeIsLocal == true { return .removableVolumes }
        return nil
    }

    /// Foundation may wrap POSIX failures; unrelated error domains with the same numeric code are not denials.
    public static func isFileAccessDenied(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(EPERM) || error.code == Int(EACCES) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return underlying.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(underlying.code)
        }
        return false
    }
}
