import PippaCore
import SwiftUI

/// One quiet line while an answer is on its way: what she is actually doing, in plain words, the elapsed time
/// after two seconds. A small dot matrix (not the ring, which the window header already shows) carries the only
/// motion, one calm pattern per kind of activity; with Reduce Motion it stands still and the text changes in place. The line steps aside as soon as answer text arrives.
struct ThoughtLineView: View {
    var thought: ThoughtLine
    /// Where no Stop is in reach (compact surfaces), the line carries one.
    var onStop: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// "Show all steps" was clicked for the answer that started then (a new answer starts folded again).
    private let showsAllState = State<Date?>(initialValue: nil)

    private var reduceMotion: Bool { systemReduceMotion || MarkHub.shared.reduced }
    private var showsAll: Bool { showsAllState.wrappedValue != nil && showsAllState.wrappedValue == thought.startedAt }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let phase = thought.phase, thought.isVisible {
                HStack(spacing: 10) {
                    DotMatrixView(pattern: DotPattern(phase), reduceMotion: reduceMotion)
                    ZStack(alignment: .leading) {
                        // A new kind of activity fades in; page numbers and seconds change in place.
                        words(phase).id(phase.kind).transition(reduceMotion ? .identity : .opacity)
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: phase.kind)
                    Spacer(minLength: 0)
                    if let onStop {
                        Button(T("Stop", table: "ThoughtUI"), action: onStop)
                            .pippa(.quiet).controlSize(.small)
                            .disabled(phase == .stopping)
                    }
                }
                .accessibilityElement(children: .contain)
                .transition(reduceMotion ? .identity : .opacity)
                let recent = showsAll ? (shown: thought.doneSteps, hidden: 0) : thought.recentSteps
                if !recent.shown.isEmpty {
                    StepList(steps: recent.shown, hidden: recent.hidden, reduceMotion: reduceMotion,
                             onShowAll: { showsAllState.wrappedValue = thought.startedAt })
                        .padding(.leading, 30).padding(.top, 5)
                        .transition(reduceMotion ? .identity : .opacity)
                }
                if case .wakingUp(let progress?) = phase {
                    WakeBar(progress: progress, reduceMotion: reduceMotion)
                        .padding(.leading, 30).padding(.top, 6)
                        .frame(maxWidth: 360, alignment: .leading)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: thought.isVisible)
    }

    private func words(_ phase: WorkPhase) -> some View {
        TimelineView(.periodic(from: thought.startedAt ?? Date(), by: 1)) { context in
            let elapsed = thought.showsElapsed(at: context.date) ? WorkReceipt.duration(thought.elapsedSeconds(at: context.date)) : nil
            HStack(spacing: 6) {
                Text(phase.title).foregroundStyle(Theme.ink2)
                    .lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)
                if let detail = thought.currentStep ?? phase.detail {
                    Text(detail).foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.middle)
                }
                if let elapsed {
                    Text(elapsed).foregroundStyle(Theme.ink3).monospacedDigit().fixedSize()
                }
            }
            .font(Fonts.hint)
            // VoiceOver reads the phase when it lands here; changes are announced politely by the controller.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(["Pippa", phase.title, thought.currentStep ?? phase.detail].compactMap { $0 }.joined(separator: ", "))
            .accessibilityValue(elapsed ?? "")
        }
    }
}

