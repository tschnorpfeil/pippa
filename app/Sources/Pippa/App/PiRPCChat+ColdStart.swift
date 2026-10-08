import PippaCore

// Cold start of the local model, seen from the conversation: measured progress while the knowledge loads into memory,
// a short "almost ready" while Pippa's instructions are read once, and loading ahead of time when the pill or the
// conversation opens, so the first question often does not wait at all (ColdStart.swift).
extension PiRPCChat {
    /// Holds the server for one answer. If it has to load first, the thought line shows the measured progress
    /// (`.wakingUp`) and, once loaded, `.warmingUp` until the first words or tool arrive.
    static func lease(_ server: LlamaServer, onWork: WorkEventHandler?) async throws -> LlamaServer.AgentLease {
        guard await !server.isWarm else { return try await server.acquireAgentLease() }
        onWork?(.phase(.wakingUp(progress: nil)))
        let watch = Task {
            var tracker = ColdStart.Tracker()
            while !Task.isCancelled {
                if let sample = await server.coldStartSample(), let stage = tracker.update(sample) { onWork?(.phase(stage.phase)) }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { watch.cancel() }
        let lease = try await server.acquireAgentLease()
        // A late loading sample after this is dropped by the thought line (preparation order).
        onWork?(.phase(.warmingUp))
        return lease
    }

    private static var preload: Task<Void, Never>?

    /// The pill or the conversation opened: if the knowledge is not in memory, start loading it now. Unused, it is
    /// unloaded after the usual idle time. Nothing happens with an online service, before setup is done, or in
    /// debug captures; a question asked meanwhile waits for this same start (`LlamaServer.ensureRunning`).
    func preloadIfCold() {
        guard Self.isLive, Self.ownsLocalServer, Self.preload == nil, Self.statusForLocalEngine() == .ready else { return }
        Self.preload = Task {
            defer { Self.preload = nil }
            guard Self.onlineConnection == nil, let server = try? await localModelServer(),
                  await !server.isWarm else { return }
            DiagnosticsLog.shared.event("llama-vorladen")
            try? await server.ensureRunning()
        }
    }
}

extension AppModel {
    /// The answer under way is waiting for a cold start (`.wakingUp` / `.warmingUp`): the pill says so.
    var coldStartPhase: WorkPhase? {
        guard let phase = conversations.thought.phase, ColdStart.pillLabel(phase) != nil else { return nil }
        return phase
    }

    var coldStartPillLabel: String? { coldStartPhase.flatMap { ColdStart.pillLabel($0) } }
}
