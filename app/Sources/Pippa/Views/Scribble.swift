import AppKit
import SwiftUI

/// Pippa writing: the three rings of her mark run as handwriting that keeps flowing and never repeats. Shown in place
/// of the mark while words of the answer come in. Ported from the pill's "write" shape (WorkShape, removed in c9931f4).
struct Scribble: View {
    var size: CGFloat
    var color: Color = IslandStyle.accent

    private static let alphas = [1.0, 0.6, 0.42]
    private let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduced)) { context in
            canvas(time: reduced ? 2 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func canvas(time: Double) -> some View {
        Canvas { canvas, area in
            // The handwriting reaches ±0.87 across: scaled so its widest loop just fits the mark's square.
            let scale = area.width / 2 * 1.1, line = max(1.3, size * 0.08)
            for k in 0..<3 {
                var path = Path()
                for (i, point) in Self.stroke(k, at: time).enumerated() {
                    let p = CGPoint(x: area.width / 2 + point.x * scale, y: area.height / 2 + point.y * scale)
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                canvas.stroke(path, with: .color(color.opacity(Self.alphas[k])),
                              style: StrokeStyle(lineWidth: line, lineCap: .round, lineJoin: .round))
            }
        }
    }

    /// One strand of the handwriting at `time` seconds, in -1...1 with y down. Pure, so the checks can run it.
    static func stroke(_ k: Int, at time: Double) -> [CGPoint] {
        func noise(_ x: Double, _ s: Double) -> Double {
            0.5 * sin(x * 1.7 + s) + 0.3 * sin(x * 3.1 + s * 1.9) + 0.2 * sin(x * 5.3 + s * 0.7)
        }
        let start = time * 0.55 - Double(k) * 0.012
        return (0...90).map { i in
            let u = Double(i) / 90
            let w = u * 1.6 + start
            let phase = w * .pi * 2 * 1.6 + 1.2 * noise(w * 0.8, 1)
            let ax = 0.17 + 0.08 * (noise(w * 1.3, 2) + 1) / 2
            let ay = (0.2 + 0.12 * (noise(w * 1.1, 3) + 1) / 2) * (0.3 + 0.7 * sin(Double.pi * u))
            return CGPoint(x: -0.6 + 1.2 * u + ax * sin(phase) + Double(k) * 0.01,
                           y: 0.04 + 0.05 * noise(w * 0.9, 4) + ay * cos(phase) + Double(k) * 0.014)
        }
    }
}
