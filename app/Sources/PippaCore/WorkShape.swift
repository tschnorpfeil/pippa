import Foundation
import simd

/// Pippa's working sign in the chat line: the three rings of her mark take the shape of what she is doing,
/// instead of a row of blinking dots. Thinking is the mark's own working motion; reading lights up lines, searching
/// sends the rings out to roam until they meet on one spot, writing flows as endless handwriting, a question mark
/// asks for the person. One calm movement per shape; the line's words say the rest.
public enum WorkShape: String, Sendable, CaseIterable {
    /// Getting ready, waking up: the rings breathe in and out, one shortly after the other.
    case wake
    /// Waiting for the first words, working, retrying: the rings turn like the mark at the pill.
    case think
    /// Reading a file or recognizing text: lines light up from left to right, a small ring runs ahead.
    case read
    /// Choosing passages, looking through documents, the calendar or online: the rings roam and meet on one spot.
    case swarm
    /// Checking the answer against the sources: a green ring ticks off one line after another.
    case check
    /// Answer text is on its way: handwriting that keeps flowing and never repeats.
    case write
    /// Pippa needs the person: an orange question mark that sways a little.
    case question
    /// Stopping: the rings at rest, dimmed.
    case still

    public init(_ phase: WorkPhase) {
        switch phase {
        case .gettingReady, .wakingUp, .warmingUp: self = .wake
        case .starting, .waitingForAnswer, .working, .retrying, .condensing, .preparingPreview: self = .think
        case .reading, .recognizing: self = .read
        case .choosingPassages, .lookingThrough, .lookingUpOnline, .checkingCalendar: self = .swarm
        case .checkingSources: self = .check
        case .writing: self = .write
        case .waitingForPerson: self = .question
        case .stopping: self = .still
        }
    }
}

/// One picture of a shape: seven strokes of equal point count, so any shape can morph into any other point by point.
/// Coordinates run from -1 to 1 with y pointing down; unused strokes are tiny and invisible.
public struct WorkShapeFrame: Sendable {
    public enum Ink: Sendable { case accent, ok, need }
    public struct Stroke: Sendable {
        public var points: [SIMD2<Double>]
        public var alpha: Double
        public var ink: Ink
    }
    public var strokes: [Stroke]
}

/// Pure geometry (no drawing), so the checks can run it. Times are seconds; `still` is the Reduce Motion picture,
/// which does not change over time.
public enum WorkShapeGeometry {
    public static let pointCount = 64
    public static let strokeCount = 7
    /// Radii and strengths of the mark's three rings (MarkConst.kreisRadius, strangAbstand, straenge).
    static let radii = [0.68, 0.648, 0.616]
    static let alphas = [1.0, 0.6, 0.42]
    static let tau = Double.pi * 2

