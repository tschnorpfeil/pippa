import AppKit

/// Colors of the figure, per appearance.
struct MarkPalette: Equatable {
    var primary: [Double]
    var success: [Double]
    var destructive: [Double]

    static let light = MarkPalette(primary: rgb(0x005bcd), success: rgb(0x0d712c), destructive: rgb(0xc4001d))
    static let dark = MarkPalette(primary: hsl(212.4, 1.0, 0.749), success: hsl(141.8, 1.0, 0.424), destructive: hsl(355, 0.872, 0.794))

    static func forAppearance(_ appearance: NSAppearance?) -> MarkPalette {
        let dark = appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? .dark : .light
    }

    /// Menu bar at rest: single-color like a template symbol, color only on state change.
    func monochromeIdle(dark: Bool) -> MarkPalette {
        var p = self
        p.primary = dark ? [1, 1, 1] : [0, 0, 0]
        return p
    }

    static func rgb(_ hex: Int) -> [Double] {
        [Double((hex >> 16) & 0xff) / 255, Double((hex >> 8) & 0xff) / 255, Double(hex & 0xff) / 255]
    }
    static func hsl(_ h: Double, _ s: Double, _ l: Double) -> [Double] {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) = switch hp {
        case ..<1: (c, x, 0)
        case ..<2: (x, c, 0)
        case ..<3: (0, c, x)
        case ..<4: (0, x, c)
        case ..<5: (x, 0, c)
        default: (c, 0, x)
        }
        let m = l - c / 2
        return [r + m, g + m, b + m]
    }
}

/// State and drawing of a figure. Port of the PippaMark class (_setup, _paint).
final class MarkRenderer {
    struct Point { var x, y, angle, organic, cosine, envelope, end: Double }
    struct Vertex { var x, y, depth, width: Spring }
    struct Edge { var x, y, depth, width: Double }

    let size: Double
    let segments: Int
    private let geometry: [[Point]]
    private var orientations: [OrbitOrientation]
    private var vertices: [[Vertex]]
    private var color: [Spring]
    private var kick = Spring(value: 0)
    private(set) var elapsed = 0.0
    /// Clock for the quiet life at rest (wobble, breath, glow).
    private var idle = 0.0
    /// Seconds of quiet life left at rest. Pippa settles after a change instead of moving forever.
    /// once this runs out the draw loop stops, so a resting mark costs no CPU.
    private var idleLife = MarkRenderer.idleLifeSeconds
    static let idleLifeSeconds = 4.0
    /// The last part of the life fades breath and wobble back to the resting shape without a jump.
    static let idleFadeSeconds = 1.5
    /// Clock for the glow in the last step (rest: idle, otherwise elapsed).
    private var glowClock = 0.0
    private let options = WorkingMotion.tuned
    private var tubes: [(edges: [Edge], alpha: Double)] = []

    var state: MarkState { didSet { if state != oldValue { idleLife = Self.idleLifeSeconds } } }
    var palette: MarkPalette
    var reduced: Bool
    /// Glow only at display sizes above 32 pt.
    var glowAllowed = true
    /// Whether the resting state lives (wobbles, breathes). Off for the menu bar.
    var alive = true
    private(set) var moving = true

