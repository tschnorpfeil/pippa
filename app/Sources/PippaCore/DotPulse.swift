import Foundation

/// Pippa's working sign beside the thought line: twelve dots in a circle (a 4×4 grid without its corners). Which dots
/// light up in which order says what she does, so each pattern belongs to one named state, never to taste:
/// thinking runs clockwise round the circle, working through files or the web sweeps column by column, writing runs
/// row by row like the text appearing below it. A question shows the dots in the "needs you" colour at rest; stopping
/// leaves them dimmed. Adapted from Prima's AgentPuls (PRIME). The mark at the pill keeps its rings (WorkShape).
public enum DotPulse: String, Sendable, CaseIterable {
    case thinking, working, writing, question, still

    public init(_ shape: WorkShape) {
        switch shape {
        case .think: self = .thinking
        case .read, .swarm: self = .working
        case .write: self = .writing
        case .question: self = .question
        case .still: self = .still
        }
    }

    public init(_ phase: WorkPhase) { self.init(WorkShape(phase)) }

    public static let side = 4
    /// One run of the pattern; every delay is a tenth of it.
    public static let period = 1.5
    static let step = 0.15

    /// The four corners stay empty cells, so rows and columns keep their place and the square reads as a circle.
    public static func isCorner(_ index: Int) -> Bool {
        let row = index / side, column = index % side
        return (row == 0 || row == side - 1) && (column == 0 || column == side - 1)
    }

    /// Dot indices that are drawn (row-major, corners left out).
    public static let dots = (0..<(side * side)).filter { !isCorner($0) }

    /// Clockwise from the top left, rim then core: each inner dot moves with the rim dot that opens its quarter.
    private static let orbit: [Int: Int] = [1: 0, 2: 1, 7: 2, 11: 3, 14: 4, 13: 5, 8: 6, 4: 7, 5: 0, 6: 2, 10: 4, 9: 6]

    /// Delay of one dot in seconds; `nil` for patterns that do not move.
    public func delay(_ index: Int) -> Double? {
        let row = index / Self.side, column = index % Self.side
        switch self {
        case .thinking: return Double(Self.orbit[index] ?? 0) * Self.step
        case .working: return Double(column) * Self.step
        case .writing: return Double(row) * Self.step
        case .question, .still: return nil
        }
    }

    /// How strongly a dot shows the accent at `time` (0 = at rest, 1 = lit): up in the first 15 % of its run, back to
    /// rest by 45 %, eased in and out. Under Reduce Motion and for still patterns always 0.
    public func glow(_ index: Int, at time: Double, reduceMotion: Bool) -> Double {
        guard !reduceMotion, let delay = delay(index) else { return 0 }
        var p = (time - delay).truncatingRemainder(dividingBy: Self.period) / Self.period
        if p < 0 { p += 1 }
        func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }
        if p < 0.15 { return ease(p / 0.15) }
        if p < 0.45 { return 1 - ease((p - 0.15) / 0.3) }
        return 0
    }
}
