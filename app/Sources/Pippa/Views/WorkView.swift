import SwiftUI

/// What Pippa did on the way to the answer, as one row. While she works: her mark, what she is doing right now and the
/// seconds. Afterwards: "Worked for 18 s · 3 steps". A click opens the steps and her thinking.
struct WorkView: View {
    var message: ChatMessage
    var live: Bool
    var started: Date?
    @Environment(\.expandsWork) private var expandsWork
    private let openState = State(initialValue: false)
    private let hoverState = State(initialValue: false)

    private var open: Bool { openState.wrappedValue }
    private var thinking: String? {
        guard let text = message.thinking?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
    private var canOpen: Bool { !message.steps.isEmpty || thinking != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Button { withAnimation(Theme.arrive) { openState.wrappedValue.toggle() } } label: { header }
                .buttonStyle(.plain)
                .disabled(!canOpen)
                .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering && canOpen } }
                .onAppear { if expandsWork && canOpen { openState.wrappedValue = true } }
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(message.steps) { step in stepRow(step) }
                    if let thinking {
                        Text(thinking)
                            .font(Typo.footnote).foregroundStyle(Theme.ink3).lineSpacing(3)
                            .textSelection(.enabled)
                            .lineLimit(live ? 6 : nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, Space.ml)
                            .overlay(alignment: .leading) { Rectangle().fill(Theme.fill3).frame(width: 2) }
                            .padding(.top, message.steps.isEmpty ? Space.xs : Space.s).padding(.bottom, Space.xs)
                    }
                }
                .padding(.leading, 22)
                .transition(Theme.reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 7) {
            if live {
                PippaMark(size: 16, state: .arbeitet).frame(width: 16, height: 16)
                Text(nowLabel).foregroundStyle(Theme.ink2).lineLimit(1).truncationMode(.middle)
                    .contentTransition(.opacity)
                    .animation(Theme.quick, value: nowLabel)
                if let started {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = Int(context.date.timeIntervalSince(started))
                        if seconds >= 1 {
                            Text(T("%lld s", table: "App", seconds)).monospacedDigit().foregroundStyle(Theme.ink3)
                                .contentTransition(.numericText(countsDown: false))
                                .animation(Theme.quick, value: seconds)
                        }
                    }
                }
            } else {
                Text(summary).foregroundStyle(hoverState.wrappedValue ? Theme.ink2 : Theme.ink3).lineLimit(1)
                    .monospacedDigit()
                if message.steps.contains(where: \.failed) {
                    Image(systemName: "exclamationmark.circle.fill").font(Typo.caption).foregroundStyle(Theme.need)
                }
            }
            if canOpen {
                Image(systemName: "chevron.right").font(Typo.caption.weight(.semibold)).foregroundStyle(Theme.ink3)
                    .rotationEffect(.degrees(open ? 90 : 0))
            }
        }
        .font(Typo.callout)
        .padding(.horizontal, Space.m)
        .frame(height: 28)
        .background(hoverState.wrappedValue ? Theme.rowHover : .clear, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .contentShape(Rectangle())
        .padding(.leading, -Space.m)
    }

    private func stepRow(_ step: ChatStep) -> some View {
        HStack(spacing: Space.m) {
            Group {
                if !step.done && live { SpinRing(size: 11, lineWidth: 1.5) }
                else if step.failed { Image(systemName: "exclamationmark").font(Typo.caption.weight(.bold)).foregroundStyle(Theme.need) }
                else { Image(systemName: "checkmark").font(Typo.caption.weight(.semibold)).foregroundStyle(Theme.ink3) }
            }
            .frame(width: 14, height: 14)
            .contentTransition(.symbolEffect(.replace))
            Text(step.label).lineLimit(1).truncationMode(.middle).foregroundStyle(step.done || !live ? Theme.ink3 : Theme.ink2)
        }
        .font(Typo.footnote)
        .frame(height: 24)
    }

    /// What she is doing right now: the running step, else thinking or writing.
    private var nowLabel: String {
        if let step = message.steps.last(where: { !$0.done }) { return step.label }
        return message.text.isEmpty ? T("Thinking…", table: "App") : T("Writing…", table: "App")
    }

    private var summary: String {
        if message.stopped == true { return T("Stopped", table: "App") }
        let count = message.steps.count
        guard let duration = message.duration else {
            if count == 0 { return T("Thought it through", table: "App") }
            return count == 1 ? T("1 step", table: "App") : T("%lld steps", table: "App", count)
        }
        let time = Self.time(duration)
        switch count {
        case 0: return T("Thought for %@", table: "App", time)
        case 1: return T("Worked for %@ · 1 step", table: "App", time)
        default: return T("Worked for %@ · %lld steps", table: "App", time, count)
        }
    }

    /// "18 s", "2 min 5 s".
    static func time(_ duration: TimeInterval) -> String {
        let seconds = max(1, Int(duration.rounded()))
        if seconds < 60 { return T("%lld s", table: "App", seconds) }
        return T("%lld min %lld s", table: "App", seconds / 60, seconds % 60)
    }
}
