import Foundation
import PippaCore

/// Pippa's working sign (PippaCore/WorkShape.swift): every phase has a shape, every shape can morph into every other
/// (same strokes, same point count), stays inside its square, and stands still under Reduce Motion.
func runWorkShapeChecks() {
    check("Work shape: each phase shows the shape of what Pippa does") {
        let expected: [(WorkPhase, WorkShape)] = [
            (.starting, .think), (.waitingForAnswer(continuing: true), .think), (.working, .think), (.retrying, .think),
            (.wakingUp(progress: 0.4), .wake), (.gettingReady, .wake), (.warmingUp, .wake),
            (.reading(name: "Mietvertrag.pdf", index: 1, count: 1), .read), (.recognizing(name: "Scan.pdf", page: 1, pages: 2), .read),
            (.lookingThrough(name: nil), .swarm), (.lookingUpOnline, .swarm), (.checkingCalendar, .swarm), (.choosingPassages, .swarm),
            (.checkingSources, .check), (.writing, .write), (.waitingForPerson, .question), (.stopping, .still),
        ]
        return expected.allSatisfy { WorkShape($0.0) == $0.1 }
    }

    check("Work shape: every shape has the same strokes and points, all inside the square") {
        let times = stride(from: 0.0, through: 20.0, by: 0.05)
        for shape in WorkShape.allCases {
            for still in [false, true] {
                for t in times {
                    let frame = WorkShapeGeometry.frame(shape, at: t, still: still)
                    guard frame.strokes.count == WorkShapeGeometry.strokeCount else { return false }
                    for stroke in frame.strokes {
                        guard stroke.points.count == WorkShapeGeometry.pointCount, (0...1).contains(stroke.alpha) else { return false }
                        // Half a stroke width of room to the edge, so nothing is cut off.
                        guard stroke.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 0.9 && abs($0.y) <= 0.9 }) else {
                            print("  \(shape) at \(t) leaves the square")
                            return false
                        }
                    }
                }
            }
        }
        return true
    }

    check("Work shape: with Reduce Motion every shape is a still picture") {
        WorkShape.allCases.allSatisfy { shape in
            let a = WorkShapeGeometry.frame(shape, at: 3, still: true), b = WorkShapeGeometry.frame(shape, at: 17.4, still: true)
            return zip(a.strokes, b.strokes).allSatisfy { $0.points == $1.points && $0.alpha == $1.alpha }
        }
    }

    check("Work shape: a question is orange, a checked line green, everything else Pippa blue") {
        let question = WorkShapeGeometry.frame(.question, at: 1, still: false).strokes.filter { $0.alpha > 0 }
        let check = WorkShapeGeometry.frame(.check, at: 1, still: false).strokes
        let read = WorkShapeGeometry.frame(.read, at: 1, still: false).strokes
        return question.allSatisfy { $0.ink == .need } && check[3].ink == .ok && check[0].ink == .accent
            && read.allSatisfy { $0.ink == .accent }
    }
}
