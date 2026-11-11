import AppKit
import PippaCore
import SwiftUI

/// First run, one card: load the AI for this Mac, or use an online AI in Settings. One primary button; while the AI
/// downloads, it says what already works.
struct SetupCard: View {
    @ObservedObject var setup: SetupModel
    var showsOnlineOption = true
    private let detailsState: State<Bool>
    private let copiedState = State(initialValue: false)

    /// Settings > General > Storage, where the person sees what takes up room and can free some.
    static let storageSettingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!

    init(setup: SetupModel, showsOnlineOption: Bool = true) {
        self.setup = setup
        self.showsOnlineOption = showsOnlineOption
        detailsState = State(initialValue: setup.detailsOpenForSnapshot)
    }

    private func isOutOfSpace(_ problem: PiSetupProblem) -> Bool {
        if case .notEnoughSpace? = problem.failure { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(spacing: Space.ml) {
                Image(systemName: symbol).font(Typo.body.weight(.semibold)).foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 30, height: 30)
                    .background(tintFill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                Text(T("Pippa’s AI", table: "App")).font(Typo.headline).foregroundStyle(Theme.ink)
                Spacer()
                if case .downloading(let progress, _) = setup.state {
                    let locale = Locale(identifier: Bundle.module.preferredLocalizations.first ?? "en")
                    Text(progress, format: .percent.precision(.fractionLength(0)).locale(locale))
                        .font(Typo.figure).foregroundStyle(Theme.ink2)
                        .contentTransition(.numericText())
                        .animation(Theme.quick, value: progress)
                }
            }
            switch setup.state {
            case .preparing(let source):
                HStack(spacing: Space.m) {
                    ProgressView().controlSize(.small)
                    Text(source.map { T("Taking over the AI from %@…", table: "App", $0) } ?? T("Getting ready…", table: "App"))
                }
            case .askDownload(let bytes):
                Text(T("Pippa’s AI runs on this Mac. It needs a one-time download of %@.", table: "App",
                       ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))
                Text(T("Picked to fit your Mac: %@", table: "App", setup.hardware)).font(Typo.footnote).foregroundStyle(Theme.ink3)
                HStack(spacing: Space.m) {
                    ActionPill(title: T("Load Pippa’s AI", table: "App"), primary: true) { setup.load() }
                    if showsOnlineOption {
                        ActionPill(title: T("Use an Online AI…", table: "App")) { SettingsWindow.shared.show(.ai) }
                    }
                }
            case .downloading(let progress, let remaining):
                ProgressBar(value: progress)
                HStack {
                    Text(remaining.map { $0 < 60 ? T("Less than a minute left", table: "App") : T("About %@ left", table: "App", Self.duration($0)) } ?? T("Loading…", table: "App"))
                        .font(Typo.footnote).foregroundStyle(Theme.ink3).monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(Theme.quick, value: remaining)
                    Spacer()
                    ActionPill(title: T("Stop", table: "App")) { setup.stopDownload() }
                }
                Label(T("Meanwhile, drop photos or PDFs here to make one PDF.", table: "Views"), systemImage: "doc.richtext")
                    .font(Typo.footnote).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Space.xs)
            case .failed(let problem):
                Text(problem.message).fixedSize(horizontal: false, vertical: true)
                // Never a dead end: even when this Mac can't run the AI itself (too little memory), an online AI can.
                HStack(spacing: Space.m) {
                    // Out of room: Storage settings is the way forward, then Try Again checks once more.
                    let space = isOutOfSpace(problem)
                    if space { ActionPill(title: T("Open Storage Settings…", table: "App"), primary: true) { NSWorkspace.shared.open(Self.storageSettingsURL) } }
                    if problem.canRetry { ActionPill(title: T("Try Again", table: "App"), primary: !space) { setup.begin() } }
                    if showsOnlineOption {
                        ActionPill(title: T("Use an Online AI…", table: "App"), primary: !problem.canRetry) { SettingsWindow.shared.show(.ai) }
                    }
                }
                if !problem.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    DisclosureGroup(isExpanded: detailsState.projectedValue) {
                        VStack(alignment: .leading, spacing: Space.s) {
                            Text(problem.details)
                                .font(Typo.caption.monospaced()).foregroundStyle(Theme.ink2)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            copyButton(problem.details)
                        }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Space.m)
                            .background(Theme.chatInset, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                            .padding(.top, Space.xs)
                    } label: {
                        Text(T("Details", table: "App")).font(Typo.caption).foregroundStyle(Theme.ink3)
                    }
                }
            case .ready:
                Label(T("Ready", table: "App"), systemImage: "checkmark.circle").foregroundStyle(Theme.ok)
            }
        }
        .font(Typo.callout)
        .padding(Space.xl + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raised(Radius.panel)
        .animation(Theme.arrive, value: stage)
    }

    /// Copies the details for a request for help; shows "Copied" with a check mark for a moment (a fade, with Reduce Motion).
    private func copyButton(_ text: String) -> some View {
        let copied = copiedState.wrappedValue
        return Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let fade = Theme.reduceMotion ? Animation.easeInOut(duration: 0.2) : Theme.quick
            withAnimation(fade) { copiedState.wrappedValue = true }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(fade) { copiedState.wrappedValue = false }
            }
        } label: {
            Label(copied ? T("Copied", table: "App") : T("Copy", table: "App"), systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(Typo.footnote).foregroundStyle(Theme.ink3)
                .contentTransition(Theme.reduceMotion ? .opacity : .symbolEffect(.replace))
                .frame(minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(T("Copy Details", table: "App"))
    }

    /// Which of the card's states shows, for animating between them (not the progress inside one).
    private var stage: Int {
        switch setup.state {
        case .preparing: 0
        case .askDownload: 1
        case .downloading: 2
        case .failed: 3
        case .ready: 4
        }
    }

    /// Neutral like every card's symbol; only a problem takes the warning colour.
    private var tint: Color { if case .failed = setup.state { Theme.need } else { Theme.ink2 } }
    private var tintFill: Color { if case .failed = setup.state { Theme.needTint } else { Theme.fill } }

    private var symbol: String {
        switch setup.state {
        case .failed: return "exclamationmark.triangle"
        case .ready: return "checkmark"
        default: return "arrow.down.circle"
        }
    }

    /// "45 sec", "6 min", "1 hr, 20 min". (Under a minute it says the seconds, never "1 min".)
    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: Bundle.module.preferredLocalizations.first ?? "en")
        formatter.calendar = calendar
        formatter.unitsStyle = .short
        formatter.allowedUnits = seconds < 60 ? [.second] : seconds >= 3600 ? [.hour, .minute] : [.minute]
        return formatter.string(from: seconds) ?? ""
    }
}

/// A thin determinate bar in the accent colour: drawn by hand so it looks the same in every window state (the system
/// bar turns grey and nearly invisible in a window that is not key).
private struct ProgressBar: View {
    var value: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fill2)
                Capsule().fill(Theme.accent)
                    .frame(width: max(6, geometry.size.width * min(1, max(0, value))))
                    .animation(Theme.arrive, value: value)
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityValue(Text(value, format: .percent.precision(.fractionLength(0))))
    }
}
