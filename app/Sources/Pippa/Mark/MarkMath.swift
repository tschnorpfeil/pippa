import Foundation

// Faithful port of the original pippaMark.js: constants, springs, orbit choreography.
// Pure math, no AppKit; drawing happens in MarkRenderer.

enum MarkState: String, Sendable, CaseIterable {
    case ruht, arbeitet, offen, fehler

    var spoken: String {
        switch self {
        case .ruht: T("ready", table: "App")
        case .arbeitet: T("working", table: "App")
        case .offen: T("needs you", table: "App")
        case .fehler: T("something didn’t work", table: "App")
        }
    }
}

enum MarkConst {
    static let tau = Double.pi * 2
    static let frameSeconds = 1.0 / 30

    // Outline of the resting circles
    static let idleAmp = 1.35
    static let kreisRadius = 0.34
    static let strangAbstand = 0.016
    static let straenge: [(amp: Double, alpha: Double)] = [(1.0, 1.0), (0.6, 0.6), (0.3, 0.42)]
    static let strandOffset = 1.2

    static func kreisWobble(_ angle: Double, _ strand: Int, _ time: Double, _ circleWeight: Double = 1) -> Double {
        let s = Double(strand)
        return 1 + circleWeight * idleAmp *
            (0.035 * sin(3 * angle + time / 1400 + s * strandOffset) +
             0.026 * sin(2 * angle - time / 2100 + s * strandOffset * 0.7))
    }
    static func kreisStrich(_ size: Double) -> Double { max(1.4, size * 0.052) }
    static func kreisGlow(_ size: Double, _ time: Double) -> Double {
        let oscillation = (sin(time / 4500) + 1) / 2
        return 0.5 * size * 0.16 * (0.5 + 0.5 * oscillation)
    }

    // Bewegung
    static let turnMS = 2600.0
    static let trailMS = 240.0
    static func fixedAxis(_ degrees: Double, _ depth: Double) -> Vec3 {
        let angle = degrees * .pi / 180
        let length = hypot(1, depth)
        return Vec3(x: cos(angle) / length, y: sin(angle) / length, z: depth / length)
    }
    static let orbitAxes: [Vec3] = [68, -28, 119, 24, 87, -49].map { fixedAxis($0, 0) }
    static let orbitRingOffsets: [Double] = [0, trailMS, 2 * trailMS]

    static func depthWidth(_ depth: Double, _ strength: Double = 0.28) -> Double {
        1 + strength * max(-1, min(1, depth))
    }
}

struct Vec3: Sendable { var x, y, z: Double }

/// Upper part of a rotation matrix: the first two columns (x and y) with the z row.
struct Pose: Sendable {
    var xx, xy, yx, yy, zx, zy: Double
    static let idle = Pose(xx: 1, xy: 0, yx: 0, yy: 1, zx: 0, zy: 0)

    /// Upper 2x2 part of the Rodrigues matrix: rotation about a fixed axis.
    static func orbit(_ a: Vec3, _ angle: Double) -> Pose {
        let c = cos(angle), s = sin(angle), k = 1 - c
        return Pose(
            xx: c + a.x * a.x * k, xy: a.x * a.y * k - a.z * s,
            yx: a.x * a.y * k + a.z * s, yy: c + a.y * a.y * k,
            zx: a.z * a.x * k - a.y * s, zy: a.z * a.y * k + a.x * s)
    }

    /// The missing third column is the cross product of the first two.
    static func compose(_ l: Pose, _ r: Pose) -> Pose {
        let xz = l.yx * l.zy - l.zx * l.yy
        let yz = l.zx * l.xy - l.xx * l.zy
        let zz = l.xx * l.yy - l.yx * l.xy
        return Pose(
            xx: l.xx * r.xx + l.xy * r.yx + xz * r.zx, xy: l.xx * r.xy + l.xy * r.yy + xz * r.zy,
            yx: l.yx * r.xx + l.yy * r.yx + yz * r.zx, yy: l.yx * r.xy + l.yy * r.yy + yz * r.zy,
            zx: l.zx * r.xx + l.zy * r.yx + zz * r.zx, zy: l.zx * r.xy + l.zy * r.yy + zz * r.zy)
    }

    var quaternion: [Double] {
        let xz = yx * zy - zx * yy, yz = zx * xy - xx * zy, zz = xx * yy - yx * xy
        let trace = xx + yy + zz
        if trace > 0 {
            let s = (trace + 1).squareRoot() * 2
            return [(zy - yz) / s, (xz - zx) / s, (yx - xy) / s, s / 4]
        }
        if xx > yy && xx > zz {
            let s = (1 + xx - yy - zz).squareRoot() * 2
            return [s / 4, (xy + yx) / s, (xz + zx) / s, (zy - yz) / s]
        }
        if yy > zz {
            let s = (1 + yy - xx - zz).squareRoot() * 2
            return [(xy + yx) / s, s / 4, (yz + zy) / s, (xz - zx) / s]
        }
        let s = (1 + zz - xx - yy).squareRoot() * 2
        return [(xz + zx) / s, (yz + zy) / s, s / 4, (yx - xy) / s]
    }
}

/// Exact critically damped spring: retargeting keeps position and velocity.
struct Spring: Sendable {
    var value: Double
    var velocity: Double = 0

    @discardableResult
    mutating func advance(to target: Double, seconds: Double, reduced: Bool = false,
                          attenuation: Double? = nil, frequency: Double = 18) -> Bool {
        if reduced { value = target; velocity = 0; return false }
        if seconds == 0 { return abs(value - target) > 0.005 || abs(velocity) > 0.02 }
        let att = attenuation ?? exp(-frequency * seconds)
        let distance = value - target
        let impulse = (velocity + frequency * distance) * seconds
        value = target + (distance + impulse) * att
        velocity = (velocity - frequency * impulse) * att
        let moving = abs(value - target) > 0.005 || abs(velocity) > 0.02
        if !moving { value = target; velocity = 0 }
        return moving
    }
}

