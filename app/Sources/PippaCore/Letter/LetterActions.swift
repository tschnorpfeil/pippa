import Foundation

// Actions on the letter: immediately the type actions from code (Explain · Reply · Add the date, ordered by
// habit), later the ones the model suggests, in the same slots. Model suggestions are
// unreliable input: only ids from the catalog, button texts always from the catalog, never from the model.

/// A button under the first line. `id` is the identifier in the task log.
public struct LetterAction: Sendable, Hashable, Identifiable {
    public enum Handler: Sendable, Hashable { case skill(String), addDate }
    /// „explain“ | „reply“ | „object“ | „cancel“ | „summarize“ | „add-date“
    public var id: String
    public var handler: Handler
    public var title: String
    /// Line during work: "Writing the reply …"
    public var workingTitle: String
    /// Text sent with the capability; appears as the person's message when handed over to the conversation.
    public var instruction: String
    /// One word from the model (tooltip only).
    public var reason: String?
    /// Suggested by the model (otherwise from code).
    public var proposed: Bool
    /// Reply, objection, cancellation: draft in the line. The others move into the conversation.
    public var writesDraft: Bool

    public init(id: String, handler: Handler, title: String, workingTitle: String, instruction: String, reason: String?,
                proposed: Bool, writesDraft: Bool) {
        self.id = id; self.handler = handler; self.title = title; self.workingTitle = workingTitle
        self.instruction = instruction; self.reason = reason; self.proposed = proposed; self.writesDraft = writesDraft
    }
}

public enum LetterActions {
    public static let ids: [String] = ["explain", "reply", "object", "cancel", "summarize", "add-date"]
    /// Type actions for mail and letter.
    static let fallbackIDs: [String] = ["explain", "reply", "add-date"]
    /// At most this many suggested actions.
    static let maxProposed = 3

    /// To the model, in English (not translated): together with the capability `aktionen-vorschlagen`.
    public static let proposePrompt = "Which next steps fit this mail or letter? Propose up to three."

    /// To the model, in English (not translated): together with the capability `online-pruefen`.
    public static func checkPrompt(statement: String) -> String {
        "Check online, preferring primary sources (laws, government agencies, the issuing authority) of the person’s country and naming the source, whether this is right in general: " + statement
    }

    /// All actions in the order of `ids`; if a capability is missing, its action is dropped.
    public static func catalog(skills: [PippaSkill] = PippaSkill.bundled) -> [LetterAction] {
        let names = Set(skills.map(\.name))
        return entries().filter { entry in
            guard case .skill(let name) = entry.handler else { return true }
            return names.contains(name)
        }
    }

    /// Type actions (Explain · Reply · Add the date), ordered by habit, at most three.
    public static func fallback(kind: TaskKind, source: String?, records: [TaskRecord], now: Date = Date(),
                                skills: [PippaSkill] = PippaSkill.bundled) -> [LetterAction] {
        let available = catalog(skills: skills)
        let present = fallbackIDs.filter { id in available.contains { $0.id == id } }
        let ordered = Habits.arrange(present, kind: kind, source: source, in: records, now: now)
        return ordered.compactMap { id in available.first { $0.id == id } }
    }

    /// What the model may suggest, with English texts for the model (not translated, never shown).
    public static func allowedForAgent(skills: [PippaSkill] = PippaSkill.bundled) -> [AgentActionChoice] {
        catalog(skills: skills).compactMap { action in
            guard let text = agentText(action.id) else { return nil }
            return AgentActionChoice(id: action.id, label: text.label, does: text.does)
        }
    }

    /// Checks the model's suggestions: only known ids, each once, at most three. Button texts and instructions
    /// come from the catalog; from the model only the choice, the order and a word as reason remain. `nil` if nothing is left
    /// (then the type actions stay).
    public static func validated(_ proposals: [AgentActionProposal], skills: [PippaSkill] = PippaSkill.bundled) -> [LetterAction]? {
        let available = catalog(skills: skills)
        var seen = Set<String>()
        var out: [LetterAction] = []
        for proposal in proposals {
            if out.count >= maxProposed { break }
            let id = proposal.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let base = available.first(where: { $0.id == id }), seen.insert(id).inserted else { continue }
            var action = base
            // The instruction stays the catalog's: text from the model is unreliable (the letter may have steered it)
            // and would otherwise appear as the person's message in the conversation for explain and summarize.
            action.reason = cleanReason(proposal.reason)
            action.proposed = true
            out.append(action)
        }
        return out.isEmpty ? nil : out
    }

    // MARK: Helpers

    /// One word, at most 24 characters.
    static func cleanReason(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let spaced = text.contains { $0.isWhitespace }
        guard !text.isEmpty, text.count <= 24, !spaced else { return nil }
        return text
    }

    /// English texts for the model per id.
    static func agentText(_ id: String) -> (label: String, does: String)? {
        switch id {
        case "explain": return ("Explain", "Explain the letter in plain words: who wrote, what they want, what matters")
        case "reply": return ("Reply", "Write a short, polite reply to the sender")
        case "object": return ("Object", "Write an objection, e.g. against a tax notice or a bill")
        case "cancel": return ("Cancel", "Write a cancellation of a contract, membership or subscription")
        case "summarize": return ("Summarise", "Summarise the letter in a few sentences")
        case "add-date": return ("Add the date", "Put a deadline or appointment from the letter into Calendar or Reminders")
        default: return nil
        }
    }

    /// The whole catalog, regardless of available capabilities. Texts in the UI language.
    static func entries() -> [LetterAction] {
        let explain = LetterAction(
            id: "explain", handler: .skill("brief-verstehen"),
            title: L("Explain", table: "Letter"),
            workingTitle: L("Reading the letter …", table: "Letter"),
            instruction: L("Please explain this letter in plain words.", table: "Letter"),
            reason: nil, proposed: false, writesDraft: false)
        let reply = LetterAction(
            id: "reply", handler: .skill("antwort-schreiben"),
            title: L("Reply", table: "Letter"),
            workingTitle: L("Writing the reply …", table: "Letter"),
            instruction: L("Please write a short, polite reply to this mail.", table: "Letter"),
            reason: nil, proposed: false, writesDraft: true)
        let object = LetterAction(
            id: "object", handler: .skill("antwort-schreiben"),
            title: L("Object", table: "Letter"),
            workingTitle: L("Writing the objection …", table: "Letter"),
            instruction: L("Please write an objection to this letter.", table: "Letter"),
            reason: nil, proposed: false, writesDraft: true)
        let cancel = LetterAction(
            id: "cancel", handler: .skill("antwort-schreiben"),
            title: L("Cancel", table: "Letter"),
            workingTitle: L("Writing the cancellation …", table: "Letter"),
            instruction: L("Please write a cancellation for this contract.", table: "Letter"),
            reason: nil, proposed: false, writesDraft: true)
        let summarize = LetterAction(
            id: "summarize", handler: .skill("zusammenfassen"),
            title: L("Summarise", table: "Letter"),
            workingTitle: L("Summarising …", table: "Letter"),
            instruction: L("Please summarise this in a few sentences.", table: "Letter"),
            reason: nil, proposed: false, writesDraft: false)
        let addDate = LetterAction(
            id: "add-date", handler: .addDate,
            title: L("Add the date", table: "Letter"),
            workingTitle: L("Looking for the date …", table: "Letter"),
            instruction: L("Please add the date from this letter.", table: "Letter"),
            reason: nil, proposed: false, writesDraft: false)
        return [explain, reply, object, cancel, summarize, addDate]
    }
}
