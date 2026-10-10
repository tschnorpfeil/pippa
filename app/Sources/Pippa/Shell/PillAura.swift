import AppKit
import PippaCore
import SwiftUI

// What surrounds the collapsed pill while Pippa works. It is drawn on the stage, outside the pill's clipped shape:
// a soft light that hugs the pill and slowly wanders around it (no rim), and one thought bubble at a time that rises
// out of Pippa's mark through three small dots, turns into what came of the step, and floats away.
// The bubble shows the same words, picture and check as the step chip in the conversation (ThoughtLineView.StepChip):
// one object in two places. Nothing here is timed or guessed: every bubble is a real step (ThoughtLine.bubbles).

/// One thought above the pill: a step, its finding, or the one calm sentence after a long wait.
struct AuraThought: Equatable, Identifiable {
    var id: String
    var kind: WorkStep.Kind?
    var text: String
    var outcome: String?
    var count = 1
    var running = true
    var failed = false
    /// The calm sentence for a long wait (a clock instead of a kind).
    var slow = false

    init(_ bubble: StepBubble) {
        id = "step:\(bubble.id)"; kind = bubble.kind; text = bubble.text; outcome = bubble.outcome
        count = bubble.count; running = bubble.running; failed = bubble.failed
    }

    init(slow text: String) {
        id = "slow"; self.text = text; running = false; slow = true
    }

    var spoken: String { [text, outcome].compactMap { $0 }.joined(separator: ", ") }
}

/// What the aura shows; the shell controller feeds it on every model change.
@MainActor
final class PillAuraState: ObservableObject {
    /// The pill and Pippa's mark in the aura's own coordinates (top left origin).
    @Published private(set) var pill: CGRect = .zero
    @Published private(set) var mark: CGRect = .zero
    @Published private(set) var working = false
    /// Mouse on the pill.
    @Published private(set) var hovered = false
    @Published private(set) var thought: AuraThought?
    /// Too little room above the pill (it sits near the top of the screen): the bubble hangs below it.
    @Published private(set) var below = false
    /// How the glow follows the latest change of `pill`: the shape's own spring while it morphs, nil when it jumps
    /// (dragged, another screen, Reduce Motion). Set together with `pill`, so the light never lags or runs ahead.
    @Published private(set) var pillMotion: Animation?
    /// The glow's own clock: when its light started wandering, and when it stood still again (nil while it wanders).
    /// The light keeps its place when work ends or the mouse leaves; it only goes back to the resting pose once it
    /// is out of sight, so it never jumps while it can be seen.
    @Published private(set) var glowStart: Date?
    @Published private(set) var glowStopped: Date?

    /// A finished step stays this long as its finding before it floats away (unless the next step comes first).
    static let findingShown: Duration = .milliseconds(1700)
    /// The calm sentence stays this long.
    static let slowShown: Duration = .milliseconds(3600)

    private var shownStep: StepBubble?
    private var retireTask: Task<Void, Never>?
    private var slowTask: Task<Void, Never>?
    private var answerStart: Date?
    private var slowSaid = false
    private var glowRestTask: Task<Void, Never>?

    func setHovered(_ on: Bool) {
        guard hovered != on else { return }
        hovered = on
        settleGlow()
    }

    /// - Parameters:
    ///   - pill: the collapsed pill; nil while the shell is open (the light stays where the pill was and fades there).
    ///   - motion: the spring the shape morphs with right now, nil when it jumps.
    func update(pill: CGRect?, mark: CGRect?, motion: ShellTokens.Spring?, below: Bool, working: Bool, step: StepBubble?,
                startedAt: Date?, slowText: String) {
        if let pill, self.pill != pill {
            // The very first place has nothing to come from.
            pillMotion = self.pill == .zero ? nil
                : motion.map { .interpolatingSpring(mass: $0.mass, stiffness: $0.stiffness, damping: $0.damping) }
            self.pill = pill
        }
        if let mark, self.mark != mark { self.mark = mark }
        if self.below != below { self.below = below }
        if self.working != working {
            self.working = working
            settleGlow()
        }
        guard working else {
            shownStep = nil; answerStart = nil; slowSaid = false
            retireTask?.cancel(); slowTask?.cancel()
            if thought != nil { thought = nil }
            return
        }
        if answerStart != startedAt {
            answerStart = startedAt; slowSaid = false
            scheduleSlow(startedAt: startedAt, text: slowText)
        }
        guard let step, step != shownStep else { return }
        shownStep = step
        retireTask?.cancel()
        thought = AuraThought(step)
        if !step.running {
            // The finding stays a moment, then floats away; a new step replaces it sooner.
            retireTask = Task { [weak self] in
                try? await Task.sleep(for: Self.findingShown)
                guard !Task.isCancelled, let self, self.thought?.id == "step:\(step.id)" else { return }
                self.thought = nil
            }
        }
    }

