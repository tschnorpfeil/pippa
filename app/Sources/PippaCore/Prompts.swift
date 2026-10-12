import Foundation

/// Fixed context for the model: persona plus short task rules. Must stay under 500 tokens.
public enum Prompts {
    public static let budget = 500

    /// Rough estimate: one token ≈ 4 characters.
    public static func estimateTokens(_ text: String) -> Int { (text.count + 3) / 4 }

    public static let persona: String = {
        guard let url = Bundle.module.url(forResource: "persona", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Du bist Pippa, eine kleine Helferin auf diesem Mac. Du antwortest kurz, genau und ratest nie."
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    /// The one fixed task left: classifying an unclear document while tidying (Apple's on-device model, `TidyClassifier`).
    /// Invoices, deadlines and letter checks are Pi conversations with skills now.
    public enum Task: CaseIterable, Sendable { case classify }

    static func rules(_ task: Task) -> String {
        PippaSkill.instructions(named: "dokument-einordnen") ?? "Antworte ausschließlich mit JSON nach Schema. Fehlt der Beleg, lass das Feld leer."
    }

    public static func system(_ task: Task) -> String { persona + "\n\n" + rules(task) }
}