/// What Pippa has just done, quietly under the line: the last few steps in everyday words, each with a small picture
/// of what it touched and the result when known. A step that appears fades in; with Reduce Motion nothing animates.
/// Older steps collapse into one count, which opens them all.
struct StepList: View {
    var steps: [WorkStep]
    var hidden = 0
    var reduceMotion: Bool
    var onShowAll: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if hidden > 0 {
                let count = hidden == 1 ? T("1 earlier step", table: "ThoughtUI") : T("%lld earlier steps", table: "ThoughtUI", hidden)
                if let onShowAll {
                    Button(action: onShowAll) {
                        HStack(spacing: 4) {
                            Text(count)
                            Image(systemName: "chevron.down").font(.scaled(size: 8.5, weight: .semibold))
                        }
                        .font(Fonts.hint).foregroundStyle(Theme.ink3).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(T("Show All Steps", table: "ThoughtUI"))
                    .accessibilityLabel(count)
                    .accessibilityHint(T("Show All Steps", table: "ThoughtUI"))
                } else {
                    Text(count).font(Fonts.hint).foregroundStyle(Theme.ink3)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    StepRow(step: step)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(T("What I did", table: "ThoughtUI"))
            .accessibilityValue(steps.map(\.line).joined(separator: ". "))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: steps)
        .frame(maxWidth: 520, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// One step: a small picture of what it touched, the everyday words, and what came of it. A step that did not work
/// is marked, so a gap is never mistaken for "nothing there".
struct StepRow: View {
    var step: WorkStep
    var body: some View {
        let failed = step.failed == true
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: failed ? "exclamationmark.circle" : Self.symbol(step.kind))
                .font(.scaled(size: 10.5, weight: .medium))
                .foregroundStyle(failed ? Theme.need : Theme.ink3)
                .frame(width: 13)
                .accessibilityHidden(true)
            Text(step.text).foregroundStyle(Theme.ink2).lineLimit(1).truncationMode(.middle).layoutPriority(1)
            if let outcome = step.outcome {
                Text("· " + outcome).foregroundStyle(failed ? Theme.need : Theme.ink3).lineLimit(1).fixedSize()
            }
        }
        .font(Fonts.hint)
    }

    private static func symbol(_ kind: WorkStep.Kind?) -> String {
        switch kind {
        case .file: "doc.text"
        case .change: "pencil"
        case .search: "magnifyingglass"
        case .online: "globe"
        case .calendar: "calendar"
        case .mail: "envelope"
        case .reminder: "checklist"
        case .memory: "bookmark"
        case .mac: "gearshape"
        case nil: "checkmark"
        }
    }
}

/// Cold start: how much of the knowledge is in memory (measured, ColdStart.swift). A thin calm bar; with Reduce Motion
/// it jumps instead of gliding. Also used by the pill.
struct WakeBar: View {
    var progress: Double
    var reduceMotion: Bool
    var height: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.accentTint)
                Capsule().fill(Theme.accent.opacity(0.75))
                    .frame(width: max(height, geo.size.width * min(1, max(0, progress))))
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: progress)
        .accessibilityElement()
        .accessibilityLabel(ColdStart.pillLabel(.wakingUp(progress: progress)) ?? "")
        .accessibilityValue(ColdStart.spokenProgress(progress))
    }
}

/// The small note under a finished answer ("3 sources read · 12 s"). Click or press to see what was actually read.
struct WorkReceiptView: View {
    var receipt: WorkReceipt
    var expanded: Bool
    var toggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if systemReduceMotion || MarkHub.shared.reduced { toggle() }
                else { withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { toggle() } }
            } label: {
                HStack(spacing: 5) {
                    Text(receipt.summary).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.scaled(size: 8.5, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .font(.scaled(size: 11, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? T("Hide Details", table: "ThoughtUI") : T("Show What I Read", table: "ThoughtUI"))
            .accessibilityLabel(receipt.summary)
            .accessibilityValue(expanded ? T("Details shown", table: "ThoughtUI") : T("Details hidden", table: "ThoughtUI"))
            .accessibilityHint(expanded ? T("Hide Details", table: "ThoughtUI") : T("Show What I Read", table: "ThoughtUI"))
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(receipt.sources.enumerated()), id: \.offset) { _, source in
                        row(icon: Self.icon(source), strong: !source.wasRead || source.status == .partial,
                            title: source.displayName, detail: source.detail)
                    }
                    if receipt.lookedUpOnline {
                        row(icon: "globe", strong: false, title: T("Looked it up online", table: "ThoughtUI"), detail: nil)
                    }
                    if receipt.checkedCalendar {
                        row(icon: "calendar", strong: false, title: T("Checked your calendar", table: "ThoughtUI"), detail: nil)
                    }
                    if let steps = receipt.steps, !steps.isEmpty {
                        if !receipt.sources.isEmpty || receipt.lookedUpOnline || receipt.checkedCalendar { Divider() }
                        Text(T("What I did", table: "ThoughtUI")).font(Fonts.hint.weight(.medium)).foregroundStyle(Theme.ink2)
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in StepRow(step: step) }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(T("What I did", table: "ThoughtUI"))
                        .accessibilityValue(steps.map(\.line).joined(separator: ". "))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: 520, alignment: .leading)
                .background(Theme.chatCard, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.chatBorder, lineWidth: 0.5) }
                .transition(.opacity)
            }
        }
    }

    private func row(icon: String, strong: Bool, title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.scaled(size: 11, weight: .medium))
                .foregroundStyle(strong ? Theme.accent : Theme.ink3)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Fonts.hint.weight(.medium)).foregroundStyle(Theme.ink2)
                    .lineLimit(1).truncationMode(.middle)
                if let detail, !detail.isEmpty {
                    Text(detail).font(.scaled(size: 11)).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Unread and partly read sources are marked, so a gap is never mistaken for "nothing there".
    private static func icon(_ source: SourceReading) -> String {
        switch source.status {
        case .read: source.isSelection ? "text.quote" : "doc.text"
        case .partial: "circle.lefthalf.filled"
        case .unreadable, .unavailable: "exclamationmark.circle"
        case .namesOnly: "list.bullet"
        }
    }
}

