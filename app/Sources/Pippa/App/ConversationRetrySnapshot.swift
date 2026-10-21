import AppKit
import PippaCore

#if DEBUG
@MainActor private final class RetryFixtureChat: ConversationChat {
    var failNext = true
    var contexts: [ChatContext] = []
    var skills: [String?] = []
    func answer(_ text: String, taskID: String, context: ChatContext, newFiles: [URL], skill: PippaSkill?, draftOnly: Bool,
                onDelta: @escaping @Sendable (String) -> Void, onSteered: @escaping @Sendable (String) -> Void,
                onReset: (@Sendable (String) -> Void)?) async throws -> PiRPCChat.ShownAnswer {
        contexts.append(context); skills.append(skill?.name)
        if failNext { failNext = false; throw AnswerFailure.runtime("Synthetic retry failure") }
        return .init(text: "Synthetic verified answer", reviewed: false)
    }
    func steer(_ text: String) async -> Bool { false }
    func cancel() async {}
    func forget(_ keys: [String]) async {}
    func takeShownActions() -> ActionReceipt? { nil }
}

/// Exercises the real retry controller with isolated history and an injected failing chat, without Pi or native writes.
@MainActor enum ConversationRetrySnapshot {
    static func run(model: AppModel, directory: URL) async {
        var observations: [String] = []
        func verify(_ value: Bool, _ label: String) { observations.append("\(value ? "PASS" : "FAIL"): \(label)") }
        func report() {
            let passed = !observations.contains { $0.hasPrefix("FAIL:") }
            try? ((passed ? "PASS" : "FAIL") + ": conversation retry fixture\n" + observations.joined(separator: "\n") + "\n")
                .write(to: directory.appendingPathComponent("conversationretry.txt"), atomically: true, encoding: .utf8)
        }
        guard model.engine is StubEngine, DevSnapshot.directory?.standardizedFileURL == directory.standardizedFileURL else {
            verify(false, "Requires isolated demo history"); report(); return
        }
        let source = directory.appendingPathComponent("retry-source.txt")
        do { try "Synthetic source".write(to: source, atomically: true, encoding: .utf8) }
        catch { verify(false, "Creates synthetic source"); report(); return }
        model.newConversation()
        model.attach(.files([source]), items: [source], startsFresh: false, open: true)
        let controller = model.conversations
        let fixture = RetryFixtureChat()
        let skill = PippaSkill.parse("---\nname: antwort-schreiben\ndescription: Synthetic retry fixture\npippa-draft: true\n---", folder: "antwort-schreiben")
        func settle() async {
            for _ in 0..<200 {
                if !controller.isRunning { return }
                try? await Task.sleep(for: .milliseconds(20))
            }
            verify(false, "Controller settles within deadline")
            controller.stop()
        }
        controller.send("Prepare a synthetic reply", chat: fixture, skill: skill)
        await settle()
        let original = controller.current?.messages.first { $0.role == .user }?.id
        verify(original != nil && fixture.contexts.first?.nativeRequestID == original,
               "First native intent uses the persisted user message identity")
        verify(fixture.contexts.first?.nativeConversationID == controller.current?.id,
               "Native intent uses the actual conversation identity")
        if let notice = controller.failed?.notice { controller.retryFailed(notice: notice) }
        else { verify(false, "Failure exposes explicit retry") }
        await settle()
        verify(fixture.contexts.count == 2 && fixture.contexts.last?.nativeRequestID == original,
               "Explicit retry preserves native intent instead of creating another action")
        verify(fixture.skills == [skill?.name, skill?.name], "Retry preserves the chosen draft skill")
        verify(controller.error == nil && controller.failed == nil, "Retry finishes successfully")
        controller.send("Prepare a synthetic reply", chat: fixture, skill: skill)
        await settle()
        verify(fixture.contexts.count == 3 && fixture.contexts.last?.nativeRequestID != original,
               "A separately submitted identical question is a new intent")
        fixture.failNext = true
        controller.send("Use the synthetic source", chat: fixture)
        await settle()
        let calls = fixture.contexts.count
        do { try "Changed synthetic source contents".write(to: source, atomically: true, encoding: .utf8) }
        catch { verify(false, "Changes the synthetic source") }
        if let notice = controller.failed?.notice { controller.retryFailed(notice: notice) }
        else { verify(false, "Second failure exposes retry") }
        verify(fixture.contexts.count == calls && !controller.isRunning,
               "Changed source blocks automatic replay before any chat or tool request")
        verify(controller.failed == nil && controller.current?.messages.last?.role == .system,
               "Changed source presents a fresh-request explanation")
        model.newConversation()
        fixture.failNext = true
        controller.send("Describe a synthetic app source", chat: fixture,
                        frontApp: FrontApp(name: "Synthetic app", bundleID: "test.pippa.retry", pid: 0, title: "Original source"))
        await settle()
        let frontCalls = fixture.contexts.count
        if let notice = controller.failed?.notice { controller.retryFailed(notice: notice) }
        else { verify(false, "Live source failure exposes recovery") }
        verify(fixture.contexts.count == frontCalls && !controller.isRunning,
               "An unverified live app source requires a fresh request instead of silently reading another document")
        report()
    }
}
#endif
