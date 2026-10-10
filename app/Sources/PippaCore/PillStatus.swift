import Foundation

// The living pill: what the collapsed pill says while Pippa works and after she is done (UI-FIXPLAN phase 3).
//
// Same rule as the Thought Line: every word comes from a real event (`WorkPhase`, a finished or failed answer),
// nothing is timed or guessed. The pill speaks in the short form of the line: "Lese Mietvertrag · 2/4",
// never file endings, program names or paths. A finished answer stays visible until the person looks at it.

/// How a finished answer ended while only the pill was showing. Cleared when the conversation is opened.
public enum PillOutcome: Sendable, Equatable {
    case answered
    case failed
}

/// Pippa's small moments (UX rule 6): only these three, never while she works.
public enum PillMoment: Sendable, Equatable {
    /// A file task is finished (a short moment).
    case finished
    /// Undo put everything back (a short moment).
    case undone
    /// Right after setup, until the first thing is dropped or asked: the invitation.
    case invite
}

/// The pill's mood; the app maps it to colour and the figure's state.
public enum PillTone: String, Sendable, Equatable {
    /// Nothing going on: just "Pippa".
    case rest
    case working
    /// A card waits for the person (permission, a choice).
    case needsYou
    /// An answer is ready and not seen yet.
    case done
    case failed
}

public struct PillStatus: Sendable, Equatable {
    public var tone: PillTone
    public var label: String
    /// Measured progress 0…1 for the thin bar; `nil` means no bar (never an invented percentage).
    public var progress: Double?
    public init(tone: PillTone, label: String, progress: Double? = nil) {
        self.tone = tone
        self.label = label
        self.progress = progress
    }

    /// Longest file name the pill shows before shortening with "…" (the pill stays below ~260 pt).
    public static let nameLimit = 22
    /// Longest step sentence in the thought bubble above the pill before shortening (PillAura).
    public static let stepLimit = 34

    /// What the pill says. A running answer wins over an old outcome; `busy` covers file tasks without a phase.
    /// - Parameters:
    ///   - phase: the running answer's phase (`ThoughtLine.phase`), `nil` when no answer is running.
    ///   - step: the running Pi step in everyday words (`ThoughtLine.currentStep`).
    ///   - outcome: a finished answer the person has not seen yet.
    ///   - busy: a file task (tidying, reading) runs without a conversation phase.
    ///   - loading: measured progress 0…1 while Pippa's AI downloads (setup), `nil` when nothing loads.
    ///   - moment: one of Pippa's small moments; a short one wins over an old outcome, the invitation only shows when nothing else does.
    public static func make(phase: WorkPhase?, step: String? = nil, outcome: PillOutcome? = nil, busy: Bool = false,
                            loading: Double? = nil, moment: PillMoment? = nil, language: String? = nil) -> PillStatus {
        if let phase {
            if phase == .waitingForPerson {
                return PillStatus(tone: .needsYou, label: L("Quick question", table: "Thought", language: language))
            }
            if let cold = ColdStart.pillLabel(phase, language: language) {
                return PillStatus(tone: .working, label: cold, progress: ColdStart.pillProgress(phase))
            }
            return PillStatus(tone: .working, label: label(for: phase, step: step, language: language), progress: progress(for: phase))
        }
        if busy { return PillStatus(tone: .working, label: L("Working on it…", table: "Thought", language: language)) }
        if let loading {
            // The percent in the label: the bar alone is thin, the number reads from across the screen.
            let fraction = min(max(loading, 0), 1)
            return PillStatus(tone: .working, label: L("Loading my AI · %lld%%", table: "Thought", language: language, Int((fraction * 100).rounded())),
                              progress: fraction)
        }
        switch moment {
        case .finished: return PillStatus(tone: .done, label: L("Done!", table: "Thought", language: language))
        case .undone: return PillStatus(tone: .done, label: L("Back as it was.", table: "Thought", language: language))
        case .invite, nil: break
        }
        switch outcome {
        case .answered: return PillStatus(tone: .done, label: L("Your answer is ready", table: "Thought", language: language))
        case .failed: return PillStatus(tone: .failed, label: L("That didn’t work", table: "Thought", language: language))
        case nil:
            if moment == .invite {
                return PillStatus(tone: .rest, label: L("Drop something on me!", table: "Thought", language: language))
            }
            return PillStatus(tone: .rest, label: "Pippa")
        }
    }

    /// Short form of the Thought Line for the pill.
    static func label(for phase: WorkPhase, step: String?, language: String?) -> String {
        // Waiting and steps say nothing on the pill itself: the glow shows that she works, the thought bubble above
        // the pill shows the step (PillAura). Only real host work without a bubble keeps its words.
        let hasStep = !(step ?? "").isEmpty
        switch phase {
        case .starting, .waitingForAnswer, .working: return "Pippa"
        case .lookingThrough, .lookingUpOnline, .checkingCalendar, .preparingPreview: if hasStep { return "Pippa" }
        default: break
        }
        switch phase {
        case .reading(let name, let index, let count):
            let base = L("Reading %@", table: "Thought", language: language, shortName(name))
            return count > 1 ? base + " · \(index)/\(count)" : base
        case .recognizing(_, let page, let pages):
            return pages > 1
                ? L("Reading the scan · page %lld/%lld", table: "Thought", language: language, page, pages)
                : L("Reading the scan…", table: "Thought", language: language)
        case .lookingThrough(let name):
            return name.map { L("Looking in %@", table: "Thought", language: language, shortName($0)) }
                ?? L("Looking through your documents…", table: "Thought", language: language)
        case .choosingPassages: return L("Finding the right passages…", table: "Thought", language: language)
        case .lookingUpOnline: return L("Looking it up online…", table: "Thought", language: language)
        case .checkingCalendar: return L("Checking your calendar…", table: "Thought", language: language)
        case .preparingPreview: return L("Preparing a preview…", table: "Thought", language: language)
        case .retrying: return L("Trying again…", table: "Thought", language: language)
        case .condensing: return L("Summarizing…", table: "Thought", language: language)
        case .checkingSources: return L("Double-checking…", table: "Thought", language: language)
        case .writing: return L("Writing…", table: "Thought", language: language)
        case .stopping: return L("Stopping…", table: "Thought", language: language)
        case .waitingForPerson: return L("Quick question", table: "Thought", language: language)
        case .gettingReady, .wakingUp, .warmingUp:
            return L("Thinking…", table: "Thought", language: language)
        case .starting, .waitingForAnswer, .working: return "Pippa"
        }
    }

    /// Only countable work shows a bar: pages of a scan, files out of several.
    static func progress(for phase: WorkPhase) -> Double? {
        switch phase {
        case .reading(_, let index, let count) where count > 1: Double(index - 1) / Double(count)
        case .recognizing(_, let page, let pages) where pages > 1: Double(page - 1) / Double(pages)
        default: nil
        }
    }

    /// "Mietvertrag_2019_final.pdf" → "Mietvertrag_2019_final", long names shortened with "…" (no endings in view).
    public static func shortName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        let base = ext.isEmpty || ext.count > 5 || ext.contains(" ") ? name : (name as NSString).deletingPathExtension
        return shorten(base.isEmpty ? name : base, limit: nameLimit)
    }

    static func shorten(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
