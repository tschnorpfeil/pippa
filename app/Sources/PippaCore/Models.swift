import Foundation

/// Entry from Resources/catalog.json: a model on Hugging Face, every file pinned by revision, size and SHA-256.
public struct CatalogModel: Sendable, Codable, Hashable {
    public struct File: Sendable, Codable, Hashable { public var path: String; public var size: Int64; public var sha256: String }
    public struct Pinned: Sendable, Codable, Hashable { public var revision: String; public var files: [File] }

    /// Also the model's folder name, the id oMLX serves it under and the id in Pi's models.json.
    public var key: String
    public var label: String
    public var repo: String
    public var approxBytes: Int64?
    /// Largest context Pippa gives it; `ModelSelector` lowers it on 16 GB Macs.
    public var ctx: Int
    /// Pippa's default thinking level for this model in Pi (`off`, `medium`); written to Pi's
    /// `modelThinkingLevels` (PiModelTuning). Pi clamps it to what the model supports.
    public var thinking: String?
    public var pinned: Pinned?
}

public struct ModelCatalog: Sendable, Codable {
    public var models: [CatalogModel]
    public init(models: [CatalogModel]) { self.models = models }

    public static func bundled() -> ModelCatalog {
        guard let url = Bundle.module.url(forResource: "catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(ModelCatalog.self, from: data) else {
            return ModelCatalog(models: [])
        }
        return catalog
    }

    public func model(_ key: String) -> CatalogModel? { models.first { $0.key == key } }
}

/// The model for this Mac and the context it gets.
public struct ModelChoice: Sendable, Hashable {
    public var model: CatalogModel
    public var ctx: Int
}

/// One model for every Mac that can run it: Apple silicon with 16 GB or more. 32K context from 24 GB, 16K on 16 GB.
/// Smaller Macs use an online AI.
public enum ModelSelector {
    public static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        // Under Rosetta, hw.optional.arm64 still reports 1.
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
        #endif
    }

    /// Below this the 9B model (5 GB weights, ~6.5 GB while answering) leaves the Mac no room.
    public static let minimumMemoryGiB = 15.0

    public static func choose(physicalMemory: UInt64, appleSilicon: Bool = isAppleSilicon,
                              catalog: ModelCatalog = .bundled()) -> Result<ModelChoice, PippaError> {
        guard appleSilicon else {
            return .failure(.unsupportedHardware(L("Pippa needs a Mac with Apple silicon (M1 or later).", table: "Core")))
        }
        let gib = ByteCount.gibibytes(physicalMemory)
        guard gib >= minimumMemoryGiB else {
            return .failure(.unsupportedHardware(L("Pippa’s AI on this Mac needs 16 GB of memory. Use an online AI in Settings instead.", table: "Core")))
        }
        guard let model = catalog.models.first, model.pinned != nil else { return .failure(.modelUnavailable) }
        return .success(ModelChoice(model: model, ctx: min(model.ctx, gib >= 22 ? 32768 : 16384)))
    }
}

/// Download size of the matching model, for the question before the first download.
public struct ModelDownloadSize: Sendable, Equatable {
    public var total: Int64
    /// What is still missing (an interrupted download counts with what was already fetched).
    public var remaining: Int64
    /// What already lies with another program on this Mac and is only adopted (no download).
    public var existing: Int64
    /// Where the existing one comes from, e.g. "LM Studio".
    public var existingSource: String?
    public init(total: Int64, remaining: Int64, existing: Int64 = 0, existingSource: String? = nil) {
        self.total = total; self.remaining = remaining; self.existing = existing; self.existingSource = existingSource
    }

    /// "16,8 GB" (decimal GB as in Finder).
    public static func gigabytes(_ bytes: Int64) -> String {
        L("%.1f GB", table: "Core", ByteCount.gigabytes(bytes))
    }

    /// Approximate duration with fast internet (100 Mbit/s), rounded to 5 minutes: "etwa 25 Minuten".
    public static func durationText(_ bytes: Int64, bitsPerSecond: Double = 100e6) -> String {
        let minutes = Double(max(bytes, 0)) * 8 / bitsPerSecond / 60
        if minutes < 5 { return L("a few minutes", table: "Core") }
        if minutes < 90 { return L("about %lld minutes", table: "Core", Int((minutes / 5).rounded()) * 5) }
        let hours = Int((minutes / 60).rounded())
        return hours == 1 ? L("about an hour", table: "Core") : L("about %lld hours", table: "Core", hours)
    }
}
