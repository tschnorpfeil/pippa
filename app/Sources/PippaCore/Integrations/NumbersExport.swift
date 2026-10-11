import AppKit
import CryptoKit
import Foundation

// MARK: Numbers (export a copy, read only)

/// Pippa cannot read the .numbers format, but Numbers can save a copy as Excel. So a dropped Numbers table goes
/// through Numbers once: open, `export … as Microsoft Excel` into Pippa's cache, close again without saving. The
/// person's file is never changed. If the document was already open in Numbers it stays open; if Numbers was not
/// running, it is started hidden and quit again. Apple Events like `ExcelScript` (`automation.apple-events`, no App
/// Sandbox); macOS asks once for Numbers.
///
/// Compiling: `export … as Microsoft Excel` exists only in Numbers' dictionary; without Numbers the script cannot be
/// compiled, and CI has no Numbers, so nothing here runs in the checks except the paths around it.
public enum NumbersExport {
    /// Numbers from the App Store (current) and the older iWork identifier.
    static let bundleIdentifiers = ["com.apple.Numbers", "com.apple.iWork.Numbers"]

    public static var appName: String { L("Numbers", table: "Sheet") }

    /// The installed Numbers, nil without one.
    static var bundleIdentifier: String? { bundleIdentifiers.first { AppleEvents.isInstalled(bundle: $0) } }

    /// Is Numbers on this Mac? Only then does a .numbers file count as readable.
    public static var isInstalled: Bool { bundleIdentifier != nil }

    /// The script for one of the fixed identifiers above (never text from outside; paths go in as parameters).
    static func source(bundle: String) -> String {
        """
        on exportCopy(sourcePath, targetPath)
            tell application id "\(bundle)"
                set wasOpen to false
                repeat with d in documents
                    try
                        if (POSIX path of ((file of d) as alias)) is sourcePath then set wasOpen to true
                    end try
                end repeat
                set theDoc to open (POSIX file sourcePath)
                export theDoc to (POSIX file targetPath) as Microsoft Excel
                if not wasOpen then close theDoc saving no
            end tell
            return targetPath
        end exportCopy

        on quitApp()
            tell application id "\(bundle)" to quit saving no
        end quitApp
        """
    }

    /// Where the copy of this file goes: Pippa's cache, one name per file and modification date, so reading the same
    /// table twice exports it once.
    public static func copyURL(for url: URL) -> URL {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        let key = SHA256.hash(data: Data("\(url.standardizedFileURL.path)|\(modified)".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pippa/Numbers/\(key)", isDirectory: true)
        let name = url.deletingPathExtension().lastPathComponent
        return folder.appendingPathComponent((name.isEmpty ? "Tabelle" : name) + ".xlsx")
    }

    /// An Excel copy of the Numbers file (from the cache if it is there). Throws `accessDenied` when the person said
    /// no to Pippa asking Numbers, `notAvailable` without Numbers or when the export fails.
    public static func excelCopy(of url: URL) async throws -> URL {
        let target = copyURL(for: url)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        guard let bundle = bundleIdentifier else { throw PippaError.notAvailable }
        let wasRunning = AppleEvents.isRunning(bundle: bundle)
        guard await AppleEvents.launchHidden(bundle: bundle) else { throw PippaError.notAvailable }
        switch await AppleEvents.permission(bundle: bundle, appName: appName, ask: true) {
        case .granted: break
        case .denied: throw PippaError.accessDenied(appName)
        default: throw PippaError.notAvailable
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = source(bundle: bundle)
        let name = appName
        let sourcePath = url.standardizedFileURL.path, targetPath = target.path
        defer {
            if !wasRunning {
                Task { try? await AppleEvents.perform { _ = try AppleEvents.call(script, handler: "quitApp", appName: name) } }
            }
        }
        try await AppleEvents.perform {
            _ = try AppleEvents.call(script, handler: "exportCopy",
                                 [NSAppleEventDescriptor(string: sourcePath), NSAppleEventDescriptor(string: targetPath)], appName: name)
        }
        guard FileManager.default.fileExists(atPath: target.path) else { throw PippaError.notAvailable }
        return target
    }
}