    public static func frame(_ shape: WorkShape, at time: Double, still: Bool) -> WorkShapeFrame {
        let t = still ? 0.9 : time
        var lines: [[SIMD2<Double>]]
        var alpha: [Double] = alphas
        var ink = WorkShapeFrame.Ink.accent
        var inks: [WorkShapeFrame.Ink]? = nil

        switch shape {
        case .wake:
            // Starts at the top of a breath, in step with the pill's hover breath (outer ring first).
            let breath = (0..<3).map { k in still ? 0.6 : 0.5 + 0.5 * cos((t - 0.22 * Double(k)) * tau / 3) }
            lines = (0..<3).map { k in
                let r = radii[k] * (0.3 + 0.62 * breath[k])
                return ellipse(center: .zero, rx: r, ry: r, wobble: 1, time: t, strand: k)
            }
            alpha = (0..<3).map { k in alphas[k] * (still ? 1 : 0.6 + 0.4 * breath[k]) }

        case .think:
            let axes = [68.0, -28, 119], stillAngles = [0.9, 1.7, 2.4]
            lines = (0..<3).map { k in
                let pose = orbit(axisDegrees: axes[k], angle: still ? stillAngles[k] : (t - 0.24 * Double(k)) * tau / 3.4)
                return (0..<pointCount).map { i in
                    let a = Double(i) / Double(pointCount) * tau, x = cos(a), y = sin(a)
                    let perspective = 1 + 0.25 * (x * pose.zx + y * pose.zy)
                    return SIMD2((x * pose.xx + y * pose.xy) * radii[k] * perspective,
                                 (x * pose.yx + y * pose.yy) * radii[k] * perspective)
                }
            }

        case .read:
            let ys = [-0.42, 0, 0.42], lengths = [1.3, 1.18, 0.8], x0 = -0.65, period = 1.25, total = period * 3 + 0.9
            let c = still ? 1.6 : t.truncatingRemainder(dividingBy: total) / period
            let row = min(2, Int(c)), f = c >= 3 ? 1 : c - Double(row)
            let turn = still ? 0 : smooth((c - 3) / 0.72)
            func progress(_ k: Int) -> Double { k < row ? 1 : k == row ? (still ? 0.6 : smooth(f)) : 0 }
            lines = (0..<3).map { k in polyline([SIMD2(x0, ys[k]), SIMD2(x0 + lengths[k], ys[k])]) }
            lines += (0..<3).map { k in polyline([SIMD2(x0, ys[k]), SIMD2(x0 + lengths[k] * max(0.02, progress(k)), ys[k])]) }
            lines.append(ellipse(center: SIMD2(x0 + lengths[row] * progress(row), ys[row]), rx: 0.085, ry: 0.085))
            let lit = 1 - turn, shimmer = still ? 0 : 0.04 * sin(t * tau / 2.2)
            alpha = Array(repeating: 0.28 + shimmer, count: 3) + (0..<3).map { progress($0) > 0.02 ? lit : 0 }
            alpha.append((c >= 3 ? lit : 1) * (still ? 1 : smooth(f * 8)))

        case .swarm:
            let period = 3.6, n = (t / period).rounded(.down), u = still ? 0.85 : t.truncatingRemainder(dividingBy: period) / period
            let target = SIMD2(0.22 * sin(n * 2.3 + 1), 0.16 * cos(n * 1.7))
            let together = smooth((u - 0.58) / 0.18) * (1 - smooth((u - 0.92) / 0.08))
            let paths: [(Double, Double, Double, Double)] = [(1.3, 1.7, 0, 1), (1.9, 1.1, 2, 0.5), (1.5, 2.3, 4, 2.6)]
            let stillSpots = [SIMD2(-0.36, 0.2), SIMD2(0.36, 0.2), SIMD2(0, -0.28)]
            lines = (0..<3).map { k in
                let (f1, f2, p1, p2) = paths[k]
                let roam = SIMD2(0.42 * sin(t * f1 + p1), 0.3 * sin(t * f2 + p2))
                let spot = still ? stillSpots[k] : roam + (target - roam) * together
                let found = u > 0.74 ? 0.03 * together * sin((u - 0.74) * tau * 3) : 0
                let r = (still ? 0.24 : 0.24 + 0.06 * together + found) * radii[k] / radii[0]
                return ellipse(center: spot, rx: r, ry: r, wobble: 0.4, time: t, strand: k)
            }
            alpha = (0..<3).map { k in
                let apart = [1, 0.8, 0.62][k]
                return apart + (alphas[k] - apart) * together
            }

        case .check:
            let ys = [-0.42, 0, 0.42]
            let c = still ? 1.2 : t.truncatingRemainder(dividingBy: 3.6) / 1.2
            let row = min(2, Int(c)), f = c - Double(row)
            let hop = still ? 1 : spring(f / 0.45), previous = row == 0 ? -0.7 : ys[row - 1]
            let y = previous + (ys[row] - previous) * clamp(hop, 0, 1.15)
            let fade = still ? 1 : (row == 0 ? smooth(f / 0.25) : 1) * (row == 2 ? 1 - smooth((f - 0.8) / 0.2) : 1)
            lines = (0..<3).map { k in polyline([SIMD2(-0.28, ys[k]), SIMD2(0.68, ys[k])]) }
            lines.append(ellipse(center: SIMD2(-0.56, y), rx: 0.11, ry: 0.11))
            alpha = (0..<3).map { k in k < row || (k == row && f > 0.35) ? 0.95 : 0.3 } + [fade]
            inks = [.accent, .accent, .accent, .ok]

        case .write:
            func noise(_ x: Double, _ s: Double) -> Double {
                0.5 * sin(x * 1.7 + s) + 0.3 * sin(x * 3.1 + s * 1.9) + 0.2 * sin(x * 5.3 + s * 0.7)
            }
            lines = (0..<3).map { k in
                let start = (still ? 2 : t) * 0.55 - Double(k) * 0.012
                return curve { u in
                    let w = u * 1.6 + start
                    let phase = w * tau * 1.6 + 1.2 * noise(w * 0.8, 1)
                    let ax = 0.17 + 0.08 * (noise(w * 1.3, 2) + 1) / 2
                    let ay = (0.2 + 0.12 * (noise(w * 1.1, 3) + 1) / 2) * (0.3 + 0.7 * sin(Double.pi * u))
                    return SIMD2(-0.6 + 1.2 * u + ax * sin(phase) + Double(k) * 0.01,
                                 0.04 + 0.05 * noise(w * 0.9, 4) + ay * cos(phase) + Double(k) * 0.014)
                }
            }

        case .question:
            ink = .need
            let sway = still ? 0 : 0.08 * sin(t * tau / 2.8)
            var hook: [SIMD2<Double>] = (0...50).map { i in
                let a = Double.pi * (1.1 + 1.25 * Double(i) / 50)
                return SIMD2(0.29 * cos(a), -0.28 + 0.29 * sin(a))
            }
            hook.append(SIMD2(0, 0.14))
            let mark = polyline(hook)
            lines = (0..<3).map { k in transform(mark, by: SIMD2(Double(k) * 0.012, Double(k) * 0.015 - 0.04), rotation: sway) }
            lines.append(transform(ellipse(center: SIMD2(0, 0.44), rx: 0.06, ry: 0.06), by: SIMD2(0, -0.04), rotation: sway))
            alpha = alphas + [1]

        case .still:
            lines = (0..<3).map { k in ellipse(center: .zero, rx: radii[k] * 0.62, ry: radii[k] * 0.62) }
            alpha = alphas.map { $0 * 0.45 }
        }

        let hidden = ellipse(center: .zero, rx: 0.05, ry: 0.05)
        while lines.count < strokeCount { lines.append(hidden) }
        while alpha.count < strokeCount { alpha.append(0) }
        let strokes = (0..<strokeCount).map { i in
            WorkShapeFrame.Stroke(points: lines[i], alpha: clamp(alpha[i], 0, 1), ink: inks.map { i < $0.count ? $0[i] : ink } ?? ink)
        }
        return WorkShapeFrame(strokes: strokes)
    }

