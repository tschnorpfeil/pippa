import PippaCore
import SwiftUI

/// The motion family of a working phase. One calm movement per family; the line's words say the rest.
enum DotPattern: Equatable {
    /// Reading a file or one source: a soft sweep from left to right.
    case sweep
    /// Text recognition: a scan line from top to bottom.
    case scan
    /// Choosing passages, going through documents, the calendar: a few dots light one after another.
    case sequence
    /// Getting ready, waiting, retry, condensing: the whole matrix breathes slowly.
    case breathe
    /// Checking the answer against the sources: dots fill diagonally.
    case fill
    /// Stopping: still and dimmed.
    case still

    init(_ phase: WorkPhase) {
        switch phase {
        case .reading, .lookingThrough(name: .some): self = .sweep
        case .recognizing: self = .scan
        case .choosingPassages, .lookingThrough(name: nil), .checkingCalendar: self = .sequence
        case .checkingSources: self = .fill
        case .stopping: self = .still
        default: self = .breathe
        }
    }

    /// Slowest-to-fastest: every cycle is at least 2.4 s, nothing flashes.
    private var period: Double {
        switch self {
        case .sweep, .scan: 2.6
        case .sequence: 4.8
        case .breathe: 4.0
        case .fill: 3.6
        case .still: 1
        }
    }

    /// Dots lit in turn, as (row, column) in reading order of the sequence.
    private static let order: [(Int, Int)] = [(0, 0), (1, 2), (2, 1), (0, 2), (1, 0)]

    private static func bump(_ distance: Double, width: Double) -> Double {
        let x = max(0, 1 - distance / width)
        return x * x * (3 - 2 * x)
    }

    /// 0...1 brightness of one dot at time `t` (seconds), row `r`, column `c`.
    func level(row r: Int, column c: Int, at t: Double) -> Double {
        let frac = (t / period).truncatingRemainder(dividingBy: 1)
        switch self {
        case .sweep: return Self.bump(abs(Double(c) - (-0.6 + frac * 4.2)), width: 1.3)
        case .scan: return Self.bump(abs(Double(r) - (-0.6 + frac * 4.2)), width: 1.3)
        case .sequence:
            guard let slot = Self.order.firstIndex(where: { $0 == (r, c) }) else { return 0 }
            let n = Double(Self.order.count)
            let u = frac * n
            let d = min(abs(u - Double(slot)), n - abs(u - Double(slot)))
            return Self.bump(d, width: 0.9)
        case .breathe: return 0.5 - 0.5 * cos(frac * 2 * .pi)
        case .fill:
            let filled = min(1, max(0, frac * 6.5 - Double(r + c)))
            let release = frac > 0.86 ? max(0, 1 - (frac - 0.86) / 0.14) : 1
            return filled * filled * (3 - 2 * filled) * release
        case .still: return 0
        }
    }

    /// The same phase as a still picture, for Reduce Motion.
    func stillLevel(row r: Int, column c: Int) -> Double {
        switch self {
        case .sweep: c == 1 ? 1 : 0.15
        case .scan: r == 1 ? 1 : 0.15
        case .sequence: Self.order.contains { $0 == (r, c) } && (r + c) % 2 == 0 ? 1 : 0.15
        case .breathe: 0.55
        case .fill: r + c <= 2 ? 1 : 0.15
        case .still: 0
        }
    }
}

/// A 3×3 matrix of dots in Pippa blue, about as tall as the line's text. Decorative: VoiceOver skips it.
/// It only animates while it is on screen (the line removes it when hidden), at a low frame rate, and stands
/// still, per phase, under Reduce Motion.
struct DotMatrixView: View {
    var pattern: DotPattern
    var reduceMotion: Bool

    static let side: CGFloat = 12
    private static let dot: CGFloat = 2.5
    private static let floor: Double = 0.34

    var body: some View {
        ZStack {
            // Patterns cross-fade; the old one leaves while the new one arrives.
            matrix.id(pattern).transition(reduceMotion ? .identity : .opacity)
        }
        .frame(width: Self.side, height: Self.side)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: pattern)
        .accessibilityHidden(true)
    }

    private var matrix: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: reduceMotion || pattern == .still)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { gc, size in
                let gap = (size.width - 3 * Self.dot) / 2
                for r in 0..<3 {
                    for c in 0..<3 {
                        let level = reduceMotion || pattern == .still
                            ? pattern.stillLevel(row: r, column: c) : pattern.level(row: r, column: c, at: t)
                        let alpha = Self.floor + (1 - Self.floor) * level
                        let rect = CGRect(x: CGFloat(c) * (Self.dot + gap), y: CGFloat(r) * (Self.dot + gap),
                                          width: Self.dot, height: Self.dot)
                        gc.fill(Path(ellipseIn: rect), with: .color(Theme.accent.opacity(alpha)))
                    }
                }
            }
        }
    }
}