/// "What happened" under an answer from the real Pi (ActionReceipt). Always visible and stronger than the
/// reading receipt: if the answer text contradicts it ("The file was created"), the eye should stay on this line.
struct ActionReceiptView: View {
    var receipt: ActionReceipt
    /// Buttons are off while an answer runs.
    var disabled = false
    /// "Open draft" on a mail draft (Pippa does not delete a draft; see docs/development.md). `nil`: no button.
    var onOpenMailDraft: (() -> Void)? = nil
    /// "As draft in Mail" on the row "No draft in Mail yet", as long as the offer is available.
    var onSaveMailOffer: (() -> Void)? = nil
    /// "Copy text" when the mail was no longer in Mail at the click.
    var onCopyMailOffer: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(receipt.lines.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: Self.icon(entry.item))
                        .font(.scaled(size: 11.5, weight: .semibold))
                        // Read is neutral: neither success nor warning, only what Pippa looked at.
                        .foregroundStyle(entry.item.action == "read" ? Theme.ink3 : entry.item.happened ? Theme.ok : Theme.need)
                        .frame(width: 14)
                    Text(entry.text)
                        .font(Fonts.hint.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let onOpenMailDraft, entry.item.canOpenMailDraft {
                        Spacer(minLength: 6)
                        Button { onOpenMailDraft() } label: { Label(T("Open draft", table: "Views"), systemImage: "envelope") }
                            .pippa(.tinted).controlSize(.small)
                            .accessibilityHint(entry.text)
                    } else if let onSaveMailOffer, entry.item.action == "mailDraft", entry.item.outcome == "notYet",
                              let offer = receipt.mailOffer, offer.canSave {
                        Spacer(minLength: 6)
                        Button { onSaveMailOffer() } label: { Label(T("Save as draft in Mail", table: "Views"), systemImage: "envelope.badge") }
                            .pippa(.tinted).controlSize(.small).disabled(disabled)
                            .accessibilityHint(entry.text)
                    } else if let onCopyMailOffer, entry.item.action == "mailDraft", entry.item.outcome == "notYet",
                              receipt.mailOffer?.canCopy == true {
                        // The mail is no longer in Mail: no draft onto a different mail, only the text to copy.
                        Spacer(minLength: 6)
                        Button { onCopyMailOffer() } label: { Label(T("Copy text", table: "Views"), systemImage: "doc.on.doc") }
                            .pippa(.tinted).controlSize(.small)
                            .accessibilityHint(entry.text)
                    }
                }
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .frame(maxWidth: 520, alignment: .leading)
        .background(Theme.chatCard, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.chatBorder, lineWidth: 0.5) }
        .accessibilityElement(children: onOpenMailDraft == nil && onSaveMailOffer == nil && onCopyMailOffer == nil ? .combine : .contain)
        .accessibilityLabel(T("What happened", table: "ThoughtUI"))
        .accessibilityValue(receipt.lines.map(\.text).joined(separator: ". "))
    }

    private static func icon(_ item: ActionReceipt.Item) -> String {
        if item.action == "read" { return item.happened ? "eye" : "eye.slash" }
        return switch item.outcome {
        case "done": "checkmark.circle"
        case "declined", "blocked": "hand.raised"
        case "failed": "exclamationmark.triangle"
        default: "questionmark.circle"
        }
    }
}
