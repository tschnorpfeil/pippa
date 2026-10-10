import PippaCore
import SwiftUI

/// Pippa's working sign beside the thought line: the rings of her mark in the shape of what she is doing
/// (PippaCore/WorkShape.swift). A new shape morphs out of the old one point by point. Decorative: VoiceOver skips it.
/// It only animates while it is on screen (the line removes it when hidden), at a low frame rate, and under
/// Reduce Motion shows each shape as a still picture that changes without morphing.
struct WorkShapeView: View {
    var shape: WorkShape
    var reduceMotion: Bool

    static let side: CGFloat = 16
    /// Points per second the drawn shape follows its target; high enough to feel immediate, low enough to morph.
    private static let follow = 9.0
    private let morphState = State(initialValue: WorkShapeMorph())

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let morph = morphState.wrappedValue
            Canvas { gc, size in
                let target = WorkShapeGeometry.frame(shape, at: t.truncatingRemainder(dividingBy: 3600), still: reduceMotion)
                let strokes = morph.step(toward: target, at: t, follow: Self.follow, snap: reduceMotion)
                let half = Double(min(size.width, size.height)) / 2
                let style = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                for stroke in strokes where stroke.alpha > 0.01 {
                    var path = Path()
                    for (i, p) in stroke.points.enumerated() {
                        let point = CGPoint(x: half + p.x * half, y: half + p.y * half)
                        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    path.closeSubpath()
                    gc.stroke(path, with: .color(Self.color(stroke.ink).opacity(stroke.alpha)), style: style)
                }
            }
        }
        .frame(width: Self.side, height: Self.side)
        .accessibilityHidden(true)
    }

    private static func color(_ ink: WorkShapeFrame.Ink) -> Color {
        switch ink {
        case .accent: Theme.accent
        case .ok: Theme.ok
        case .need: Theme.needDot
        }
    }
}

/// What is drawn right now. Follows the target shape a little behind it each frame, which is the morph between
/// shapes; snaps when there is nothing to follow from or under Reduce Motion.
final class WorkShapeMorph {
    private var strokes: [WorkShapeFrame.Stroke] = []
    private var last: Double?

    func step(toward target: WorkShapeFrame, at time: Double, follow: Double, snap: Bool) -> [WorkShapeFrame.Stroke] {
        let dt = last.map { min(0.1, max(0, time - $0)) } ?? 0
        last = time
        guard !snap, strokes.count == target.strokes.count else {
            strokes = target.strokes
            return strokes
        }
        let k = 1 - exp(-dt * follow)
        for i in strokes.indices {
            let goal = target.strokes[i]
            for j in strokes[i].points.indices {
                strokes[i].points[j] += (goal.points[j] - strokes[i].points[j]) * k
            }
            strokes[i].alpha += (goal.alpha - strokes[i].alpha) * k
            strokes[i].ink = goal.ink
        }
        return strokes
    }
}
