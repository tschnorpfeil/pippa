import PiRPC
import PippaCore

extension DateEvidence {
    /// Feeds one answer's Pi events in (`ChatModel`, `HeadlessAsk`).
    mutating func observe(_ event: PiRPCEvent) {
        switch event {
        case .toolStarted(let id, let name, let arguments, _):
            toolStarted(id: id, isWrite: PiTurnReceipt.pippaTool(name).map(PiTurnReceipt.pippaWriters.contains) ?? false, arguments: arguments)
        case .toolEnded(let id, _, let isError, let result, let outcome, _, _):
            toolEnded(id: id, done: !isError && (outcome ?? .done) == .done, result: result)
        default:
            break
        }
    }
}
