import Foundation
import PippaCore

#if DEBUG
/// Controller races with an invented answer and journal. No file change is executed.
@MainActor enum ConversationStopSnapshot {
    @MainActor private final class Chat: ConversationChat {
        var answers = 0
        var collections = 0
        func answer(_ text: String, taskID: String, context: ChatContext, newFiles: [URL], skill: PippaSkill?, draftOnly: Bool,
                    onDelta: @escaping @Sendable (String) -> Void, onSteered: @escaping @Sendable (String) -> Void,
                    onReset: (@Sendable (String) -> Void)?) async throws -> PiRPCChat.ShownAnswer {
            answers += 1
            onDelta("Synthetic accepted answer")
            return PiRPCChat.ShownAnswer(text: "Synthetic completed answer", reviewed: false)
        }
        func steer(_ text: String) async -> Bool { false }
        func cancel() async {}
        func forget(_ keys: [String]) async {}
        func takeShownActions() -> ActionReceipt? { nil }
        func takeChanges() -> [AgentChange] {
            collections += 1
            return collections == 1 ? [AgentChange(kind: .create, from: nil, to: "/synthetic/no-file-is-created.txt")] : []
        }
    }

    @MainActor private final class Journal {
        let receipt = UUID()
        var calls = 0
        var changes: [AgentChange] = []
        var waiting: Bool { continuation != nil }
        private var continuation: CheckedContinuation<UUID?, Never>?
        private var released = false
        func record(_ changes: [AgentChange]) async -> UUID? {
            calls += 1
            self.changes += changes
            if released { return receipt }
            return await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            released = true
            continuation?.resume(returning: receipt)
            continuation = nil
        }
    }

    static func run(model: AppModel) async -> [String] {
        guard model.engine is StubEngine, DevSnapshot.directory != nil else {
            return ["Stop startup/journal fixture requires an isolated demo capture"]
        }
        let controller = model.conversations
        let previousRecorder = controller.recordChanges
        defer { controller.recordChanges = previousRecorder }
        var failures: [String] = []
        func verify(_ condition: Bool, _ note: String) { if !condition { failures.append(note) } }
        func settle() async {
            for _ in 0..<200 {
                if !controller.isRunning { return }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        controller.recordChanges = { _ in nil }
        model.newConversation()
        let immediate = Chat()
        controller.send("Synthetic immediate Stop", chat: immediate)
        controller.stop()
        await settle()
        verify(!controller.isRunning && immediate.answers == 0, "Stop before scheduled answer still invoked its engine")

        model.newConversation()
        let chat = Chat(), journal = Journal()
        controller.recordChanges = { await journal.record($0) }
        controller.send("Synthetic Stop during journal", chat: chat)
        for _ in 0..<200 {
            if journal.waiting { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        verify(journal.waiting && controller.isRunning, "Journal did not suspend after the synthetic answer")
        controller.stop()
        journal.release()
        await settle()
        verify(!controller.isRunning && journal.calls == 1 && chat.collections == 1 && journal.changes.count == 1,
               "Stop during journaling drained or recorded the changes more than once")
        verify(controller.current?.messages.last?.receipt == journal.receipt,
               "Stop during journaling lost the completed Undo receipt")
        return failures
    }
}
#endif
