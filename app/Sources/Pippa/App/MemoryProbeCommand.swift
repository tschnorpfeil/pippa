import Foundation
import PippaCore

/// `Pippa --memory-probe --from YYYY-MM-DD --to YYYY-MM-DD`: the memory experiment's aggregate report on stdout
/// (see `MemoryProbe`). Runs before any app setup: no window, model, download or permission prompt.
enum MemoryProbeCommand {
    static func run(_ arguments: [String]) async -> Int32 {
        let result = await MemoryProbe.execute(arguments, photos: .live, integrations: SystemIntegrations())
        if !result.stdout.isEmpty { print(result.stdout) }
        if !result.stderr.isEmpty { FileHandle.standardError.write(Data((result.stderr + "\n").utf8)) }
        return result.exitCode
    }
}
