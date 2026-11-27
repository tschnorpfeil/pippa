import AppKit
import Combine
import PiRPC

/// Parsed options for a `select` question, shared by `QuestionCard` and `IslandQuestionAnswers`.
/// Recognizes `ask.ts`'s trailing `otherChoice` sentinel ("Something else…" / "Etwas anderes …") so both views render
/// the real choices directly alongside an inline free-text field without a second `ui.input` round-trip.
struct ApprovalChoices: Equatable {
    static let otherSentinels: Set<String> = [
        "Something else…",
        "Something else...",
        "Etwas anderes …",
        "Etwas anderes…",
        "Etwas anderes...",
    ]

    /// The real selectable choices (excluding any trailing `otherChoice` sentinel).
    let options: [String]
    /// Whether the person can type their own answer inline on the same card.
    let allowsCustomText: Bool
    /// The original sentinel label when present.
    let customPrompt: String?

    static func parse(_ rawOptions: [String]) -> ApprovalChoices {
        guard let last = rawOptions.last else {
            return ApprovalChoices(options: [], allowsCustomText: false, customPrompt: nil)
        }
        let trimmedLast = last.trimmingCharacters(in: .whitespacesAndNewlines)
        if otherSentinels.contains(trimmedLast) {
            return ApprovalChoices(options: Array(rawOptions.dropLast()), allowsCustomText: true, customPrompt: trimmedLast)
        }
        return ApprovalChoices(options: rawOptions, allowsCustomText: false, customPrompt: nil)
    }

    /// Trims free-text input and rejects empty or whitespace-only answers.
    static func validatedText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A compact, read-only record of a Pi question and how the person answered or cancelled it, saved on `ChatMessage`.
struct AnsweredQuestion: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, Equatable {
        case confirm
        case select
        case input
    }

    enum Outcome: String, Codable, Equatable {
        case allowed
        case declined
        case answered
        case cancelled
    }

    var id: String
    var kind: Kind
    var title: String
    var detail: String?
    var answer: String?
    var outcome: Outcome
    var answeredAt: Date

    @MainActor
    static func from(_ question: Approvals.Question, response: PiUIResponse, at date: Date = Date()) -> AnsweredQuestion {
        let request = question.request
        let parsed = ApprovalPresentation.parse(request)
        let kind: Kind = switch request.method {
        case "confirm": .confirm
        case "select": .select
        default: .input
        }
        let outcome: Outcome
        let answerText: String?
        switch response {
        case .confirmed(true):
            outcome = .allowed
            answerText = Confirmations.confirmLabels(request).yes
        case .confirmed(false):
            outcome = .declined
            answerText = Confirmations.confirmLabels(request).no
        case .value(let raw):
            if let trimmed = ApprovalChoices.validatedText(raw) {
                outcome = .answered
                answerText = trimmed
            } else {
                outcome = .cancelled
                answerText = nil
            }
        case .cancelled:
            outcome = .cancelled
            answerText = nil
        }
        return AnsweredQuestion(
            id: question.id,
            kind: kind,
            title: parsed.title,
            detail: parsed.summary,
            answer: answerText,
            outcome: outcome,
            answeredAt: date
        )
    }

    /// Localized display label for the outcome badge in the transcript.
    var displayAnswer: String {
        switch outcome {
        case .allowed: answer ?? T("Allowed", table: "Views")
        case .declined: answer ?? T("Declined", table: "Views")
        case .answered: answer ?? ""
        // A cancellation may carry its reason ("Follow-up sent"); a plain one says "Cancelled".
        case .cancelled: answer ?? T("Cancelled", table: "Views")
        }
    }
}

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
    /// Called whenever an open question is answered or cancelled so the chat can keep a read-only record.
    var onAnswered: (@MainActor (Question, AnsweredQuestion) -> Void)?
    private var waiting: [String: CheckedContinuation<PiUIResponse, Never>] = [:]
    private var presenters: [String: Int] = [:]
    private var reveals: [String: () -> Void] = [:]
    private var answerWatch: AnyCancellable?

    private init() {
        onAnswered = { question, record in
            ChatModel.shared.recordAnsweredQuestion(record, in: question.conversationID)
        }
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

    /// The person's answer; a question already answered or cancelled is ignored. `note`: the reason a cancellation
    /// keeps in its record instead of a plain "Cancelled".
    func answer(_ id: String, _ response: PiUIResponse, note: String? = nil) {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        let removed = questions.first { $0.id == id }
        questions.removeAll { $0.id == id }
        if let removed {
            var record = AnsweredQuestion.from(removed, response: response)
            if let note, record.outcome == .cancelled { record.answer = note }
            onAnswered?(removed, record)
        }
        continuation.resume(returning: response)
    }

    /// Whether `conversationID` (or any conversation when `nil`) currently has an open question waiting for the person.
    func hasOpenQuestions(in conversationID: String?) -> Bool {
        questions.contains { conversationID == nil || $0.conversationID == conversationID }
    }

    /// The person sent a follow-up into the running answer (`ChatModel.steer`): its open questions are stale, so they
    /// are cancelled (never allowed) and Pi reads the follow-up right away. Only questions of `conversationID` when given.
    func cancelForSteer(in conversationID: String?) {
        for question in questions where conversationID == nil || question.conversationID == conversationID {
            answer(question.id, .cancelled, note: T("Follow-up sent", table: "App"))
        }
    }

    func cancelAll() {
        for question in questions { answer(question.id, .cancelled) }
    }
}
