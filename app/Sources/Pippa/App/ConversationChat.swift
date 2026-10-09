import Foundation
import PippaCore

/// Who answers a message in the conversation: the real Pi (`PiRPCChat`, in every release build), in debug captures
/// without `PIPPA_PI_RPC=1` a stand-in (`SnapshotChat`). `ConversationController` and `LetterController` know only this.
@MainActor
protocol ConversationChat: AnyObject {
    /// Answer with what this message showed (`PiRPCChat+Shown.swift`). `newFiles`: newly shown in this message;
    /// `skill`: chosen skill; `draftOnly`: the text lands in Pippa's own line (letter draft).
    func answer(_ text: String, taskID: String, context: ChatContext, newFiles: [URL], skill: PippaSkill?, draftOnly: Bool,
                onDelta: @escaping @Sendable (String) -> Void, onSteered: @escaping @Sendable (String) -> Void,
                onReset: (@Sendable (String) -> Void)?) async throws -> PiRPCChat.ShownAnswer
    /// Submit a message during the running answer. `false`: not accepted, later as its own message.
    func steer(_ text: String) async -> Bool
    func cancel() async
    /// Conversation deleted: remove the history of these identifiers (`uuid`, `uuid:revision`).
    func forget(_ keys: [String]) async
    /// What tools did in the last answer, once; `nil` if nothing.
    func takeSearchFiles() -> [URL]
    func takeShownActions() -> ActionReceipt?
}

extension ConversationChat {
    func takeSearchFiles() -> [URL] { [] }
}

extension PiRPCChat: ConversationChat {
    /// The conversation path of this app run.
    static var conversation: any ConversationChat {
        #if DEBUG
        if !isLive { return SnapshotChat.shared }
        #endif
        return shared
    }
}

#if DEBUG
/// Debug captures without a real Pi: every message gets the sample answer or the capture's script. Starts nothing,
/// reads and writes nothing outside the capture.
@MainActor
final class SnapshotChat: ConversationChat {
    static let shared = SnapshotChat()
    /// A capture's answer to (message, conversation identifier, shown items). The script streams its text itself via
    /// `onDelta` and returns it whole; `nil`: the sample answer.
    typealias Script = @Sendable (_ text: String, _ taskID: String, _ context: ChatContext,
                                  _ onDelta: @escaping @Sendable (String) -> Void) async throws -> String?
    var script: Script?
    /// "Stop" of a capture (e.g. release a held answer).
    var onCancel: (@Sendable () async -> Void)?

    init(script: Script? = nil, onCancel: (@Sendable () async -> Void)? = nil) {
        self.script = script; self.onCancel = onCancel
    }

    func answer(_ text: String, taskID: String, context: ChatContext, newFiles: [URL], skill: PippaSkill?, draftOnly: Bool,
                onDelta: @escaping @Sendable (String) -> Void, onSteered: @escaping @Sendable (String) -> Void,
                onReset: (@Sendable (String) -> Void)?) async throws -> PiRPCChat.ShownAnswer {
        if let script, let answer = try await script(text, taskID, context, onDelta) {
            return PiRPCChat.ShownAnswer(text: answer, reviewed: false)
        }
        let answer = StubEngine.sampleAnswer
        onDelta(answer)
        return PiRPCChat.ShownAnswer(text: answer, reviewed: false)
    }
    func steer(_ text: String) async -> Bool { false }
    func cancel() async { await onCancel?() }
    func forget(_ keys: [String]) async {}
    func takeShownActions() -> ActionReceipt? { nil }
}
#endif
