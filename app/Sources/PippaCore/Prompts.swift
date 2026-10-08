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

    public enum Task: CaseIterable, Sendable { case classify, invoice, deadlines, deadlineCalculation }

    static func rules(_ task: Task) -> String {
        let name: String
        switch task {
        case .classify: name = "dokument-einordnen"
        case .invoice: name = "rechnung-auslesen"
        case .deadlines: name = "fristen-erkennen"
        case .deadlineCalculation: name = "frist-berechnen"
        }
        return PippaSkill.instructions(named: name) ?? "Antworte ausschließlich mit JSON nach Schema. Fehlt der Beleg, lass das Feld leer."
    }

    public static func invoiceRepair(prompt: String, amount: String, evidence: String) -> String {
        prompt + "\n\nDie Belegprüfung war unvollständig. Deine vorige Antwort: betrag=\(amount), beleg=\(evidence). Kopiere die vollständige Belegstelle einschließlich Summenwort und Zahl; bei Zeilenumbruch beide Zeilen. Antworte neu im Schema."
    }

    public static func system(_ task: Task) -> String { persona + "\n\n" + rules(task) }

    public static let deadlinesSchema = #"""
    {"type":"object","properties":{"items":{"type":"array","maxItems":12,"items":{"type":"object","properties":{
    "kind":{"type":"string","enum":["payment","cancellation","objection","appointment","debit","contractEnd","generic"]},
    "datum":{"type":"string"},"title":{"type":"string"},"quote":{"type":"string"},"page":{"type":"integer","minimum":1},
    "note":{"type":"string"},"sender":{"type":"string"},"documentKind":{"type":"string"}},
    "required":["kind","datum","title","quote","page","note","sender","documentKind"],"additionalProperties":false}}},
    "required":["items"],"additionalProperties":false}
    """#

    public static let deadlineCalculationSchema = #"""
    {"type":"object","properties":{"baseID":{"type":"string"},"unit":{"type":"string","enum":["days","weeks","months","years"]},"amount":{"type":"integer","minimum":-365,"maximum":365}},"required":["baseID","unit","amount"],"additionalProperties":false}
    """#

    // MARK: JSON schemas (as text so they are Sendable)

    public static let classifySchema = #"""
    {"type":"object","properties":{"kategorie":{"type":"string","enum":["rechnung","vertrag","brief","sonstiges"]},
    "absender":{"type":"string"},"art":{"type":"string"},"datum":{"type":"string"},"betreff":{"type":"string"},
    "entwurf":{"type":"boolean"},"entwurf_beleg":{"type":"string"},"beleg":{"type":"string"}},"required":["kategorie","absender","art","datum","betreff","entwurf","entwurf_beleg","beleg"],"additionalProperties":false}
    """#

    public static let invoiceSchema = #"""
    {"type":"object","properties":{"typ":{"type":"string","enum":["rechnung","gutschrift","mahnung","keine_rechnung"]},
    "datum":{"type":"string"},"absender":{"type":"string"},"betrag":{"type":"string"},"beleg":{"type":"string"}},
    "required":["typ","datum","absender","betrag","beleg"],"additionalProperties":false}
    """#
}
