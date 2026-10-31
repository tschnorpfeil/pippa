import Foundation
import PippaCore

/// Memory pressure and the memory check before loading (PippaCore/MemoryHeadroom.swift, docs/next-level-plan-2026-10-30.md
/// §2 rows 3–4 and §3): refusal only under critical pressure (a preload follows the same rule), what a pressure event does
/// in each server state, and which PID a pressure unload of the terminal's server may signal. Pure inputs, no real pressure.
func runPressureChecks() {
    check("Memory check: a load is refused only under critical pressure, tight headroom is only logged") {
        MemoryGate.load(pressure: .critical, headroomGiB: 40, tier: 32) == .refuse
            && MemoryGate.load(pressure: .warning, headroomGiB: 0.5, tier: 8) == .tight
            && MemoryGate.load(pressure: .normal, headroomGiB: 5.1, tier: 8) == .tight
            && MemoryGate.load(pressure: .normal, headroomGiB: 5.2, tier: 8) == .ok
            && MemoryGate.load(pressure: .normal, headroomGiB: 7.9, tier: 16) == .tight
            && MemoryGate.load(pressure: .normal, headroomGiB: 8, tier: 24) == .ok
            && MemoryGate.load(pressure: .normal, headroomGiB: 18, tier: 32) == .tight
    }

    check("Pressure: critical acts in every state, also on a load under way and on the terminal's server") {
        MemoryGate.onPressure(.critical, server: .starting, busy: true, slotsActive: true) == .abortStart
            && MemoryGate.onPressure(.critical, server: .owned, busy: true, slotsActive: true) == .unload(saveSlot: false)
            && MemoryGate.onPressure(.critical, server: .adopted, busy: true, slotsActive: false) == .terminateAdopted
            && MemoryGate.onPressure(.critical, server: .stopped, busy: false, slotsActive: false) == .none
    }

    check("Pressure: warning unloads only without a request in flight and never aborts a load") {
        MemoryGate.onPressure(.warning, server: .starting, busy: false, slotsActive: true) == .none
            && MemoryGate.onPressure(.warning, server: .owned, busy: true, slotsActive: true) == .none
            && MemoryGate.onPressure(.warning, server: .owned, busy: false, slotsActive: true) == .unload(saveSlot: true)
            && MemoryGate.onPressure(.warning, server: .owned, busy: false, slotsActive: false) == .unload(saveSlot: false)
            && MemoryGate.onPressure(.warning, server: .adopted, busy: true, slotsActive: false) == .none
            && MemoryGate.onPressure(.warning, server: .adopted, busy: false, slotsActive: false) == .terminateAdopted
            && MemoryGate.onPressure(.normal, server: .owned, busy: false, slotsActive: true) == .none
    }

    check("Pressure: only the terminal's server PID on our port is signalled, never its supervisor or another app's server") {
        let pi = PiServerLock(owner: "pi", holder: 4100, pid: 4200, port: 8191)
        var app = pi; app.owner = "app"
        var starting = pi; starting.pid = nil
        var otherPort = pi; otherPort.port = 8192
        var me = pi; me.pid = getpid()
        return MemoryGate.adoptedTarget(pi, port: 8191) == 4200
            && MemoryGate.adoptedTarget(app, port: 8191) == nil
            && MemoryGate.adoptedTarget(starting, port: 8191) == nil
            && MemoryGate.adoptedTarget(otherPort, port: 8191) == nil
            && MemoryGate.adoptedTarget(me, port: 8191) == nil
            && MemoryGate.adoptedTarget(nil, port: 8191) == nil
    }

    check("Memory check: the snapshot reads a level and plausible headroom on this Mac") {
        let headroom = MemoryHeadroom.current()
        return PressureLevel.allCases.contains(headroom.pressure) && headroom.availableBytes > 0
            && headroom.availableBytes <= ProcessInfo.processInfo.physicalMemory
    }

    check("Memory check: the refusal has plain words in both languages") {
        let key = "Your Mac is short on memory right now. Close a few apps or browser windows, then try again."
        return L(key, table: "Core", language: "en") == key
            && L(key, table: "Core", language: "de") == "Dein Mac hat gerade zu wenig Arbeitsspeicher frei. Schließ ein paar Apps oder Browserfenster und versuch es dann noch einmal."
            && PippaError.notEnoughMemory.errorDescription?.isEmpty == false
    }
}