    /// Work starts: the light wanders on from wherever it stands. Work ends: it stands still where it is. Out of
    /// sight (no work, no mouse) it goes back to the resting pose after the fade.
    private func settleGlow() {
        glowRestTask?.cancel()
        if working {
            if let start = glowStart, let stopped = glowStopped {
                glowStart = Date().addingTimeInterval(-stopped.timeIntervalSince(start))
            } else if glowStart == nil {
                glowStart = Date()
            }
            glowStopped = nil
            return
        }
        if glowStart != nil && glowStopped == nil { glowStopped = Date() }
        guard !hovered, glowStart != nil else { return }
        glowRestTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, !self.working, !self.hovered else { return }
            self.glowStart = nil
            self.glowStopped = nil
        }
    }

    /// After ten seconds, once per answer, when no step is in the air: "Dauert etwas länger, ich bleib dran."
    private func scheduleSlow(startedAt: Date?, text: String) {
        slowTask?.cancel()
        guard let startedAt else { return }
        let wait = max(0, ThoughtLine.slowAfter - Date().timeIntervalSince(startedAt))
        slowTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, self.working, !self.slowSaid else { return }
            self.slowSaid = true
            guard self.thought == nil || self.thought?.running == false else { return }
            self.retireTask?.cancel()
            self.thought = AuraThought(slow: text)
            try? await Task.sleep(for: Self.slowShown)
            guard !Task.isCancelled, self.thought?.id == "slow" else { return }
            self.thought = nil
        }
    }
}

/// Covers the stage; never takes a click (the pill and its cards below keep theirs).
final class PillAuraHost: NSHostingView<PillAura> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

struct PillAura: View {
    @ObservedObject var state: PillAuraState
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool { systemReduceMotion || MarkHub.shared.reduced }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Hover at rest: the same light, standing still and at half strength. While working it only brightens a little.
            // Each part has its own animation: the shape follows the pill's spring, strength and lift fade, and
            // none of them carries the others along.
            WanderingGlow(reduceMotion: reduceMotion, start: state.glowStart, stopped: state.glowStopped,
                          lift: state.hovered && state.working ? 0.12 : 0)
                .animation(.easeOut(duration: 0.3), value: state.hovered)
                .animation(state.pillMotion) {
                    $0.frame(width: state.pill.width + 12, height: state.pill.height + 10)
                        .offset(x: state.pill.minX - 6, y: state.pill.minY - 5)
                }
                .animation(state.hovered ? .easeOut(duration: 0.3) : .easeInOut(duration: state.working ? 0.9 : 0.6)) {
                    $0.opacity(glow)
                }
            thoughtSpot
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var glow: Double { state.working ? 1 : state.hovered ? 0.5 : 0 }

