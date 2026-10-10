import PippaCore
import SwiftUI

/// While an answer is on its way: no generic status text and no seconds. Pippa's dot matrix breathes; each real step
/// appears as a small chip (a picture of what it touches, everyday words) and turns into what came of it. Identical
/// steps in a row count up instead of repeating. Words appear only for something real the host does (reading a file,
/// waking up, a question) and, after ten seconds, one calm sentence that it takes a little longer.
/// With Reduce Motion chips appear without moving and the matrix stands still. Steps aside as soon as answer text arrives.
struct ThoughtLineView: View {
    var thought: ThoughtLine
    /// Where no Stop is in reach (compact surfaces), the line carries one.
    var onStop: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    /// "Show all steps" was clicked for the answer that started then (a new answer starts folded again).
    private let showsAllState = State<Date?>(initialValue: nil)

    private var reduceMotion: Bool { systemReduceMotion || MarkHub.shared.reduced }
    private var showsAll: Bool { showsAllState.wrappedValue != nil && showsAllState.wrappedValue == thought.startedAt }
    /// How many chips stay in view; older ones fold into one count.
    static let visibleChips = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let phase = thought.phase, thought.isVisible {
                HStack(alignment: .top, spacing: 10) {
                    DotMatrixView(pattern: DotPattern(phase), reduceMotion: reduceMotion)
                        .accessibilityHidden(true)
                    content(phase)
                    Spacer(minLength: 0)
                    if let onStop {
                        Button(T("Stop", table: "ThoughtUI"), action: onStop)
                            .pippa(.quiet).controlSize(.small)
                            .disabled(phase == .stopping)
                    }
                }
                .accessibilityElement(children: .contain)
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: thought.isVisible)
    }

    private func content(_ phase: WorkPhase) -> some View {
        let bubbles = thought.bubbles
        let hidden = showsAll ? 0 : max(0, bubbles.count - Self.visibleChips)
        return VStack(alignment: .leading, spacing: 6) {
            if let note = thought.phaseNote {
                HStack(spacing: 6) {
                    Text(note.title).foregroundStyle(Theme.ink2).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                    if let detail = note.detail {
                        Text(detail).foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.middle)
                    }
                }
                .font(Fonts.statusLine)
                .id(phase.kind)
                .transition(reduceMotion ? .identity : .opacity)
                .accessibilityElement(children: .combine)
            }
            if hidden > 0 {
                let count = hidden == 1 ? T("1 earlier step", table: "ThoughtUI") : T("%lld earlier steps", table: "ThoughtUI", hidden)
                Button { showsAllState.wrappedValue = thought.startedAt } label: {
                    HStack(spacing: 4) {
                        Text(count)
                        Image(systemName: "chevron.down").font(.scaled(size: 8.5, weight: .semibold))
                    }
                    .font(Fonts.hint).foregroundStyle(Theme.ink3).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(T("Show All Steps", table: "ThoughtUI"))
                .accessibilityHint(T("Show All Steps", table: "ThoughtUI"))
            }
            ForEach(bubbles.suffix(bubbles.count - hidden)) { bubble in
                StepChip(bubble: bubble, reduceMotion: reduceMotion)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
            if case .wakingUp(let progress?) = phase {
                WakeBar(progress: progress, reduceMotion: reduceMotion)
                    .frame(maxWidth: 360, alignment: .leading)
            }
            TimelineView(.periodic(from: thought.startedAt ?? Date(), by: 1)) { context in
                if thought.isSlow(at: context.date) {
                    Text(ThoughtLine.slowNote)
                        .font(.scaled(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.ink2)
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(.top, 1)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: bubbles)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: phase.kind)
    }
}

/// One step while Pippa works, the same object as the thought bubble at the pill (PillAura.ThoughtBubble): a small
/// picture, the everyday words, a count for repeated steps, and once done what came of it with a green check.
/// A step that did not work is marked, so a gap is never mistaken for "nothing there".
struct StepChip: View {
    var bubble: StepBubble
    var reduceMotion: Bool

    private var found: Bool { !bubble.running && !bubble.failed }

    var body: some View {
        HStack(spacing: 7) {
            StepPicture(symbol: bubble.failed ? "exclamationmark" : StepRow.symbol(bubble.kind),
                        color: StepPicture.color(bubble.kind, failed: bubble.failed), size: 20)
            Text(bubble.outcome.map { bubble.text + " · " + $0 } ?? bubble.text)
                .lineLimit(1).truncationMode(.middle).layoutPriority(1)
                .foregroundStyle(bubble.running ? Theme.ink : Theme.ink2)
                .contentTransition(reduceMotion ? .opacity : .interpolate)
            if bubble.count > 1 {
                Text(verbatim: "×\(bubble.count)")
                    .font(.scaled(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Theme.accentTint, in: Capsule())
                    .contentTransition(reduceMotion ? .identity : .numericText())
            }
            if found {
                Image(systemName: "checkmark").font(.scaled(size: 10, weight: .heavy)).foregroundStyle(Theme.ok)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.1).combined(with: .opacity))
            }
        }
        .font(.scaled(size: 13, weight: .semibold, design: .rounded))
        .padding(.leading, 5).padding(.trailing, 12).frame(minHeight: 30)
        .background {
            Capsule().fill(Theme.chatCard)
            if found { Capsule().fill(Theme.okTint) }
        }
        .overlay { Capsule().strokeBorder(Theme.chatBorder, lineWidth: 0.5) }
        .shadow(color: Theme.shadowInk.opacity(0.06), radius: 4, y: 1)
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.8), value: bubble)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bubble.spoken)
        .accessibilityValue(bubble.running ? T("Running", table: "ThoughtUI") : bubble.failed ? T("Didn’t work", table: "ThoughtUI") : T("Done", table: "ThoughtUI"))
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
            if let repeats = step.repeats, repeats > 1 {
                Text(verbatim: "\(repeats)×").foregroundStyle(Theme.ink3).monospacedDigit().lineLimit(1).fixedSize()
            }
        }
        .font(Fonts.hint)
    }

    static func symbol(_ kind: WorkStep.Kind?) -> String {
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
                    // What Pippa touched, at a glance: one small picture per kind of thing.
                    ForEach(Self.symbols(receipt), id: \.self) { symbol in
                        Image(systemName: symbol).font(.scaled(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
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
                            ForEach(Array(WorkStep.merged(steps).enumerated()), id: \.offset) { _, step in StepRow(step: step) }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(T("What I did", table: "ThoughtUI"))
                        .accessibilityValue(WorkStep.merged(steps).map(\.line).joined(separator: ". "))
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

    /// One picture per kind of thing the answer touched, in the order it happened (at most five).
    static func symbols(_ receipt: WorkReceipt) -> [String] {
        var result: [String] = []
        func add(_ symbol: String) { if !result.contains(symbol) { result.append(symbol) } }
        if !receipt.sources.isEmpty { add(StepRow.symbol(.file)) }
        for step in receipt.steps ?? [] where step.kind != nil { add(StepRow.symbol(step.kind)) }
        if receipt.lookedUpOnline { add(StepRow.symbol(.online)) }
        if receipt.checkedCalendar { add(StepRow.symbol(.calendar)) }
        return Array(result.prefix(5))
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
