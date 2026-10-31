import Foundation

/// Conditions of the Mac that make loading ahead of time a bad idea: it is already hot (`thermalState`), or the
/// person chose to save battery (Low Power Mode). Read when needed; the decision is `MemoryGate.preload`.
public struct HostConditions: Sendable, Equatable {
    public var thermal: ProcessInfo.ThermalState
    public var lowPower: Bool

    public init(thermal: ProcessInfo.ThermalState, lowPower: Bool) {
        self.thermal = thermal; self.lowPower = lowPower
    }

    public static func current() -> HostConditions {
        let info = ProcessInfo.processInfo
        return HostConditions(thermal: info.thermalState, lowPower: info.isLowPowerModeEnabled)
    }

    /// Name in the diagnostics log.
    public static func logName(_ thermal: ProcessInfo.ThermalState) -> String {
        switch thermal {
        case .nominal: "normal"
        case .fair: "erhoeht"
        case .serious: "hoch"
        case .critical: "kritisch"
        @unknown default: "unbekannt"
        }
    }
}
