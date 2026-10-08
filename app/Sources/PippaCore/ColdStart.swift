import Darwin
import Foundation

// Cold start of the local model: llama-server is not running (after launch or after idle unloading) and the first
// answer waits until the model is in memory and Pippa's instructions have been read once. That can take a minute;
// this file turns what can be measured into plain progress so the person knows it only takes this long once.
//
// Two stages:
//   1. loading — the server process runs, `/health` answers 503 (or not yet at all). Progress is the process's
//      resident memory relative to the size of the model file, never more than `cap` until `/health` is 200.
//      If no memory reading is available (a server started by the terminal), the last measured load time is used.
//   2. warming — `/health` is 200; the saved conversation cache is restored and the first request reads Pippa's
//      instructions. No honest measure exists here, so it is shown without a number until the first words arrive.

public enum ColdStart {
    /// Highest fraction shown while loading; only `/health` 200 finishes the bar.
    public static let cap = 0.95

    /// What `/health` said at the last poll.
    public enum Health: Sendable, Equatable {
        /// No answer yet (the process is still starting up and not listening).
        case silent
        /// 503: the model is loading.
        case loading
        /// 200: the model is loaded.
        case ready

        public init(status: Int) {
            switch status {
            case 200: self = .ready
            case 0: self = .silent
            default: self = .loading
            }
        }
    }

    public enum Stage: Sendable, Equatable {
        /// Loading into memory; `fraction` is `nil` while nothing can be estimated yet.
        case loading(fraction: Double?)
        /// Loaded; getting through Pippa's instructions once.
        case warming

        /// The Thought Line phase for this stage.
        public var phase: WorkPhase {
            switch self {
            case .loading(let fraction): .wakingUp(progress: fraction)
            case .warming: .warmingUp
            }
        }
    }

    /// One reading of a starting server (`LlamaServer.coldStartSample`).
    public struct Sample: Sendable, Equatable {
        /// Resident memory of the server process in bytes; `nil` when it cannot be read.
        public var residentBytes: UInt64?
        /// Size of the model file in bytes (0: unknown).
        public var modelBytes: UInt64
        public var health: Health
        /// Seconds since the server process was started.
        public var elapsed: Double
        /// How long the last complete load took on this Mac (`nil`: never measured).
        public var lastLoadSeconds: Double?

        public init(residentBytes: UInt64?, modelBytes: UInt64, health: Health, elapsed: Double, lastLoadSeconds: Double?) {
            self.residentBytes = residentBytes; self.modelBytes = modelBytes; self.health = health
            self.elapsed = elapsed; self.lastLoadSeconds = lastLoadSeconds
        }
    }

    /// Pure estimate for one sample. Memory first (it is what actually grows while the weights are read),
    /// otherwise elapsed time against the last measured load, otherwise no number.
    public static func estimate(_ sample: Sample) -> Stage {
        if sample.health == .ready { return .warming }
        if let resident = sample.residentBytes, sample.modelBytes > 0 {
            return .loading(fraction: clamp(Double(resident) / Double(sample.modelBytes)))
        }
        if let last = sample.lastLoadSeconds, last > 0 {
            return .loading(fraction: clamp(sample.elapsed / last))
        }
        return .loading(fraction: nil)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(cap, max(0, value))
    }

    /// Keeps what the person sees steady across samples: the bar never moves backwards, whole percent only
    /// (fewer redraws), and once warming is reached it stays there.
    public struct Tracker: Sendable, Equatable {
        public private(set) var stage: Stage?
        public init() {}

        /// Applies one sample; returns the stage to show, or `nil` when nothing visible changed.
        @discardableResult
        public mutating func update(_ sample: Sample) -> Stage? {
            var next = ColdStart.estimate(sample)
            switch (stage, next) {
            case (.warming?, _):
                return nil
            case (.loading(let shown?)?, .loading(let fraction)):
                let rounded = ((fraction ?? 0) * 100).rounded(.down) / 100
                next = .loading(fraction: max(shown, rounded))
            case (_, .loading(let fraction?)):
                next = .loading(fraction: (fraction * 100).rounded(.down) / 100)
            default:
                break
            }
            guard next != stage else { return nil }
            stage = next
            return next
        }
    }

    // MARK: Words

    /// Pill label while waking up (no number: the pill keeps its width; the bar carries the progress).
    public static func pillLabel(_ phase: WorkPhase, language: String? = nil) -> String? {
        switch phase {
        case .wakingUp, .gettingReady: L("Pippa is waking up…", table: "Thought", language: language)
        case .warmingUp: L("Pippa is almost ready…", table: "Thought", language: language)
        default: nil
        }
    }

    /// Progress for the pill's bar: a fraction while loading, `nil` otherwise (indeterminate or no bar).
    public static func pillProgress(_ phase: WorkPhase) -> Double? {
        if case .wakingUp(let progress) = phase { return progress }
        return nil
    }

    /// Spoken value for the bar ("42 %"), so VoiceOver hears the number the eye sees as a bar.
    public static func spokenProgress(_ fraction: Double, language: String? = nil) -> String {
        L("%lld percent", table: "Thought", language: language, Int((fraction * 100).rounded()))
    }

    // MARK: Measuring

    /// Last complete load on this Mac, kept across launches for the time-based fallback.
    static let lastLoadKey = "coldStart.lastLoadSeconds"
    public static var lastLoadSeconds: Double? {
        let value = UserDefaults.standard.double(forKey: lastLoadKey)
        return value > 0 ? value : nil
    }
    static func rememberLoad(seconds: Double) {
        guard seconds.isFinite, seconds > 0.5 else { return }
        UserDefaults.standard.set(seconds, forKey: lastLoadKey)
    }

    /// Memory of a process (own user only): resident set and physical footprint, in bytes.
    public struct Memory: Sendable, Equatable {
        public var resident: UInt64
        public var footprint: UInt64
    }

    public static func memory(pid: Int32) -> Memory? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        return Memory(resident: info.ri_resident_size, footprint: info.ri_phys_footprint)
    }

    /// Bytes of the model's weights: the catalog's pinned files (all parts of a split model), otherwise the file itself.
    static func modelBytes(_ choice: ModelChoice, file: URL) -> UInt64 {
        let pinned = choice.model.pinned?.files.filter { $0.path.hasSuffix(".gguf") }.reduce(Int64(0)) { $0 + max(0, $1.size) } ?? 0
        if pinned > 0 { return UInt64(pinned) }
        return UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
}
