import PippaCore
import SwiftUI

/// The mark's working shape (MarkView) as drawn right now. Follows the target shape a little behind it each frame, which is the morph between
/// shapes; snaps when there is nothing to follow from or under Reduce Motion.
final class WorkShapeMorph {
    private var strokes: [WorkShapeFrame.Stroke] = []
    private var last: Double?

    /// Starts from this picture, so the next target morphs out of it instead of appearing at once.
    func seed(_ frame: WorkShapeFrame) { strokes = frame.strokes }

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
