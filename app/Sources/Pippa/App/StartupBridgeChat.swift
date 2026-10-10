import Foundation
import PippaCore

/// Who answers while Pippa's own AI is still being set up or loaded (setup gate `.wait`), and the first message after it
/// (StartupBridge.swift). Plain questions get a short answer from the system model right away; everything else shows
/// "I’m almost ready", waits for Pi and then goes there, together with what was answered in between. Stop works
/// throughout. The message is in the conversation from the start, so nobody has to type it twice.
@MainActor
final class StartupBridgeChat: ConversationChat {
    static let shared = StartupBridgeChat()

    /// Quick exchanges per conversation (Pippa's id without revision) that Pi has not seen yet. In memory only:
    /// after a restart Pi simply starts without them.
    private var pending: [String: [StartupBridge.Turn]] = [:]
    /// Pi, once the message went there (for Stop, steering and what the tools did).
    private var delegated: (any ConversationChat)?
    private var cancelled = false
    private weak var model: AppModel?

    func connect(_ model: AppModel) { self.model = model }

    /// Is this conversation still owed a hand-over to Pi?
    func hasPending(conversation: UUID) -> Bool { !(pending[conversation.uuidString]?.isEmpty ?? true) }

    /// Apple Intelligence is on, ready and speaks German (checks: never, `PIPPA_NO_SYSTEM_MODEL`).
    static var systemModelAvailable: Bool { TidyClassifier.appleAvailable }

    func answer(_ text: String, taskID: String, context: ChatContext, newFiles: [URL], skill: PippaSkill?, draftOnly: Bool,
                onDelta: @escaping @Sendable (String) -> Void, onSteered: @escaping @Sendable (String) -> Void,
                onReset: (@Sendable (String) -> Void)?) async throws -> PiRPCChat.ShownAnswer {
        cancelled = false
        delegated = nil
        let key = String(taskID.prefix { $0 != ":" })
        let language = Bundle.module.preferredLocalizations.first ?? "en"
        if model?.piSetupGate == .wait {
            let route = StartupBridge.route(text, hasFiles: !context.files.isEmpty || !newFiles.isEmpty, selectedText: context.selectedText,
                                            skill: skill != nil, systemModel: Self.systemModelAvailable)
            if route == .quick, let system = AppleQuickModel.system,
               let answer = try await quick(text, key: key, language: language, context: context, system: system, onDelta: onDelta) {
                pending[key, default: []].append(StartupBridge.Turn(person: text, pippa: answer))
                DiagnosticsLog.shared.event("start-bruecke", ["weg": "apple"])
                return PiRPCChat.ShownAnswer(text: answer, reviewed: false)
            }
            DiagnosticsLog.shared.event("start-bruecke", ["weg": "warten"])
            model?.startupBridgeWaits()
            context.onWork?(.phase(.gettingReady))
            try await waitForSetup()
        }
        // Pi is ready: the new message, with what was answered in between.
        let history = pending.removeValue(forKey: key) ?? []
        let chat = PiRPCChat.conversation
        delegated = chat
        do {
            return try await chat.answer(StartupBridge.handover(text, history: history, language: language), taskID: taskID, context: context,
                                         newFiles: newFiles, skill: skill, draftOnly: draftOnly, onDelta: onDelta, onSteered: onSteered, onReset: onReset)
        } catch {
            // Not delivered: the next message hands it over again.
            if !history.isEmpty { pending[key] = history + (pending[key] ?? []) }
            throw error
        }
    }

    /// The system model's short answer; `nil`: it handed over (needs tools or is unsure), declined or failed.
    /// The first words are kept back until it is clear it is a real answer, so the hand-over token never shows.
    private func quick(_ text: String, key: String, language: String, context: ChatContext, system: AppleQuickModel,
                       onDelta: @escaping @Sendable (String) -> Void) async throws -> String? {
        context.onWork?(.phase(.waitingForAnswer(continuing: false)))
        let stream = system.stream(instructions: StartupBridge.instructions(language: language, today: Date()),
                                   prompt: StartupBridge.prompt(text, selectedText: context.selectedText, history: pending[key] ?? [], language: language),
                                   maximumTokens: StartupBridge.maximumTokens)
        var full = ""
        var shown = false
        do {
            for try await chunk in stream {
                if cancelled { throw CancellationError() }
                full += chunk
                if shown { onDelta(chunk); continue }
                switch StartupBridge.opening(full) {
                case .undecided: continue
                case .deferred: return nil
                case .answer:
                    shown = true
                    onDelta(full)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Declined or failed: what was already shown stays if it is a real answer, otherwise Pi answers.
            guard shown, full.count >= 40 else { return nil }
            return StartupBridge.cleaned(full)
        }
        if cancelled { throw CancellationError() }
        guard StartupBridge.opening(full) == .answer else { return nil }
        if !shown { onDelta(full) }
        return StartupBridge.cleaned(full)
    }

    /// Until setup opens the conversation. A download question or an error ends the wait with setup's own sentence.
    private func waitForSetup() async throws {
        while true {
            if cancelled { throw CancellationError() }
            switch model?.piSetupGate ?? .open {
            case .open: return
            case .wait: try await Task.sleep(for: .milliseconds(500))
            case .showSetup:
                model?.startupBridgeNeedsSetup()
                throw PiRPCChat.Failure.setup("setup needs the person while a message waited")
            }
        }
    }

    func steer(_ text: String) async -> Bool {
        guard let delegated else { return false }
        return await delegated.steer(text)
    }

    func cancel() async {
        cancelled = true
        await delegated?.cancel()
    }

    func forget(_ keys: [String]) async {
        for key in keys { pending[String(key.prefix { $0 != ":" })] = nil }
    }

    func takeSearchFiles() -> [URL] { delegated?.takeSearchFiles() ?? [] }
    func takeShownActions() -> ActionReceipt? { delegated?.takeShownActions() }
}
