import AppKit
import PippaCore
import QuartzCore
import SwiftUI

/// One state for the whole app: all figures follow it.
@MainActor
final class MarkHub {
    static let shared = MarkHub()
    private(set) var state: MarkState = .ruht
    /// What Pippa does in a conversation, as the chat's working sign shows it (`nil`: the mark itself).
    private(set) var shape: WorkShape?
    private let views = NSHashTable<MarkNSView>.weakObjects()
    private(set) var reduced = MarkHub.systemReducesMotion
    /// System setting; native fixtures can simulate it with `PIPPA_REDUCE_MOTION=1` (debug only, never changes the setting).
    static var systemReducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || DevEnvironment.value("PIPPA_REDUCE_MOTION") == "1"
    }

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                let hub = MarkHub.shared
                hub.reduced = MarkHub.systemReducesMotion
                for v in hub.views.allObjects { v.reducedChanged(hub.reduced) }
            }
        }
    }

    func register(_ view: MarkNSView) { views.add(view) }

    func set(_ state: MarkState, shape: WorkShape? = nil) {
        if shape != self.shape {
            self.shape = shape
            for v in views.allObjects { v.setShape(shape) }
        }
        guard state != self.state else { return }
        self.state = state
        for v in views.allObjects { v.setState(state) }
    }

    func pulse() { for v in views.allObjects { v.pulse() } }
}

/// Draws a figure at up to 30 frames per second. At rest it lives on only briefly after a change
/// (`MarkRenderer.idleLifeSeconds`); after that, and otherwise, the loop stops once the shape has settled.
/// With `workShapes` (the pill) the rings take the same shapes as the chat's working sign while a conversation
/// runs: the handwriting while the answer streams, the lines while reading, and so on. The mark fades into the
/// shape, which morphs out of the turning rings; thinking stays the mark's own orbit.
final class MarkNSView: NSView {
    private var renderer: MarkRenderer
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var pending: Double = 0
    private var stepNeeded = false
    /// Menu bar: single-color at rest.
    var monochromeIdle = false { didSet { updatePalette() } }
    private var occlusionObserver: NSObjectProtocol?
    private let workShapes: Bool
    private var shape: WorkShape?
    /// The shape drawn while fading in or out (stays after `shape` is gone, until faded).
    private var drawnShape: WorkShape?
    private let shapeMorph = WorkShapeMorph()
    private var shapeClock = 0.0
    /// 0: the mark, 1: the work shape.
    private var shapeMix = 0.0
    /// How fast mark and shape cross-fade (per second).
    private static let shapeFade = 9.0