    // MARK: Helpers

    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, x)) }
    static func smooth(_ x: Double) -> Double { let x = clamp(x, 0, 1); return x * x * (3 - 2 * x) }
    /// A soft spring with a little overshoot, 0 → 1.
    static func spring(_ x: Double) -> Double { let x = clamp(x, 0, 10); return 1 - exp(-6 * x) * cos(8 * x) }

    /// A ring, with the mark's organic wobble when `wobble` > 0.
    static func ellipse(center: SIMD2<Double>, rx: Double, ry: Double, wobble: Double = 0, time: Double = 0, strand: Int = 0) -> [SIMD2<Double>] {
        let s = Double(strand)
        return (0..<pointCount).map { i in
            let a = Double(i) / Double(pointCount) * tau
            let w = 1 + wobble * (0.035 * sin(3 * a + time / 1.4 + s * 1.2) + 0.026 * sin(2 * a - time / 2.1 + s * 0.84))
            return center + SIMD2(rx * cos(a) * w, ry * sin(a) * w)
        }
    }

    /// An open line, walked there and back so it has the same point count as a closed ring. `upTo` draws only the start.
    static func polyline(_ path: [SIMD2<Double>], upTo: Double = 1) -> [SIMD2<Double>] {
        var lengths = [0.0]
        for i in 1..<path.count { lengths.append(lengths[i - 1] + simd_length(path[i] - path[i - 1])) }
        let total = lengths[lengths.count - 1] * max(0.001, upTo)
        func at(_ d: Double) -> SIMD2<Double> {
            var i = 1
            while i < lengths.count - 1 && lengths[i] < d { i += 1 }
            let span = lengths[i] - lengths[i - 1]
            let u = span > 0 ? clamp((d - lengths[i - 1]) / span, 0, 1) : 0
            return path[i - 1] + (path[i] - path[i - 1]) * u
        }
        let half = pointCount / 2
        return (0..<pointCount).map { i in
            let s = i < half ? Double(i) / Double(half) : Double(pointCount - i) / Double(half)
            return at(s * total)
        }
    }

    static func curve(_ f: (Double) -> SIMD2<Double>) -> [SIMD2<Double>] {
        polyline((0...90).map { f(Double($0) / 90) })
    }

    static func transform(_ points: [SIMD2<Double>], by offset: SIMD2<Double>, rotation r: Double) -> [SIMD2<Double>] {
        points.map { p in offset + SIMD2(p.x * cos(r) - p.y * sin(r), p.x * sin(r) + p.y * cos(r)) }
    }

    /// Rotation about a fixed axis in the picture plane (as the mark's orbit), with the depth row for perspective.
    static func orbit(axisDegrees: Double, angle: Double) -> (xx: Double, xy: Double, yx: Double, yy: Double, zx: Double, zy: Double) {
        let a = axisDegrees * .pi / 180, ax = cos(a), ay = sin(a), c = cos(angle), s = sin(angle), k = 1 - c
        return (c + ax * ax * k, ax * ay * k, ax * ay * k, c + ay * ay * k, -ay * s, ax * s)
    }
}
