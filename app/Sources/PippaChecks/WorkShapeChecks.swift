import Foundation
import PippaCore

/// Pippa's working sign (PippaCore/WorkShape.swift): every phase has a shape, every shape can morph into every other
/// (same strokes, same point count), stays inside its square, and stands still under Reduce Motion.
func runWorkShapeChecks() {
    check("Work shape: each phase shows the shape of what Pippa does") {
        let expected: [(WorkPhase, WorkShape)] = [
            (.starting, .think), (.waitingForAnswer(continuing: true), .think), (.working, .think), (.retrying, .think),
            (.wakingUp(progress: 0.4), .think), (.gettingReady, .think), (.warmingUp, .think),
            (.reading(name: "Mietvertrag.pdf", index: 1, count: 1), .read), (.recognizing(name: "Scan.pdf", page: 1, pages: 2), .read),
            (.checkingSources, .read),
            (.lookingThrough(name: nil), .swarm), (.lookingUpOnline, .swarm), (.checkingCalendar, .swarm), (.choosingPassages, .swarm),
            (.writing, .write), (.preparingPreview, .write), (.condensing, .write),
            (.waitingForPerson, .question), (.stopping, .still),
        ]
        return expected.allSatisfy { WorkShape($0.0) == $0.1 }
    }

    check("Work shape: few enough shapes to tell apart, handwriting among them") {
        WorkShape.allCases.count <= 6 && WorkShape.allCases.contains(.write)
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

    check("Work shape: a question is orange, everything else Pippa blue") {
        let question = WorkShapeGeometry.frame(.question, at: 1, still: false).strokes.filter { $0.alpha > 0 }
        let others = WorkShape.allCases.filter { $0 != .question }
        return question.allSatisfy { $0.ink == .need }
            && others.allSatisfy { WorkShapeGeometry.frame($0, at: 1, still: false).strokes.allSatisfy { $0.ink == .accent } }
    }
}

/// The twelve-dot working sign (PippaCore/DotPulse.swift) and step durations.
func runDotPulseChecks() {
    check("Dot pulse: twelve dots, corners empty, each phase has its pattern") {
        DotPulse.dots.count == 12 && [0, 3, 12, 15].allSatisfy(DotPulse.isCorner)
            && DotPulse(.starting) == .thinking && DotPulse(.lookingUpOnline) == .working
            && DotPulse(.reading(name: "A.pdf", index: 1, count: 1)) == .working && DotPulse(.writing) == .writing
            && DotPulse(.waitingForPerson) == .question && DotPulse(.stopping) == .still
    }
    check("Dot pulse: columns, rows and the clockwise orbit run in tenths of the period") {
        let tenths = { (p: DotPulse) in Set(DotPulse.dots.map { Int((p.delay($0)! / 0.15).rounded()) }) }
        let orbit = [1, 2, 7, 11, 14, 13, 8, 4].map { DotPulse.thinking.delay($0)! }
        return tenths(.working) == [0, 1, 2, 3] && tenths(.writing) == [0, 1, 2, 3]
            && orbit == orbit.sorted() && Set(orbit).count == 8
            && DotPulse.question.delay(5) == nil && DotPulse.still.delay(5) == nil
    }
    check("Dot pulse: lights up and rests again, still under Reduce Motion") {
        let p = DotPulse.working
        // Dot 1 sits in column 1 (0.15 s late) and peaks 15 % into its run (another 0.225 s).
        return p.glow(1, at: 0.375, reduceMotion: false) > 0.99 && p.glow(1, at: 1.2, reduceMotion: false) == 0
            && p.glow(1, at: 0.375, reduceMotion: true) == 0 && DotPulse.question.glow(5, at: 0.2, reduceMotion: false) == 0
    }
    check("Step duration: hidden under half a second, tenths below ten, whole seconds above") {
        WorkStep.duration(0.3) == nil && WorkStep.duration(nil) == nil
            && WorkStep.duration(3.24).map { $0.hasPrefix("3") && $0.contains("2") && $0.hasSuffix(" s") } == true
            && WorkStep.duration(12.6) == L("%lld s", table: "Thought", 13)
    }
    check("Step duration: the thought line times each tool and merged steps add up") {
        let id = UUID(), start = Date(timeIntervalSinceReferenceDate: 0)
        var line = ThoughtLine()
        line.begin(id, at: start)
        line.apply(.toolStarted(name: "read", source: nil, step: "Lese A.pdf", kind: .file), request: id, at: start)
        line.apply(.toolEnded(name: "read"), request: id, at: start.addingTimeInterval(2))
        line.apply(.toolStarted(name: "read", source: nil, step: "Lese A.pdf", kind: .file), request: id, at: start.addingTimeInterval(2))
        line.apply(.toolEnded(name: "read"), request: id, at: start.addingTimeInterval(3.5))
        line.apply(.thinking("Erst lesen, "), request: id, at: start)
        line.apply(.thinking("dann antworten."), request: id, at: start)
        return line.bubbles.count == 1 && line.bubbles[0].seconds == 3.5 && line.doneSteps.first?.seconds == 3.5
            && line.reasoning == "Erst lesen, dann antworten."
    }
}