    /// The bubble's corner sits just above (or below) Pippa's mark; the dots lead from the mark to it.
    private var thoughtSpot: some View {
        let height: CGFloat = 96
        let x = state.mark.minX - 6
        let y = state.below ? state.pill.maxY + 4 : state.pill.minY - height - 4
        return ZStack(alignment: state.below ? .topLeading : .bottomLeading) {
            if let thought = state.thought {
                ThoughtBubble(thought: thought, below: state.below, reduceMotion: reduceMotion)
                    .id(thought.id)
                    .transition(reduceMotion ? .opacity : .asymmetric(insertion: .identity, removal: .floatAway(below: state.below)))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .easeIn(duration: 0.85), value: state.thought?.id)
        .frame(width: 320, height: height, alignment: state.below ? .topLeading : .bottomLeading)
        // The bubble rides along with Pippa's mark when the pill changes width.
        .animation(state.pillMotion) { $0.offset(x: x, y: y) }
    }
}

/// A light that hugs the pill: two soft highlights wander slowly along it over a faint accent base, and the whole
/// light breathes a little. Its clock runs from `start` and stands at `stopped`; without a start it shows the resting
/// pose (one highlight at each end), which is also where wandering begins, so the light never jumps.
/// Reduce Motion: always the resting pose, nothing breathes.
struct WanderingGlow: View, Animatable {
    var reduceMotion: Bool
    var start: Date?
    var stopped: Date?
    /// Extra brightness while the mouse is on the working pill (animated).
    var lift = 0.0
    private static let cycle = 7.0
    private static let breath = 4.2
    private static let violet = Color(red: 132 / 255, green: 110 / 255, blue: 255 / 255)

    var animatableData: Double {
        get { lift }
        set { lift = newValue }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || start == nil || stopped != nil)) { context in
            let t = reduceMotion ? 0 : start.map { max(0, (stopped ?? context.date).timeIntervalSince($0)) } ?? 0
            // A quarter cycle in: the highlights start at the two ends of the pill.
            let a = 2 * Double.pi * (t / Self.cycle + 0.25)
            let first = UnitPoint(x: 0.5 + 0.38 * sin(a), y: 0.5 + 0.3 * sin(1.7 * a))
            let second = UnitPoint(x: 0.5 - 0.38 * sin(a), y: 0.5 - 0.3 * sin(1.7 * a + 0.8))
            let intensity = 0.875 + 0.125 * cos(2 * Double.pi * t / Self.breath) + lift
            GeometryReader { geo in
                let reach = max(geo.size.width, geo.size.height) * 0.55
                ZStack {
                    Capsule().fill(Theme.accentFill.opacity(0.2))
                    Capsule().fill(RadialGradient(colors: [Theme.accentFill.opacity(0.7 * intensity), .clear], center: first,
                                                  startRadius: 0, endRadius: reach))
                    Capsule().fill(RadialGradient(colors: [Self.violet.opacity(0.55 * intensity), .clear], center: second,
                                                  startRadius: 0, endRadius: reach))
                }
                .blur(radius: 8)
            }
        }
        .accessibilityHidden(true)
    }
}

/// One thought: three dots out of Pippa's mark, then the bubble pops up on a spring. While the step runs its words
/// shimmer softly; once done they change in place to the finding with a green check. A repeat counts up.
struct ThoughtBubble: View {
    var thought: AuraThought
    var below: Bool
    var reduceMotion: Bool
    private let shownState = State<Bool>(initialValue: false)
    private var shown: Bool { shownState.wrappedValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if below { dots }
            bubble
                .scaleEffect(shown || reduceMotion ? 1 : 0.55, anchor: below ? .topLeading : .bottomLeading)
                .offset(y: shown || reduceMotion ? 0 : (below ? -10 : 10))
                .opacity(shown ? 1 : 0)
                .animation(reduceMotion ? .easeOut(duration: 0.25) : .spring(response: 0.5, dampingFraction: 0.62).delay(0.17), value: shown)
            if !below { dots }
        }
        .onAppear { shownState.wrappedValue = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(thought.spoken)
    }

