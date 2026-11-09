import Foundation

/// The two ways Pippa counts bytes: binary for memory ("16 GB" as Apple sells it), decimal for download sizes (as Finder).
enum ByteCount {
    static func gibibytes(_ bytes: UInt64) -> Double { Double(bytes) / 1_073_741_824 }
    static func gigabytes(_ bytes: Int64) -> Double { Double(max(bytes, 0)) / 1e9 }
}
