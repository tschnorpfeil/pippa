import Foundation

extension ModelDownloader {
    // MARK: Disk space

    /// Buffer beyond the download: the Mac needs room itself, and Pippa writes logs and histories.
    public static let spaceBuffer: Int64 = 2_000_000_000
    /// Below this free amount a running download aborts rather than filling the disk completely.
    public static let spaceFloor: Int64 = 1_000_000_000

    /// How much more would have to be free; `nil` = enough space (or unknown).
    public static func spaceShortfall(available: Int64?, remaining: Int64, buffer: Int64 = spaceBuffer) -> Int64? {
        guard let available, remaining > 0 else { return nil }
        let needed = remaining + buffer
        return available < needed ? needed - available : nil
    }

    /// Free space for "important" data (includes what macOS can free up itself when needed).
    public static func availableSpace(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Disk full or quota exhausted?
    public static func isOutOfSpace(_ error: Error) -> Bool {
        if let p = error as? PippaError, case .notEnoughSpace = p { return true }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return true }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(ENOSPC) || ns.code == Int(EDQUOT)) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isOutOfSpace(underlying) }
        return false
    }

    /// Write error as an understandable message; full disk with the missing space on the volume of `directory`.
    static func writeFailure(_ error: Error, remaining: Int64, in directory: URL) -> PippaError {
        if isOutOfSpace(error) {
            let shortfall = spaceShortfall(available: availableSpace(at: directory), remaining: remaining) ?? spaceBuffer
            return .notEnoughSpace(bytes: shortfall)
        }
        return .writeFailed(SystemError.reason(error))
    }

    func writeFailure(_ error: Error, remaining: Int64) -> PippaError {
        Self.writeFailure(error, remaining: remaining, in: directory)
    }

    /// Models are large and can be downloaded again any time: keep out of backups (Time Machine, iCloud).
    public func excludeFromBackup() {
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}
