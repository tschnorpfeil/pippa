import Foundation
import PippaCore

/// The living pill (PippaCore/PillStatus.swift): short words from real phases, no endings, a bar only for countable
/// work, a question wins over everything, a finished answer stays until seen, and a running answer wins over it.
func runPillStatusChecks() {
    check("Living pill: short form of the real phase, file names without endings, counted work gets a bar") {
        let reading = PillStatus.make(phase: .reading(name: "Mietvertrag.pdf", index: 2, count: 4), language: "de")
        let scan = PillStatus.make(phase: .recognizing(name: "Scan 3.pdf", page: 2, pages: 5), language: "de")
        let single = PillStatus.make(phase: .reading(name: "Brief.docx", index: 1, count: 1), language: "en")
        return reading == PillStatus(tone: .working, label: "Lese Mietvertrag · 2/4", progress: 0.25)
            && scan == PillStatus(tone: .working, label: "Lese den Scan · Seite 2/5", progress: 0.2)
            && single == PillStatus(tone: .working, label: "Reading Brief", progress: nil)
            && PillStatus.make(phase: .writing, language: "de").label == "Schreibe …"
            && PillStatus.make(phase: .starting, language: "en").label == "Thinking…"
    }

    check("Living pill: Pi's own step is shown shortened, a question needs the person, cold start keeps its bar") {
        let step = PillStatus.make(phase: .working, step: "Suche in deinen Dokumenten nach „Kaution 2019 Nebenkosten“", language: "de")
        let ask = PillStatus.make(phase: .waitingForPerson, outcome: .failed, language: "de")
        let cold = PillStatus.make(phase: .wakingUp(progress: 0.4), language: "de")
        return step.tone == .working && step.label.count <= PillStatus.stepLimit && step.label.hasSuffix("…")
            && ask == PillStatus(tone: .needsYou, label: "Kurz eine Frage")
            && cold == PillStatus(tone: .working, label: "Pippa wird wach …", progress: 0.4)
    }

    check("Living pill: a finished answer stays until seen, a running one wins, rest is just the name") {
        PillStatus.make(phase: nil, outcome: .answered, language: "de") == PillStatus(tone: .done, label: "Deine Antwort ist da", hand: true)
            && PillStatus.make(phase: nil, outcome: .failed, language: "en") == PillStatus(tone: .failed, label: "That didn’t work")
            && PillStatus.make(phase: .writing, outcome: .answered).tone == .working
            && PillStatus.make(phase: nil, outcome: .answered, busy: true).tone == .working
            && PillStatus.make(phase: nil) == PillStatus(tone: .rest, label: "Pippa")
    }

    check("Living pill: handwritten moments are short, never while working, the invitation only when nothing else shows") {
        PillStatus.make(phase: nil, moment: .finished, language: "de") == PillStatus(tone: .done, label: "Fertig!", hand: true)
            && PillStatus.make(phase: nil, outcome: .failed, moment: .undone, language: "de") == PillStatus(tone: .done, label: "Wieder wie vorher.", hand: true)
            && PillStatus.make(phase: nil, moment: .invite, language: "de") == PillStatus(tone: .rest, label: "Leg was auf mich!", hand: true)
            && PillStatus.make(phase: nil, outcome: .answered, moment: .invite, language: "de").label == "Deine Antwort ist da"
            && PillStatus.make(phase: .writing, moment: .finished).tone == .working
            && PillStatus.make(phase: nil, busy: true, moment: .invite).tone == .working
            && !PillStatus.make(phase: .writing).hand && !PillStatus.make(phase: nil, outcome: .failed).hand
    }

    check("Living pill: names lose endings and get shortened, never a path or extension in view") {
        PillStatus.shortName("Mietvertrag.pdf") == "Mietvertrag"
            && PillStatus.shortName("Nebenkostenabrechnung_2024_final_v3.pdf").count == PillStatus.nameLimit
            && PillStatus.shortName("Nebenkostenabrechnung_2024_final_v3.pdf").hasSuffix("…")
            && PillStatus.shortName("Notizen") == "Notizen"
            && PillStatus.shortName(".pdf") == ".pdf"
    }

    check("Living pill: every label in both languages fits the pill and avoids technical words") {
        let banned = ["spotlight", "pi", "model", "modell", "token", "server", "pdf", "docx"]
        let phases: [WorkPhase] = [.starting, .reading(name: "Rechnung.pdf", index: 1, count: 3), .recognizing(name: "Scan.pdf", page: 1, pages: 9),
                                   .choosingPassages, .waitingForAnswer(continuing: true), .lookingThrough(name: "Kontoauszug.pdf"),
                                   .lookingThrough(name: nil), .lookingUpOnline, .checkingCalendar, .preparingPreview, .working, .retrying,
                                   .condensing, .checkingSources, .waitingForPerson, .writing, .stopping]
        var labels: [String] = []
        for language in ["de", "en"] {
            labels += phases.map { PillStatus.make(phase: $0, language: language).label }
            labels += [PillStatus.make(phase: nil, outcome: .answered, language: language).label,
                       PillStatus.make(phase: nil, outcome: .failed, language: language).label]
            labels += [PillMoment.finished, .undone, .invite].map { PillStatus.make(phase: nil, moment: $0, language: language).label }
        }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 40
                && !banned.contains { word in label.lowercased().split(whereSeparator: { !$0.isLetter }).contains { $0 == word } }
        }
    }
}
