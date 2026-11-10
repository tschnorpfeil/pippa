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
            if chat.isWriting { return IslandStatus(tone: .working, label: T("Writing…", table: "App")) }
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

    nonisolated(unsafe) static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    static let markSize: CGFloat = 18

    private var labelWidth: CGFloat {
        ceil((label as NSString).size(withAttributes: [.font: Self.font]).width)
    }
    /// The sign or the progress ring after the words.
    private var trailerWidth: CGFloat { symbol != nil || progress != nil ? 18 : 0 }

    /// At the notch: one wing's width. The mark sits in the left wing, the line in the right one; both are equally
    /// wide so the island stays centred on the camera.
    var wingWidth: CGFloat { IslandStyle.wingGap + labelWidth + trailerWidth + IslandStyle.wingInset }

    /// Under the menu bar: the whole capsule.
    var capsuleWidth: CGFloat { 6 + Self.markSize + 7 + labelWidth + trailerWidth + 12 }
}

/// Island colours and measures. The island is always dark: black like the camera housing, white type in three steps.
enum IslandStyle {
    static let primary = 0.95
    static let secondary = 0.56
    static let tertiary = 0.32
    /// From the housing to the line in the right wing, and from the outer edge to the mark.
    static let wingGap: CGFloat = 8
    static let wingInset: CGFloat = 12
    static let padding: CGFloat = 16
}
