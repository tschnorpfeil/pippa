import AppKit
import PippaCore

/// What Pippa Island says at a glance, from the same sources the pill used: the running answer, the setup, open
/// questions (`Approvals`), a dragged file and a short "done" or "failed" after an answer.
struct IslandStatus: Equatable {
    enum Tone: Equatable { case rest, working, needsYou, done, failed }

    var tone: Tone
    var label: String
    /// Download progress 0...1 while the AI loads.
    var progress: Double?
    /// A file is dragged over the island.
    var targeted = false
    /// Words of the answer are coming in: the mark becomes her handwriting (`Scribble`).
    var writing = false

    static let rest = IslandStatus(tone: .rest, label: "Pippa")

    /// Only rest leaves the notch empty (and the menu bar alone).
    var showsCompact: Bool { tone != .rest || targeted }

    var markState: MarkState {
        switch tone {
        case .rest, .done: .ruht
        case .working: .arbeitet
        case .needsYou: .offen
        case .failed: .fehler
        }
    }

    /// A small sign after the words, so the state does not depend on colour alone.
    var symbol: String? {
        switch tone {
        case .needsYou: "questionmark"
        case .done: "checkmark"
        case .failed: "exclamationmark"
        case .rest, .working: nil
        }
    }

    @MainActor
    static func current(chat: ChatModel, setup: SetupModel, questions: Int, flash: ChatModel.Unseen?, targeted: Bool) -> IslandStatus {
        if targeted { return IslandStatus(tone: .working, label: T("Drop something on me!", table: "App"), targeted: true) }
        if questions > 0 { return IslandStatus(tone: .needsYou, label: T("Pippa has a question", table: "Island")) }
        if chat.isAnswering {
            let last = chat.answering?.messages.last
            if let step = last?.steps.last(where: { !$0.done }) { return IslandStatus(tone: .working, label: step.label) }
            if chat.isWriting { return IslandStatus(tone: .working, label: T("Writing…", table: "App"), writing: true) }
            return IslandStatus(tone: .working, label: chat.startingAI ? T("Starting my AI…", table: "App") : T("Thinking…", table: "App"))
        }
        if !setup.usesOnlineAI {
            switch setup.state {
            case .preparing: return IslandStatus(tone: .working, label: T("Getting ready…", table: "App"))
            case .downloading(let progress, _):
                return IslandStatus(tone: .working, label: T("Loading my AI · %lld %%", table: "App", Int(progress * 100)), progress: progress)
            case .askDownload, .failed: return IslandStatus(tone: .needsYou, label: T("Set up my AI", table: "App"))
            case .ready: break
            }
        }
        switch flash {
        case .answer: return IslandStatus(tone: .done, label: T("Your answer is ready", table: "App"))
        case .failed: return IslandStatus(tone: .failed, label: T("That didn’t work", table: "App"))
        case nil: return .rest
        }
    }

    // MARK: Compact size

    /// The wing's one font, SF Pro Rounded with tabular digits: it both measures the wing and draws its line, so the
    /// measured width is the drawn one.
    nonisolated(unsafe) static let font: NSFont = {
        let base = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let rounded = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        let tabular = rounded.addingAttributes([.featureSettings: [[NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                                                                     .selectorIdentifier: kMonospacedNumbersSelector]]])
        return NSFont(descriptor: tabular, size: 12) ?? base
    }()
    static let markSize: CGFloat = 18

    private var labelWidth: CGFloat {
        ceil((label as NSString).size(withAttributes: [.font: Self.font]).width)
    }
    /// The sign or the progress ring after the words.
    private var trailerWidth: CGFloat { symbol != nil || progress != nil ? 18 : 0 }

    /// At the notch: one wing's width. The mark sits in the left wing, the line in the right one; both are equally
    /// wide so the island stays centred on the camera.
    /// Left of the housing: mark, line, and a gap before the housing.
    var wingWidth: CGFloat { IslandStyle.wingInset + Self.markSize + IslandStyle.wingGap + labelWidth + trailerWidth + IslandStyle.wingGap }

    /// Under the menu bar: the whole capsule.
    var capsuleWidth: CGFloat { 12 + labelWidth + trailerWidth + 12 }
}

/// Island colours and measures. The island is always dark: black like the camera housing, white type in three steps.
enum IslandStyle {
    static let primary = 0.95
    static let secondary = 0.56
    static let tertiary = 0.32
    /// From the housing to the line in the right wing, and from the outer edge to the mark.
    static let wingGap: CGFloat = 8
    static let wingInset: CGFloat = 12
    /// Between the panel's edges and everything in it.
    static let padding: CGFloat = 16
    /// Between blocks: what she says, the question, the field row.
    static let gap: CGFloat = 12
    /// Between buttons, and between the lines of a question.
    static let buttonGap: CGFloat = 8
    /// Inner wells (the question field, the drop tray); the panel's own corners are `IslandGeometry.cornerRadius`.
    static let wellRadius: CGFloat = 12
    /// Capsule buttons and the field beside them.
    static let controlHeight: CGFloat = 28
    /// At the notch, between the menu bar row (mark and name) and the panel's content.
    static let notchTop: CGFloat = 6
    /// How far a new step rises into place.
    static let rise: CGFloat = 4
}
