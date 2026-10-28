import PippaCore
import SwiftUI

// Welcome with setup (PiSetupController). No technical questions, no paths, no "Pi" and no
// "Terminal" in the UI. With Reduce Motion everything stands still: the rings without motion, examples change only
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
                        progress: nil, remaining: nil)
            case .downloading(let progress, _) where DownloadProgress.isFinishing(progress):
                // Every byte is in: checking and setting up take a while, without a bar that already reads 100 %.
                waiting(title: T("Pippa is getting ready", table: "Settings"),
                        line: T("I’m checking my AI and setting it up …", table: "Settings"),
                        progress: nil, remaining: nil)
            case .downloading(let progress, let remaining):
                // Stuck (no new data for 30 s or offline): say so instead of a bar that silently stands still.
                waiting(title: T("Pippa is loading her AI", table: "Settings"),
                        line: setup.stalled ? AppModel.offlineText : T("I’m loading my AI …", table: "Settings"),
                        progress: progress, remaining: setup.stalled ? nil : remaining)
            case .failed(let problem):
                failed(problem)
            case .ready(let source):
                ready(adoptedFrom: source)
            }
        }
        .workflowWidth(Theme.wideWidth)
        .overlay(alignment: .topTrailing) {
            // The download question is its own step: one clear button, no corner exit (only the quiet "Later" below).
            if !setup.asksDownload { CloseButton { setup.later() }.padding(12) }
        }
    }

    // MARK: The only question

    private func question(_ bytes: Int64) -> some View {
        VStack(spacing: 0) {
            head(T("Hi, I’m Pippa", table: "Settings"))
            Text(PiInstaller.downloadQuestion(bytes: bytes))
                .font(Fonts.body)
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
                .padding(.horizontal, 32)
                .stagger(1)
            // What the choice is based on: this Mac's chip and memory, in plain words.
            Text(T("Picked for your Mac · %@", table: "Settings", setup.hardware))
                .font(Fonts.hint)
                .foregroundStyle(Theme.ink3)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.horizontal, 32)
                .stagger(1)
            // A phone hotspot or Low Data Mode: say so before 5+ GB go over it.
            if NetworkWatch.shared.expensive {
                Text(T("You’re on a phone hotspot right now. Better load on Wi-Fi.", table: "Settings"))
                    .font(Fonts.hint)
                    .foregroundStyle(Theme.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .padding(.horizontal, 32)
            }
            VStack(spacing: 10) {
                if let shortfall = setup.spaceShortfall {
                    // Checked before the click: a download that cannot fit never starts.
                    Button(T("Free Up %@ First", table: "Settings", ModelDownloadSize.gigabytes(max(shortfall, 100_000_000)))) {}
                        .pippa(.primary, large: true)
                        .disabled(true)
                    Text(T("Empty the Trash or delete large files you no longer need, then try again.", table: "Settings"))
                        .font(Fonts.hint)
                        .foregroundStyle(Theme.ink2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 32)
                    Button(T("Try Again", table: "Settings")) { setup.checkSpace() }
                        .pippa(.quiet)
                } else {
                    // The one primary action. No Return shortcut: several GB are a deliberate click.
                    Button(T("Set Up Pippa’s AI · %@", table: "Settings", ModelDownloadSize.gigabytes(bytes))) { setup.load() }
                        .pippa(.primary, large: true)
                }
                // Quiet way out (hotspot, no time): tidying, PDFs and text recognition work without the AI.
                Button(T("Later", table: "Settings")) { setup.later() }
                    .buttonStyle(.plain)
                    .font(Fonts.hint)
                    .foregroundStyle(Theme.ink3)
                    .accessibilityLabel(T("Later", table: "Settings"))
                    .accessibilityHint(T("Tidying up and overviews already work without it. You can load it any time.", table: "Settings"))
            }
            .padding(.top, 18)
            .stagger(2)
            nativeStart
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 22)
                .stagger(3)
        }
    }

    private var nativeStart: some View {
        Well(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text(T("Make something useful right away", table: "NativeFlow"))
                    .font(Fonts.head).foregroundStyle(Theme.ink)
                Text(T("Turn photos into a PDF, convert images or extract text. No AI download needed. Your originals stay as they are.", table: "NativeFlow"))
                    .font(Fonts.body).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Button(T("Choose Photos or PDFs…", table: "NativeFlow")) { setup.chooseNativeFiles() }
                    .pippa(.secondary)
                    .accessibilityHint(T("Choose files, then choose what to make. Nothing changes until you pick an action.", table: "NativeFlow"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Setting up and loading

    private func waiting(title: String, line: String, progress: Double?, remaining: TimeInterval?) -> some View {
        VStack(spacing: 0) {
            head(title)
            VStack(spacing: 10) {
                SetupThoughtLine(text: line, progress: progress, remaining: remaining)
                if let progress { ThinProgress(value: progress, height: 6) }
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)
            SetupExamplesCard(setup: setup)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .stagger(3)
            Button(T("Choose Photos or PDFs…", table: "NativeFlow")) { setup.chooseNativeFiles() }
                .pippa(.secondary)
                .padding(.top, 14)
                .accessibilityHint(T("File actions work while the download continues.", table: "NativeFlow"))
            ActionBar {
                if progress != nil, !setup.stalled {
                    Button(T("Stop Loading", table: "Settings")) { setup.stopDownload() }.pippa(.quiet)
                }
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
            nativeStart
                .padding(.horizontal, 24)
                .padding(.top, 18)
            Spacer(minLength: 0).frame(height: 24)
        }
    }

    // MARK: Fertig

    /// One step: how to call Pippa, open at login, then straight into the conversation with its examples.
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
            if hotkey != nil || setup.canOpenAtLogin {
                Well(padding: 14) {
                    VStack(alignment: .leading, spacing: 14) {
                        if let hotkey {
                            readyRow(icon: "keyboard", title: T("Call me from anywhere", table: "Settings"),
                                     detail: T("Press %@ in any app to call me.", table: "Settings", hotkey))
                        }
                        if setup.canOpenAtLogin {
                            HStack(alignment: .top, spacing: 12) {
                                readyRow(icon: "power", title: T("Open at login", table: "Settings"),
                                         detail: setup.loginProblem ?? T("Pippa is there as soon as your Mac is on.", table: "Settings"))
                                Toggle("", isOn: Binding(get: { setup.opensAtLogin }, set: { setup.setOpensAtLogin($0) }))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .accessibilityLabel(T("Open at login", table: "Settings"))
                                    .onAppear { setup.refreshLogin() }
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .stagger(2)
            }
            ActionBar {
                Button(T("Later", table: "Settings")) { setup.later() }.pippa(.quiet)
                // Straight into the empty conversation: its examples (ConversationWorkspace.examples) are the first steps.
                Button(T("Get Started", table: "Settings")) { model.startFromOnboarding() }
                    .pippa(.primary)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func readyRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.scaled(size: 17, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.scaled(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(detail).font(Fonts.body).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// The shortcut as Settings names it ("⌃⌥ Space"); `nil` when it is off or macOS or another app has it.
    private var hotkey: String? {
        let key = Hotkey.current
        return key == .off || HotkeyCenter.shared.mainTaken ? nil : key.display
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

/// The setup's thought line: Pippa's rings turning as in ThoughtLineView, one sentence, percent and time left on the right.
struct SetupThoughtLine: View {
    var text: String
    var progress: Double?
    var remaining: TimeInterval?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || MarkHub.shared.reduced }

    var body: some View {
        HStack(spacing: 10) {
            WorkShapeView(shape: .think, reduceMotion: reduceMotion)
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
