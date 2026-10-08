import Foundation
import PippaCore

/// The one place where the UI picks an engine.
/// In the debug build `PippaEngineFactory.make()` returns the sample engine when `PIPPA_DEMO=1`;
/// the release build always takes the local one (no developer switch in the shipped app).
enum EngineShim {
    static func make() -> any PippaEngine {
        #if DEBUG
        if DevEnvironment.value("PIPPA_SNAPSHOT_ONLY") == "scans" {
            return LocalEngine(modelEnabled: false)
        }
        return PippaEngineFactory.make()
        #else
        LocalEngine()
        #endif
    }
}
