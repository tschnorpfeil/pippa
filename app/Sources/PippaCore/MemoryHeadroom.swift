import Darwin
import Foundation

/// The kernel's own memory pressure level (`kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical).
public enum PressureLevel: Int, Sendable, Comparable, CaseIterable {
    case normal = 1, warning = 2, critical = 4

    public static func < (a: PressureLevel, b: PressureLevel) -> Bool { a.rawValue < b.rawValue }

    /// Name in the diagnostics log.
    public var logName: String {
        switch self {
        case .normal: "normal"
        case .warning: "warnung"
        case .critical: "kritisch"
        }
    }
}

/// How much memory the Mac could hand a model right now without swapping: free + inactive + purgeable + speculative
/// pages (`host_statistics64`), plus the kernel's pressure level. A snapshot; the decisions live in `MemoryGate`.
public struct MemoryHeadroom: Sendable, Equatable {
    public var availableBytes: UInt64
    public var pressure: PressureLevel

    public init(availableBytes: UInt64, pressure: PressureLevel) {
        self.availableBytes = availableBytes; self.pressure = pressure
    }

    public var availableGiB: Double { Double(availableBytes) / 1_073_741_824 }

    /// Reads both values now. Unreadable statistics count as no headroom, an unreadable level as normal
    /// (only critical refuses a load, so a missing sysctl never blocks one).
    public static func current() -> MemoryHeadroom {
        MemoryHeadroom(availableBytes: availablePages().map { $0 * UInt64(max(sysconf(_SC_PAGESIZE), 0)) } ?? 0,
                       pressure: pressureLevel())
    }

    /// Reclaimable pages without swapping. `free_count` already contains the speculative pages (vm_stat prints
    /// "Pages free" as free minus speculative), so they are counted once.
    static func availablePages() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let free = UInt64(stats.free_count) - min(UInt64(stats.free_count), UInt64(stats.speculative_count))
        return free + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count) + UInt64(stats.speculative_count)
    }

    static func pressureLevel() -> PressureLevel {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return .normal }
        return PressureLevel(rawValue: Int(value)) ?? (value > PressureLevel.critical.rawValue ? .critical : .normal)
    }
}

/// Pure decisions about memory and loading (docs/next-level-plan-2026-10-30.md §3): whether a load may start (a preload
/// follows the same rule) and what a pressure event does to the server. Inputs only, no system calls, so PippaChecks
/// cover every branch without real memory pressure.
public enum MemoryGate {
    /// Below this a load is only logged as tight (log-only in 0.3.18; 0.3.19 sets refusals from the logged data).
    /// 32 GB+ keeps the 35B's former 24 GB value: its weights alone are 17.5 GiB.
    public static func tightGiB(tier: Int) -> Double {
        switch tier {
        case ..<12: 5.2
        case ..<28: 8
        default: 18.5
        }
    }

    public enum LoadVerdict: String, Sendable, Equatable {
        case ok, tight, refuse
    }

    /// A model load: refused only under critical pressure; little headroom is only logged.
    public static func load(pressure: PressureLevel, headroomGiB: Double, tier: Int) -> LoadVerdict {
        if pressure == .critical { return .refuse }
        return headroomGiB < tightGiB(tier: tier) ? .tight : .ok
    }

    public enum ServerKind: Sendable, Equatable {
        case stopped, starting, owned, adopted
    }

    public enum PressureAction: Sendable, Equatable {
        case none
        /// A load under way is stopped and the start fails with `PippaError.notEnoughMemory`.
        case abortStart
        /// Stop the own server; `saveSlot`: save the prompt cache first (warning only, there is time).
        case unload(saveSlot: Bool)
        /// SIGTERM the terminal's server (PID from the lock), SIGKILL after 2 s, remove the lock. Terminal Pi
        /// starts it again with its next request.
        case terminateAdopted
    }

    /// What a pressure event does. Critical: always, at once, in every state. Warning: only without a request in flight
    /// (an agent lease, or for a shared server also the terminal's own request), and never to a load under way.
    public static func onPressure(_ level: PressureLevel, server: ServerKind, busy: Bool, slotsActive: Bool) -> PressureAction {
        guard level != .normal, server != .stopped else { return .none }
        let critical = level == .critical
        switch server {
        case .stopped: return .none
        case .starting: return critical ? .abortStart : .none
        case .adopted: return critical || !busy ? .terminateAdopted : .none
        case .owned:
            if critical { return .unload(saveSlot: false) }
            return busy ? .none : .unload(saveSlot: slotsActive)
        }
    }

    /// The process `terminateAdopted` may signal: only the server PID of the terminal's lock on our port, never its
    /// holder (the supervisor, which removes the lock once the server is gone) and never a lock of another app.
    public static func adoptedTarget(_ lock: PiServerLock?, port: Int) -> Int32? {
        guard let lock, lock.owner == "pi", lock.port == port, let pid = lock.pid, pid > 0, pid != getpid() else { return nil }
        return pid
    }
}
