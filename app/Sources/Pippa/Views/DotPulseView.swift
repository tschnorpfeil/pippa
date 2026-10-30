import PippaCore
import SwiftUI

/// The twelve-dot working sign (PippaCore/DotPulse.swift). Dots are a seventh of the side with equal gaps. Decorative:
/// the words beside it say the same, so VoiceOver skips it. Under Reduce Motion the dots stand still.
struct DotPulseView: View {
    var pulse: DotPulse
    var reduceMotion: Bool
    var side: CGFloat = Self.side

    static let side: CGFloat = 16

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || pulse.delay(DotPulse.dots[0]) == nil)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)
            Canvas { gc, size in
                let unit = min(size.width, size.height) / CGFloat(DotPulse.side * 2 - 1)
                for index in DotPulse.dots {
                    let rect = CGRect(x: CGFloat(index % DotPulse.side) * unit * 2, y: CGFloat(index / DotPulse.side) * unit * 2,
                                      width: unit, height: unit)
                    let dot = Path(ellipseIn: rect)
                    gc.fill(dot, with: .color(rest))
                    let glow = pulse.glow(index, at: t, reduceMotion: reduceMotion)
                    if glow > 0.01 { gc.fill(dot, with: .color(Theme.accent.opacity(glow))) }
                }
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    private var rest: Color {
        switch pulse {
        case .question: Theme.needDot
        case .still: Theme.ink3.opacity(0.25)
        default: Theme.ink3.opacity(0.45)
        }
    }
}
