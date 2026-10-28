import Darwin
import Foundation

/// This Mac in plain words for "Picked for your Mac": the chip as macOS names it and the memory in GB.
public enum MacHardware {
    /// "Apple M2 Pro" (sysctl machdep.cpu.brand_string); `nil` if macOS does not say.
    public static func chipName() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return nil }
        return chipName(brand: String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    /// The brand string without surrounding space or control characters; empty is `nil`.
    public static func chipName(brand: String) -> String? {
        let name = brand.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
        return name.isEmpty ? nil : name
    }

    /// Memory as Apple sells it: 17 179 869 184 bytes are "16 GB".
    public static func memoryGB(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        Int((Double(physicalMemory) / 1_073_741_824).rounded())
    }

    /// "Apple M2 Pro · 16 GB memory", or only the memory when the chip is unknown.
    public static func summary(chip: String? = chipName(), physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> String {
        let memory = memoryGB(physicalMemory: physicalMemory)
        guard let chip else { return L("%lld GB memory", table: "Setup", memory) }
        return L("%1$@ · %2$lld GB memory", table: "Setup", chip, memory)
    }
}
