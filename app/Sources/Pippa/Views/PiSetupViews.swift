import PippaCore
import SwiftUI

// Welcome with setup (PiSetupController). No technical questions, no paths, no "Pi" and no
// "Terminal" in the UI. With Reduce Motion everything stands still: dots without motion, examples change only
// on click and without cross-fade.

struct PiSetupContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var setup: PiSetupController

    var body: some View {
        VStack(spacing: 0) {
            switch setup.state {
            case .askDownload(let bytes):
                question(bytes)
            case .preparing(let source):
                waiting(title: T("Pippa is getting ready", table: "Settings"),
                        line: source.map { T("I’m taking over my AI from %@, without extra space …", table: "Settings", $0) }
                            ?? T("I’m setting myself up …", table: "Settings"),
                        pattern: source == nil ? .sequence : .sweep, progress: nil, remaining: nil)
            case .downloading(let progress, let remaining):
                // Stuck (no new data for 30 s or offline): say so instead of a bar that silently stands still.
                waiting(title: T("Pippa is loading her AI", table: "Settings"),
                        line: setup.stalled ? AppModel.offlineText : T("I’m loading my AI …", table: "Settings"),
                        pattern: .fill, progress: progress, remaining: setup.stalled ? nil : remaining)
            case .failed(let problem):
                failed(problem)
            case .ready(let source):
                ready(adoptedFrom: source)
            }
        }
        .workflowWidth(Theme.wideWidth)
        .overlay(alignment: .topTrailing) {
            CloseButton { setup.later() }.padding(12)
        }
    }

    // MARK: The only question

    private func question(_ bytes: Int64) -> some View {
        VStack(spacing: 0) {
            head(T("Hi, I’m Pippa", table: "Settings"))
            Text(PiInstaller.downloadQuestion(bytes: bytes))
                .font(Fonts.lead)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .padding(.horizontal, 32)
                .stagger(1)
            HStack(spacing: 8) {
                Button(T("Later", table: "Settings")) { setup.later() }.pippa(.quiet)
                Button(T("Load", table: "Settings")) { setup.load() }
                    .pippa(.primary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 20)
            .padding(.bottom, 26)
            .stagger(2)
        }
    }

    // MARK: Setting up and loading

    private func waiting(title: String, line: String, pattern: DotPattern, progress: Double?, remaining: TimeInterval?) -> some View {
        VStack(spacing: 0) {
            head(title)
            VStack(spacing: 10) {
                SetupThoughtLine(text: line, pattern: pattern, progress: progress, remaining: remaining)
                if let progress { ThinProgress(value: progress, height: 6) }
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)
            SetupExamplesCard(setup: setup)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .stagger(3)
            ActionBar {
                Button(T("Keep Loading in the Background", table: "Settings")) { setup.later() }.pippa(.quiet)
                if setup.stalled {
                    Button(T("Try Again", table: "Settings")) { setup.retryDownload() }.pippa(.primary)
                }
            }
        }
    }

    // MARK: Fehler

    private func failed(_ problem: PiSetupProblem) -> some View {
        VStack(spacing: 0) {
            MarkSlot(size: 48).padding(.top, 30)
            Text(problem.message)
                .font(Fonts.lead)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
                .padding(.horizontal, 32)
            HStack(spacing: 8) {
                Button(setup.showsDetails ? T("Hide Details", table: "Settings") : T("Details", table: "Settings")) {
                    setup.showsDetails.toggle()
                }
                .pippa(.quiet)
                .accessibilityValue(setup.showsDetails ? T("Details shown", table: "Settings") : T("Details hidden", table: "Settings"))
                if problem.canRetry {
                    Button(T("Try again", table: "Settings")) { setup.retry() }
                        .pippa(.primary)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 18)
            if setup.showsDetails {
                Text(problem.details)
                    .font(.scaled(size: 11.5, design: .monospaced))
                    .foregroundStyle(Theme.ink2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill))
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
            }
            Spacer(minLength: 0).frame(height: 24)
        }
    }

    // MARK: Fertig

    private func ready(adoptedFrom source: String?) -> some View {
        VStack(spacing: 0) {
            head(T("I’m ready", table: "Settings"))
            if let source {
                Text(T("I’m using the AI that was already in %@, without extra space.", table: "Settings", source))
                    .font(Fonts.hint)
                    .foregroundStyle(Theme.ink3)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .padding(.horizontal, 32)
            }
            Well(padding: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "folder")
                        .font(.scaled(size: 17, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(T("Try it: your Downloads folder", table: "Settings"))
                            .font(.scaled(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text(T("I’ll suggest some order first. Nothing moves until you say so, and Undo puts everything back.", table: "Settings"))
                            .font(Fonts.body).foregroundStyle(Theme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .stagger(2)
            ActionBar {
                Button(T("Later", table: "Settings")) { setup.later() }.pippa(.quiet)
                Button(T("Try It", table: "Settings")) { setup.tryIt() }
                    .pippa(.primary)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func head(_ title: String) -> some View {
        VStack(spacing: 0) {
            MarkSlot(size: 48).padding(.bottom, 14)
            Text(title)
                .font(Fonts.resultL)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .stagger(0)
        }
        .padding(.top, 30)
    }
}

/// The setup's thought line: same dots as ThoughtLineView, one sentence, percent and time left on the right.
struct SetupThoughtLine: View {
    var text: String
    var pattern: DotPattern
    var progress: Double?
    var remaining: TimeInterval?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || MarkHub.shared.reduced }

    var body: some View {
        HStack(spacing: 10) {
            DotMatrixView(pattern: pattern, reduceMotion: reduceMotion)
            Text(text).foregroundStyle(Theme.ink2).lineLimit(2).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
            Spacer(minLength: 8)
            if let remaining, remaining > 0, (progress ?? 0) < 1 {
                Text(AppModel.remainingText(remaining)).foregroundStyle(Theme.ink3).lineLimit(1)
            }
            if let progress {
                Text(T("%lld%%", table: "Settings", Int((progress * 100).rounded(.down))))
                    .font(Fonts.hint.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .contentTransition(reduceMotion ? .identity : .numericText())
            }
        }
        .font(Fonts.hint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(["Pippa", text].joined(separator: ", "))
        .accessibilityValue(progress.map { T("%lld%%", table: "Settings", Int(($0 * 100).rounded(.down))) } ?? "")
    }
}

/// Examples to page through while Pippa loads. All lie on top of each other so the height stays the same
/// on change; without Reduce Motion it pages on by itself after a while.
struct SetupExamplesCard: View {
    @ObservedObject var setup: PiSetupController
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || MarkHub.shared.reduced }
    static let interval: Double = 9

    var body: some View {
        let examples = SetupExample.all
        let index = min(setup.exampleIndex, examples.count - 1)
        Well(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(T("What I can do for you", table: "Settings"))
                        .font(Fonts.sill).foregroundStyle(Theme.ink3)
                    Spacer(minLength: 6)
                    pagerButton("chevron.left", T("Previous Example", table: "Settings")) { setup.showExample(index - 1) }
                    Text(T("%1$lld of %2$lld", table: "Settings", index + 1, examples.count))
                        .font(Fonts.sill.monospacedDigit()).foregroundStyle(Theme.ink3)
                    pagerButton("chevron.right", T("Next Example", table: "Settings")) { setup.showExample(index + 1) }
                }
                ZStack(alignment: .topLeading) {
                    ForEach(Array(examples.enumerated()), id: \.offset) { offset, example in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: example.icon)
                                .font(.scaled(size: 17, weight: .medium))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(example.title).font(.scaled(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                                Text(example.body).font(Fonts.body).foregroundStyle(Theme.ink2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .opacity(offset == index ? 1 : 0)
                        .accessibilityHidden(offset != index)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: index)
            }
        }
        .task(id: index) {
            guard !reduceMotion else { return }
            try? await Task.sleep(for: .seconds(Self.interval))
            if !Task.isCancelled { setup.showExample(index + 1) }
        }
    }

    private func pagerButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.scaled(size: 10, weight: .semibold))
                .foregroundStyle(Theme.ink2)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.fill2))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}