    /// Small at Pippa's mark, bigger towards the bubble, popping up one after another from the mark.
    private var dots: some View {
        let sizes: [CGFloat] = below ? [5, 7, 9] : [9, 7, 5]
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(sizes.enumerated()), id: \.offset) { index, size in
                let fromMark = below ? index : sizes.count - 1 - index
                Circle().fill(.regularMaterial)
                    .overlay { Circle().strokeBorder(Theme.chatBorder, lineWidth: 0.5) }
                    .frame(width: size, height: size)
                    .padding(.leading, 12 + CGFloat(fromMark) * 4)
                    .scaleEffect(shown || reduceMotion ? 1 : 0.2)
                    .opacity(shown ? 1 : 0)
                    .animation(reduceMotion ? .easeOut(duration: 0.25) : .spring(response: 0.3, dampingFraction: 0.55).delay(0.07 * Double(fromMark)), value: shown)
            }
        }
    }

    private var bubble: some View {
        HStack(spacing: 8) {
            StepPicture(symbol: thought.slow ? "clock" : thought.failed ? "exclamationmark" : StepRow.symbol(thought.kind),
                        color: thought.slow ? Theme.accentFill : StepPicture.color(thought.kind, failed: thought.failed), size: 22)
            Text(words)
                .foregroundStyle(thought.running ? Theme.ink : Theme.ink2)
                .lineLimit(1)
                .contentTransition(reduceMotion ? .opacity : .interpolate)
            if thought.count > 1 {
                Text(verbatim: "×\(thought.count)")
                    .font(.scaled(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Theme.accentTint, in: Capsule())
                    .contentTransition(reduceMotion ? .identity : .numericText())
            }
            if !thought.running && !thought.failed && !thought.slow {
                Image(systemName: "checkmark").font(.scaled(size: 10.5, weight: .heavy)).foregroundStyle(Theme.ok)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.1).combined(with: .opacity))
            }
        }
        .font(.scaled(size: 13.5, weight: .semibold, design: .rounded))
        .padding(.leading, 6).padding(.trailing, 14).frame(height: 34)
        .fixedSize()
        .background {
            Capsule().fill(.regularMaterial)
            if !thought.running && !thought.failed && !thought.slow { Capsule().fill(Theme.okTint) }
        }
        .overlay { Capsule().strokeBorder(Theme.chatBorder, lineWidth: 0.5) }
        .shadow(color: Theme.shadowInk.opacity(0.16), radius: 10, y: 4)
        .animation(reduceMotion ? .easeInOut(duration: 0.25) : .spring(response: 0.45, dampingFraction: 0.8), value: thought)
    }

    /// The chip's words, shortened in the middle so the bubble stays small (the conversation shows them in full).
    private var words: String {
        let limit = PillStatus.stepLimit
        var text = thought.text
        if text.count > limit {
            let head = (limit - 1) * 2 / 3
            text = String(text.prefix(head)).trimmingCharacters(in: .whitespaces) + "…"
                + String(text.suffix(limit - 1 - head)).trimmingCharacters(in: .whitespaces)
        }
        guard let outcome = thought.outcome, !thought.running else { return text }
        return text + " · " + outcome
    }
}

/// The small picture of a step, white on a colour per kind of thing: the same in the thought bubble at the pill and
/// on the step chip in the conversation.
struct StepPicture: View {
    var symbol: String
    var color: Color
    var size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.scaled(size: size * 0.48, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(color))
            .accessibilityHidden(true)
    }

    static func color(_ kind: WorkStep.Kind?, failed: Bool) -> Color {
        if failed { return Theme.needDot }
        switch kind {
        case .mail: return Color(red: 0.10, green: 0.45, blue: 0.91)
        case .calendar, .reminder: return Color(red: 0.90, green: 0.28, blue: 0.30)
        case .online: return Color(red: 0.05, green: 0.55, blue: 0.60)
        case .file, .change, .search: return Color(red: 0.45, green: 0.50, blue: 0.58)
        default: return Theme.accentFill
        }
    }
}

/// Floats up (or down, below the pill), a little blurred, and fades.
private struct FloatAway: ViewModifier {
    var gone: Bool
    var below: Bool
    func body(content: Content) -> some View {
        content
            .offset(y: gone ? (below ? 30 : -30) : 0)
            .blur(radius: gone ? 6 : 0)
            .opacity(gone ? 0 : 1)
    }
}

extension AnyTransition {
    static func floatAway(below: Bool) -> AnyTransition {
        .modifier(active: FloatAway(gone: true, below: below), identity: FloatAway(gone: false, below: below))
    }
}
