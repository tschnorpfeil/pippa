import Foundation

/// Download progress as people read it. Checking the file (SHA-256) and setting up still take noticeable time after the
/// last byte, so a percent shows only while bytes come in and never reads "100 %" for something that is not finished.
public enum DownloadProgress {
    /// Every byte is in: what follows is checking and setting up, not loading.
    public static func isFinishing(_ progress: Double) -> Bool { progress >= 1 }

    /// 0…99 while bytes come in (rounding must not turn 99.6 % into "100 %").
    public static func percent(_ progress: Double) -> Int { min(99, max(0, Int((progress * 100).rounded()))) }
}