/// Damped orientation with hemisphere continuity; normalization preserves the ring's volume.
struct OrbitOrientation: Sendable {
    var ch: [Spring] = [Spring(value: 0), Spring(value: 0), Spring(value: 0), Spring(value: 1)]

    mutating func advance(to target: Pose, seconds: Double, snap: Bool, frequency: Double = 18) -> (moving: Bool, pose: Pose) {
        let q = target.quaternion
        var dot = 0.0
        for i in 0..<4 { dot += ch[i].value * q[i] }
        let sign: Double = dot < 0 ? -1 : 1
        var moving = false
        let attenuation = exp(-frequency * seconds)
        for i in 0..<4 {
            moving = ch[i].advance(to: q[i] * sign, seconds: seconds, reduced: snap, attenuation: attenuation, frequency: frequency) || moving
        }
        var length = 0.0
        for c in ch { length += c.value * c.value }
        length = length.squareRoot()
        if length > 0 {
            for i in 0..<4 { ch[i].value /= length; ch[i].velocity /= length }
        }
        var radial = 0.0
        for c in ch { radial += c.value * c.velocity }
        for i in 0..<4 { ch[i].velocity -= radial * ch[i].value }
        let x = ch[0].value, y = ch[1].value, z = ch[2].value, w = ch[3].value
        return (moving, Pose(
            xx: 1 - 2 * (y * y + z * z), xy: 2 * (x * y - z * w),
            yx: 2 * (x * y + z * w), yy: 1 - 2 * (x * x + z * z),
            zx: 2 * (x * z - y * w), zy: 2 * (y * z + x * w)))
    }
}

/// Abgestimmte Arbeitsbewegung (WORKING_MOTION in pippaMark.js).
struct WorkingMotion: Sendable {
    var speed = 1.6, overlap = 1000.0, trail = 440.0, response = 1.0, wander = 0.0, easing = 0.8
    var axisSpread = 8.0, axisRotation = 0.0, tempoVariation = 1.0, depth = 0.2, perspective = 0.025
    // Selected "Kräftiger Ring" prototype: stronger contour, same choreography.
    var stroke = 1.55, morph = 18.0, glow = 0.3
    static let tuned = WorkingMotion()
}

/// createTunedChoreography: pose per ring at the elapsed working time.
struct Choreography: Sendable {
    let s: WorkingMotion
    let duration: Double
    let axes: [[Vec3]]
    let prefixes: [[Pose]]
    let cycleAngles: [Double]

    init(_ settings: WorkingMotion) {
        s = settings
        duration = MarkConst.turnMS + settings.overlap
        let n = MarkConst.orbitAxes.count
        var axes: [[Vec3]] = []
        for strand in 0..<MarkConst.orbitRingOffsets.count {
            let offset = (settings.axisRotation + Double(strand - 1) * settings.axisSpread) * .pi / 180
            axes.append(MarkConst.orbitAxes.map { a in
                Vec3(x: a.x * cos(offset) - a.y * sin(offset), y: a.x * sin(offset) + a.y * cos(offset), z: 0)
            })
        }
        self.axes = axes
        prefixes = axes.map { sequence in
            var bases = [Pose.idle]
            for axis in sequence { bases.append(Pose.compose(Pose.orbit(axis, .pi), bases[bases.count - 1])) }
            return bases
        }
        cycleAngles = prefixes.map { atan2($0[n].yx, $0[n].xx) }
    }

    private func clock(_ t: Double) -> Double {
        t + s.tempoVariation * (180 * sin(t * MarkConst.tau / 15600) + 75 * sin(t * MarkConst.tau / 10400))
    }

    func pose(_ elapsed: Double, _ strand: Int) -> Pose {
        let n = MarkConst.orbitAxes.count
        let turnMS = MarkConst.turnMS
        let latestClock = clock(elapsed)
        let latestTurn = Int(floor(latestClock / turnMS))
        var vx = 0.0, vy = 0.0
        var turn = max(0, latestTurn - 1)
        while turn <= latestTurn {
            let p = (latestClock - Double(turn) * turnMS) / duration
            if p >= 0 && p <= 1 {
                let speed = (1 - s.easing) + s.easing * sin(.pi * p)
                vx += speed * MarkConst.orbitAxes[turn % n].x
                vy += speed * MarkConst.orbitAxes[turn % n].y
            }
            turn += 1
        }
        let factor = 1 + s.response * (-0.25 + 0.5 * min(1, hypot(vx, vy))) + s.wander * sin(elapsed / 2700)
        let time = clock(max(0, elapsed - Double(strand) * s.trail * factor))
        let latest = Int(floor(time / turnMS))
        let completed = max(0, Int(floor((time - s.overlap) / turnMS)))
        let step = completed % n
        let cycleAngle = Double(completed / n) * cycleAngles[strand]
        var pose = Pose.compose(prefixes[strand][step],
                                Pose(xx: cos(cycleAngle), xy: -sin(cycleAngle), yx: sin(cycleAngle), yy: cos(cycleAngle), zx: 0, zy: 0))
        var t = completed
        while t <= latest {
            let p = max(0, min(1, (time - Double(t) * turnMS) / duration))
            let angle = Double.pi * ((1 - s.easing) * p + s.easing * (0.5 - 0.5 * cos(.pi * p)))
            pose = Pose.compose(Pose.orbit(axes[strand][t % n], angle), pose)
            t += 1
        }
        return pose
    }

    static let working = Choreography(.tuned)
}
