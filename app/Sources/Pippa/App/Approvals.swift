import AppKit
import Combine
import PiRPC

/// Questions Pi's extensions ask during an answer ("May Pippa search the web?"), answered inside Pippa instead of a
/// modal alert. Views that can show them (the chat transcript, the island) register as presenters while they are on
/// screen; without one, the question falls back to the plain alert in `Confirmations`, so nothing waits unseen.
@MainActor
final class Approvals: ObservableObject {
    static let shared = Approvals()

    struct Question: Identifiable, Equatable {
        let id: String
        let request: PiUIRequest
        /// The conversation whose answer asked, if one was running.
        let conversationID: String?
        let asked: Date
    }

    /// Open questions, oldest first.
    @Published private(set) var questions: [Question] = []
    private var waiting: [String: CheckedContinuation<PiUIResponse, Never>] = [:]
    private var presenters: [String: Int] = [:]
    private var reveals: [String: () -> Void] = [:]
    private var answerWatch: AnyCancellable?

    private init() {
        // An answer that ends (finished, stopped, failed) takes its open questions with it.
        answerWatch = ChatModel.shared.$isAnswering.removeDuplicates().sink { [weak self] answering in
            if !answering { self?.cancelAll() }
        }
    }

    /// A view that shows questions calls this when it appears, with a stable name ("chat", "island"). `reveal` brings
    /// it in front of the person when a question arrives (the chat window comes forward, the island opens): a view can
    /// be on screen and still hidden behind other windows.
    func present(_ name: String, reveal: (() -> Void)? = nil) {
        presenters[name, default: 0] += 1
        if let reveal { reveals[name] = reveal }
    }
    /// The matching call when that view disappears. When the last one goes (a new conversation replaced the transcript)
    /// and no view takes over within the same turn, the open questions go to the alert, so none waits unseen.
    func dismiss(_ name: String) {
        guard let count = presenters[name] else { return }
        presenters[name] = count > 1 ? count - 1 : nil
        if presenters[name] == nil { reveals[name] = nil }
        if presenters.isEmpty, !questions.isEmpty { Task { @MainActor in self.handOver() } }
    }
    var hasPresenter: Bool { !presenters.isEmpty }

    /// Asks when no view can: the alert. `--check-approvals` puts a stand-in here.
    var fallback: @MainActor (PiUIRequest) -> PiUIResponse = Confirmations.alert

    private func handOver() {
        guard presenters.isEmpty else { return }
        for question in questions where waiting[question.id] != nil { answer(question.id, fallback(question.request)) }
    }

    /// Asks inside Pippa when a presenter is on screen, otherwise with an alert. Pi's own timeout cancels the question.
    func ask(_ request: PiUIRequest) async -> PiUIResponse {
        guard hasPresenter else { return fallback(request) }
        let question = Question(id: request.id, request: request, conversationID: ChatModel.shared.answeringID, asked: Date())
        if let timeout = request.timeout, timeout > 0 {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(timeout))
                self?.answer(question.id, .cancelled)
            }
        }
        return await withCheckedContinuation { continuation in
            waiting[question.id] = continuation
            questions.append(question)
            for reveal in reveals.values { reveal() }
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
    }

    /// The person's answer; a question already answered or cancelled is ignored.
    func answer(_ id: String, _ response: PiUIResponse) {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        questions.removeAll { $0.id == id }
        continuation.resume(returning: response)
    }

    func cancelAll() {
        for question in questions { answer(question.id, .cancelled) }
    }
}
