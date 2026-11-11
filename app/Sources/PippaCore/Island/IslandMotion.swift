import Foundation

/// Critically damped spring on Pippa Island's progress (0 closed, 1 open) or on a size in points (the open panel's
/// height): it eases out without overshoot or rebound, in fixed sub-steps so the motion does not depend on the frame
/// rate. Retargeting keeps value and velocity, so a reversal in flight continues from wherever the shape is.
public struct IslandSpring: Equatable, Sendable {
    public struct Parameters: Equatable, Sendable {
        /// Perceptual duration: one undamped period, 2π / ω.
        public var response: Double
        /// Damping ratio; 1 is critical damping, the fastest motion that never overshoots.
        public var damping: Double
    }
    // Critical damping reaches 95 % after 0.755 × response: opening ~240 ms, closing ~180 ms.
    public static let opening = Parameters(response: 0.32, damping: 1)
    public static let closing = Parameters(response: 0.24, damping: 1)
    /// One sub-step of the integration.
    public static let step = 1.0 / 480

    public private(set) var value: Double
    public private(set) var velocity: Double = 0
    public private(set) var target: Double
    public private(set) var parameters = IslandSpring.closing
    /// The value never leaves these bounds.
    public let bounds: ClosedRange<Double>
    /// Closer than this to the target (and nearly still), the value snaps onto it.
    public let tolerance: Double

    /// `tolerance` 0.001 is a third of a point on the widest panel for a progress; a size in points takes ~0.25.
    public init(value: Double = 0, bounds: ClosedRange<Double> = 0...1, tolerance: Double = 0.001) {
        self.value = value
        target = value
        self.bounds = bounds
        self.tolerance = tolerance
    }

    public var isSettled: Bool { value == target && velocity == 0 }

    /// New target; value and velocity stay as they are.
    public mutating func retarget(_ target: Double, _ parameters: Parameters) {
        self.target = target
        self.parameters = parameters
    }

    public mutating func snap(to target: Double) {
        self.target = target
        value = target
        velocity = 0
    }

    /// Reduce Motion jumps straight to the target (the view only fades); otherwise the spring carries it there.
    public mutating func move(to target: Double, _ parameters: Parameters, reduceMotion: Bool) {
        if reduceMotion { snap(to: target) } else { retarget(target, parameters) }
    }

    public mutating func advance(by interval: Double) {
        guard interval > 0, !isSettled else { return }
        let stiffness = pow(2 * Double.pi / parameters.response, 2)
        let friction = 4 * Double.pi * parameters.damping / parameters.response
        // A stalled frame slows the motion down instead of making it jump.
        var remaining = min(interval, 1.0 / 15)
        while remaining > 0 {
            let dt = min(Self.step, remaining)
            let before = value - target
            velocity += (-stiffness * before - friction * velocity) * dt
            value += velocity * dt
            // Hard guards against any overshoot, also after a retarget against fast motion or fast double reversals:
            // the value stops on the target instead of passing it, and never leaves its bounds.
            if before != 0, (value - target).sign != before.sign {
                value = target
                velocity = 0
            }
            if !bounds.contains(value) {
                value = min(max(value, bounds.lowerBound), bounds.upperBound)
                velocity = 0
            }
            remaining -= dt
        }
        if abs(value - target) < tolerance, abs(velocity) < 50 * tolerance {
            value = target
            velocity = 0
        }
    }
}

/// Pure functions of the progress, shared by drawing, reversals and snapshots.
public enum IslandChoreography {
    /// Width leads height slightly: the shape first spreads, then drops.
    public static func widthProgress(_ p: CGFloat) -> CGFloat {
        let t = min(max(p / 0.8, 0), 1)
        return 1 - (1 - t) * (1 - t)
    }
    /// The floating silhouette fades from transparent to black and is done before the content starts.
    public static func backgroundAlpha(_ p: CGFloat) -> CGFloat { smoothstep(0, 0.55, p) }
    public static func contentAlpha(_ p: CGFloat) -> CGFloat { smoothstep(0.55, 0.95, p) }
    /// The content settles 8 pt downward into place while the panel opens.
    public static func contentDrop(_ p: CGFloat) -> CGFloat { 8 * (1 - smoothstep(0.3, 1, p)) }
    /// The wing's own line and mark give way first as the panel opens.
    public static func compactAlpha(_ p: CGFloat) -> CGFloat { 1 - smoothstep(0, 0.35, p) }

    public static func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