    init(size: Double, state: MarkState, palette: MarkPalette, reduced: Bool) {
        self.size = size
        self.state = state
        self.palette = palette
        self.reduced = reduced
        segments = size <= 32 ? 32 : 48
        let segs = segments
        geometry = (0..<3).map { strand in
            (0..<segs).map { point in
                let angle = Double(point) / Double(segs) * MarkConst.tau
                let organic = MarkConst.kreisWobble(angle, strand, 0)
                let cosine = cos(angle)
                let u = (cosine + 1) / 2
                return Point(x: organic * cosine, y: organic * sin(angle), angle: angle, organic: organic, cosine: cosine,
                             envelope: sin(.pi * u), end: pow(abs(u - 0.5) * 2, 3))
            }
        }
        orientations = Array(repeating: OrbitOrientation(), count: 3)
        vertices = geometry.enumerated().map { index, ring in
            ring.map { point in
                let radius = size * (MarkConst.kreisRadius - Double(index) * MarkConst.strangAbstand)
                return Vertex(x: Spring(value: size / 2 + point.x * radius), y: Spring(value: size / 2 + point.y * radius),
                              depth: Spring(value: 0), width: Spring(value: MarkConst.kreisStrich(size) * WorkingMotion.tuned.stroke / 2))
            }
        }
        color = palette.primary.map { Spring(value: $0) }
        step(seconds: 0, snap: true)
    }

    func pulse() {
        guard !reduced else { return }
        kick.velocity += 18
        idleLife = Self.idleLifeSeconds
    }

    /// One physics step (_paint without the drawing).
    func step(seconds: Double, snap: Bool = false) {
        let s = size
        let morph = options.morph
        let attenuation = exp(-morph * seconds)
        let current = state
        let working = current == .arbeitet
        let mouth = current == .offen || current == .fehler
        let snapping = snap || reduced
        if working && !reduced { elapsed += seconds * 1000 * options.speed }
        let living = current == .ruht && alive && !reduced
        if living && idleLife > 0 {
            idleLife = max(0, idleLife - seconds)
            idle += seconds * 1000
        }
        let fade = living ? min(1, idleLife / Self.idleFadeSeconds) : 0
        let breath = 1 + 0.025 * sin(idle / 9000 * MarkConst.tau) * fade
        glowClock = living ? idle : elapsed
        let targetInk = current == .fehler ? palette.destructive : current == .offen ? palette.success : palette.primary
        var moving = kick.advance(to: 0, seconds: seconds, reduced: snapping, attenuation: attenuation, frequency: morph)
        for i in 0..<3 {
            moving = color[i].advance(to: targetInk[i], seconds: seconds, reduced: snapping, attenuation: attenuation, frequency: morph) || moving
        }
        var newTubes: [(edges: [Edge], alpha: Double)] = []
        for strand in 0..<3 {
            let time = reduced ? MarkConst.turnMS * 0.35 : elapsed
            let targetPose = working ? Choreography.working.pose(time, strand) : Pose.idle
            let orientation = orientations[strand].advance(to: targetPose, seconds: seconds, snap: snapping, frequency: morph)
            let pose = orientation.pose
            moving = orientation.moving || moving
            let radius = s * (MarkConst.kreisRadius - Double(strand) * MarkConst.strangAbstand) * (1 + 0.04 * max(0, kick.value)) * breath
            var edges: [Edge] = []
            edges.reserveCapacity(segments)
            for (index, point) in geometry[strand].enumerated() {
                let live = fade > 0 ? 1 + (MarkConst.kreisWobble(point.angle, strand, idle) / point.organic - 1) * fade : 1
                let px = point.x * live, py = point.y * live
                let depth = mouth ? 0 : px * pose.zx + py * pose.zy
                let perspective = 1 + options.perspective * depth
                let st = Double(strand)
                let x = mouth ? s / 2 + s * MarkConst.kreisRadius * point.cosine
                    : s / 2 + (px * pose.xx + py * pose.xy) * radius * perspective
                let y: Double
                if mouth {
                    y = s / 2 + (current == .offen
                        ? (s * 0.1 + st * s * 0.016) * point.envelope - s * 0.03 * point.end
                        : -(s * 0.085 + st * s * 0.014) * point.envelope + s * 0.06 * point.end)
                } else {
                    y = s / 2 + (px * pose.yx + py * pose.yy) * radius * perspective
                }
                let width = (mouth ? max(1.5, s * 0.058) : MarkConst.kreisStrich(s) * MarkConst.depthWidth(depth, options.depth)) * options.stroke / 2
                var v = vertices[strand][index]
                moving = v.x.advance(to: x, seconds: seconds, reduced: snapping, attenuation: attenuation, frequency: morph) || moving
                moving = v.y.advance(to: y, seconds: seconds, reduced: snapping, attenuation: attenuation, frequency: morph) || moving
                moving = v.depth.advance(to: depth, seconds: seconds, reduced: snapping, attenuation: attenuation, frequency: morph) || moving
                moving = v.width.advance(to: width, seconds: seconds, reduced: snapping, attenuation: attenuation, frequency: morph) || moving
                vertices[strand][index] = v
                edges.append(Edge(x: v.x.value, y: v.y.value, depth: v.depth.value, width: v.width.value))
            }
            newTubes.append((edges, MarkConst.straenge[strand].alpha))
        }
        tubes = newTubes
        if current == .ruht && !moving { elapsed = 0 }
        self.moving = moving
    }

