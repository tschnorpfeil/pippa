import SwiftUI

/// What Pippa did on the way to the answer, as one row. While she works: her mark, what she is doing right now and the
/// seconds. Afterwards: "Worked for 18 s · 3 steps". A click opens the steps and her thinking.
struct WorkView: View {
    var message: ChatMessage
    var live: Bool
    /// The AI on this Mac is starting: the row says so, with an explanation behind the info button.
    var starting = false
    /// Words of the answer are coming in right now (not: there is text already).
    var writing = false
    var started: Date?
    @Environment(\.expandsWork) private var expandsWork
    private let openState = State(initialValue: false)
    private let hoverState = State(initialValue: false)
    /// Opened while the answer came in: the thinking keeps its six lines when the answer ends, so nothing below jumps.
    /// Opening it again shows all of it.
    private let cappedState = State(initialValue: false)
    private let infoState = State(initialValue: false)

    private var open: Bool { openState.wrappedValue }
    private var thinking: String? {
        guard let text = message.thinking?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
    private var canOpen: Bool { !message.steps.isEmpty || thinking != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button { toggle() } label: { header }
                    .buttonStyle(.plain)
                    .disabled(!canOpen)
                    .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering && canOpen } }
                    .onAppear { if expandsWork && canOpen { openState.wrappedValue = true } }
                if showsStarting { startingInfo.transition(.opacity) }
            }
            .animation(Theme.quick, value: showsStarting)
            // The steps fade in while this box grows and clips them: they never slide over the row above or the answer below.
            VStack(alignment: .leading, spacing: 0) {
                if open {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(message.steps) { step in stepRow(step) }
                        if let thinking {
                            Text(thinking)
                                .font(Typo.footnote).foregroundStyle(Theme.ink3).lineSpacing(3)
                                .textSelection(.enabled)
                                .lineLimit(live || cappedState.wrappedValue ? 6 : nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, Space.ml)
                                .overlay(alignment: .leading) { Rectangle().fill(Theme.fill3).frame(width: 2) }
                                .padding(.top, message.steps.isEmpty ? Space.xs : Space.s).padding(.bottom, Space.xs)
                        }
                    }
                    .padding(.leading, 22).padding(.top, Space.xxs)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Opening grows softly; closing is quick, because the conversation below moves up with it.
    private func toggle() {
        let opening = !open
        withAnimation(opening ? Theme.arrive : Theme.leave) {
            openState.wrappedValue = opening
            cappedState.wrappedValue = opening && live
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            if live {
                ZStack {
                    if writing && !showsStarting && message.steps.allSatisfy(\.done) {
                        Scribble(size: 16, color: Theme.accent).transition(.opacity)
                    } else {
                        PippaMark(size: 16, state: .arbeitet).transition(.opacity)
                    }
                }
                .frame(width: 16, height: 16)
                .animation(Theme.quick, value: writing)
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
        // "Working" turns into "Worked for 18 s" as a crossfade, not a jump.
        .animation(Theme.quick, value: live)
        .padding(.horizontal, Space.m)
        .frame(height: 28)
        .background(hoverState.wrappedValue ? Theme.rowHover : .clear, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .contentShape(Rectangle())
        .padding(.leading, -Space.m)
    }

    /// Nothing has come from the AI yet and it is still starting.
    private var showsStarting: Bool { live && starting && message.steps.isEmpty && message.text.isEmpty && thinking == nil }

    /// What "starting" means, for those who want to know.
    private var startingInfo: some View {
        Button { infoState.wrappedValue.toggle() } label: {
            Image(systemName: "info.circle").font(Typo.callout).foregroundStyle(Theme.ink3)
                .frame(width: 24, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(T("Why this takes a moment", table: "App"))
        .accessibilityLabel(T("Why this takes a moment", table: "App"))
        .popover(isPresented: infoState.projectedValue, arrowEdge: .bottom) {
            StartingExplanation()
        }
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
            // Where the time goes: the running step counts up, a finished one of a second or more says how long it took.
            if !step.done && live, let started = step.started {
                ElapsedSeconds(since: started).foregroundStyle(Theme.ink3)
            } else if let duration = step.duration, duration >= 1 {
                Text(Self.time(duration)).monospacedDigit().foregroundStyle(Theme.ink3.opacity(0.75)).fixedSize()
            }
        }
        .font(Typo.footnote)
        .frame(height: 24)
    }

    /// What she is doing right now: the running step, the AI starting, words coming in, else thinking. With the steps
    /// open the running one shows right below, so the row only says she is working.
    private var nowLabel: String {
        if let step = message.steps.last(where: { !$0.done }) { return open ? T("Working…", table: "App") : step.label }
        if showsStarting { return T("Starting my AI…", table: "App") }
        return writing ? T("Writing…", table: "App") : T("Thinking…", table: "App")
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

/// Seconds since `since` ("8 s", "1 min 5 s"), ticking once a second; nothing in the first second, so quick steps stay
/// quiet. The caller sets font and colour.
struct ElapsedSeconds: View {
    var since: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = context.date.timeIntervalSince(since)
            if seconds >= 1 {
                Text(WorkView.time(seconds))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: false))
                    .animation(.easeOut(duration: 0.2), value: Int(seconds))
            }
        }
        .fixedSize()
    }
}

/// Behind the info button while the AI starts: what is happening, in four sentences.
struct StartingExplanation: View {
    var body: some View {
        Text(T("My AI runs on this Mac, not on the internet. Before the first answer I load it into memory, which is several gigabytes. That takes a few seconds, or up to a minute when your Mac is busy. After ten minutes without a question I free the memory again.", table: "App"))
            .font(Typo.footnote).foregroundStyle(Theme.ink).lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: 280, alignment: .leading)
            .padding(Space.xl)
    }
}