    init(size: CGFloat, monochromeIdle: Bool = false, workShapes: Bool = false) {
        let hub = MarkHub.shared
        renderer = MarkRenderer(size: Double(size), state: hub.state, palette: .light, reduced: hub.reduced)
        self.workShapes = workShapes
        self.monochromeIdle = monochromeIdle
        renderer.alive = !monochromeIdle
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        hub.register(self)
        if workShapes, let shape = hub.shape {
            self.shape = shape; drawnShape = shape; shapeMix = 1
        }
        setAccessibilityElement(false)
        updatePalette()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updatePalette()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o); occlusionObserver = nil }
        guard let window else { stop(); return }
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.wake() }
        }
        updatePalette()
        wake()
    }

    private func updatePalette() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var palette: MarkPalette = dark ? .dark : .light
        if monochromeIdle { palette = palette.monochromeIdle(dark: dark) }
        if palette != renderer.palette {
            renderer.palette = palette
            wake()
        }
    }

    func setState(_ state: MarkState) {
        guard renderer.state != state else { return }
        renderer.state = state
        wake()
    }

    func setShape(_ next: WorkShape?) {
        guard workShapes, next != shape else { return }
        if let next {
            // Out of the mark: the handwriting (or lines, or swarm) grows from the turning rings.
            if drawnShape == nil || shapeMix < 0.01 {
                shapeMorph.seed(WorkShapeGeometry.frame(.think, at: shapeClock, still: renderer.reduced))
            }
            drawnShape = next
        }
        shape = next
        wake()
    }

    private var shapeSettled: Bool { shapeMix == (shape == nil ? 0 : 1) }

    private func advanceShape(_ seconds: Double, snap: Bool) {
        let target = shape == nil ? 0.0 : 1.0
        if snap { shapeMix = target } else {
            shapeMix += (target - shapeMix) * (1 - exp(-seconds * Self.shapeFade))
            if abs(target - shapeMix) < 0.005 { shapeMix = target }
        }
        if shapeMix == 0 { drawnShape = nil }
        shapeClock += seconds
    }

    func pulse() {
        renderer.pulse()
        wake()
    }

    func setHovered(_ on: Bool) {
        guard renderer.hovered != on else { return }
        renderer.hovered = on
        wake()
    }

    func reducedChanged(_ reduced: Bool) {
        renderer.reduced = reduced
        wake()
    }

    private var isShowing: Bool {
        guard let window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor
    }

    func wake() {
        if renderer.reduced || !isShowing {
            renderer.step(seconds: 0, snap: true)
            advanceShape(0, snap: true)
            needsDisplay = true
            stop()
            return
        }
        if link == nil {
            let l = displayLink(target: self, selector: #selector(tick(_:)))
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
            l.add(to: .main, forMode: .common)
            link = l
            lastTimestamp = nil
        }
    }

    private func stop() {
        link?.invalidate()
        link = nil
        lastTimestamp = nil
    }

    @objc private func tick(_ l: CADisplayLink) {
        guard isShowing else { stop(); return }
        let now = l.timestamp
        let delta = lastTimestamp.map { now - $0 } ?? 0
        lastTimestamp = now
        renderer.step(seconds: min(delta, 0.1))
        advanceShape(min(delta, 0.1), snap: false)
        needsDisplay = true
        if !renderer.animates && shape == nil && shapeSettled { stop() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = bounds.width / CGFloat(renderer.size)
        renderer.glowAllowed = bounds.width > 32
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        if shapeMix < 1 {
            ctx.saveGState()
            ctx.setAlpha(1 - shapeMix)
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            renderer.draw(in: ctx)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
        if let drawnShape, shapeMix > 0 { drawShape(drawnShape, in: ctx) }
        ctx.restoreGState()
    }

    /// The chat's working sign (WorkShapeView) at the mark's size, stroke and ink.
    private func drawShape(_ shape: WorkShape, in ctx: CGContext) {
        let size = renderer.size, half = size / 2
        let target = WorkShapeGeometry.frame(shape, at: shapeClock.truncatingRemainder(dividingBy: 3600), still: renderer.reduced)
        let strokes = shapeMorph.step(toward: target, at: shapeClock, follow: 9, snap: renderer.reduced)
        let primary = renderer.palette.primary
        let accent = CGColor(srgbRed: primary[0], green: primary[1], blue: primary[2], alpha: 1)
        let need = NSColor(Theme.needDot).cgColor
        let glow = renderer.glowAllowed ? MarkConst.kreisGlow(size, shapeClock * 1000) * WorkingMotion.tuned.glow : 0
        ctx.saveGState()
        ctx.setAlpha(shapeMix)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setLineWidth(MarkConst.kreisStrich(size) * WorkingMotion.tuned.stroke)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for stroke in strokes where stroke.alpha > 0.01 {
            let ink = stroke.ink == .need ? need : accent
            let path = CGMutablePath()
            for (i, p) in stroke.points.enumerated() {
                let point = CGPoint(x: half + p.x * half, y: half + p.y * half)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            ctx.saveGState()
            if glow > 0 { ctx.setShadow(offset: .zero, blur: glow * stroke.alpha, color: ink) }
            ctx.setStrokeColor(ink.copy(alpha: stroke.alpha) ?? ink)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }
}

/// SwiftUI shell for a figure in panels and messages.
struct PippaMarkView: NSViewRepresentable {
    var size: CGFloat
    func makeNSView(context: Context) -> MarkNSView { MarkNSView(size: size) }
    func updateNSView(_ nsView: MarkNSView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkNSView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}