    /// Does the drawing loop keep running?
    var animates: Bool { state == .arbeitet || moving || (state == .ruht && alive && !reduced && idleLife > 0) }

    /// Draws into a context with y down, origin top left, unit = size.
    func draw(in ctx: CGContext) {
        let ink = CGColor(srgbRed: color[0].value, green: color[1].value, blue: color[2].value, alpha: 1)
        ctx.saveGState()
        ctx.setFillColor(ink)
        // First the back parts, then the front parts of each ring.
        for front in [false, true] {
            for tube in tubes {
                ctx.saveGState()
                ctx.setAlpha(tube.alpha)
                // Small marks stay sharp, without glow.
                let blur = (size <= 32 || !glowAllowed) ? 0 : MarkConst.kreisGlow(size, glowClock) * tube.alpha * options.glow
                if blur > 0 { ctx.setShadow(offset: .zero, blur: blur, color: ink) }
                let path = CGMutablePath()
                let edges = tube.edges
                for position in 0..<segments {
                    var from = edges[position]
                    var to = edges[(position + 1) % segments]
                    let a = front ? from.depth >= 0 : from.depth < 0
                    let b = front ? to.depth >= 0 : to.depth < 0
                    if !a && !b { continue }
                    var capEnd = false
                    if a != b {
                        let w = from.depth / (from.depth - to.depth)
                        let crossing = Edge(x: from.x + (to.x - from.x) * w, y: from.y + (to.y - from.y) * w, depth: 0,
                                            width: from.width + (to.width - from.width) * w)
                        if a { to = crossing; capEnd = true } else { from = crossing }
                    }
                    let dx = to.x - from.x, dy = to.y - from.y
                    let length = max(0.0001, hypot(dx, dy))
                    let nx = -dy / length, ny = dx / length
                    path.move(to: CGPoint(x: from.x - nx * from.width, y: from.y - ny * from.width))
                    path.addLine(to: CGPoint(x: to.x - nx * to.width, y: to.y - ny * to.width))
                    path.addLine(to: CGPoint(x: to.x + nx * to.width, y: to.y + ny * to.width))
                    path.addLine(to: CGPoint(x: from.x + nx * from.width, y: from.y + ny * from.width))
                    path.closeSubpath()
                    path.move(to: CGPoint(x: from.x + from.width, y: from.y))
                    path.addArc(center: CGPoint(x: from.x, y: from.y), radius: from.width, startAngle: 0, endAngle: MarkConst.tau, clockwise: false)
                    path.closeSubpath()
                    if capEnd {
                        path.move(to: CGPoint(x: to.x + to.width, y: to.y))
                        path.addArc(center: CGPoint(x: to.x, y: to.y), radius: to.width, startAngle: 0, endAngle: MarkConst.tau, clockwise: false)
                        path.closeSubpath()
                    }
                }
                ctx.addPath(path)
                ctx.fillPath(using: .winding)
                ctx.restoreGState()
            }
        }
        ctx.restoreGState()
    }
}
