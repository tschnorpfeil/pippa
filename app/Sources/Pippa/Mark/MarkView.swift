import AppKit
import QuartzCore
import SwiftUI

/// Pippa's living mark: the three rings at rest, the orbit while she works, the colours when she needs you or
/// something failed. Drawn at up to 30 frames per second, only while visible and moving (MarkRenderer).
final class MarkNSView: NSView {
    private var renderer: MarkRenderer
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var occlusionObserver: NSObjectProtocol?
    /// Menu bar: black or white at rest like a template symbol, still; colour only when the state changes.
    private let monochromeIdle: Bool
    /// Words of the answer are coming in: draw her handwriting (`Scribble`) instead of the rings.
    private(set) var isWriting = false

    init(size: CGFloat, monochromeIdle: Bool = false) {
        renderer = MarkRenderer(size: Double(size), state: .ruht, palette: .light, reduced: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        renderer.alive = !monochromeIdle
        self.monochromeIdle = monochromeIdle
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
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
        if monochromeIdle && renderer.state == .ruht && !isWriting { palette = palette.monochromeIdle(dark: dark) }
        if palette != renderer.palette {
            renderer.palette = palette
            wake()
        }
    }

    func setState(_ state: MarkState) {
        guard renderer.state != state else { return }
        renderer.state = state
        updatePalette()
        wake()
    }

    func setWriting(_ writing: Bool) {
        guard isWriting != writing else { return }
        isWriting = writing
        updatePalette()
        wake()
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

    private var isShowing: Bool {
        guard let window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor
    }

    private var animates: Bool { (isWriting && !renderer.reduced) || renderer.animates }

    func wake() {
        if renderer.reduced || !isShowing {
            renderer.step(seconds: 0, snap: true)
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
        needsDisplay = true
        if !animates { stop() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if isWriting {
            let size = bounds.width
            let scale = size / 2 * 1.1, line = max(1.3, size * 0.08)
            let time = renderer.reduced ? 2.0 : Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000)
            let ink = renderer.palette.primary
            let color = CGColor(srgbRed: ink[0], green: ink[1], blue: ink[2], alpha: 1)
            let alphas = [1.0, 0.6, 0.42]
            ctx.saveGState()
            ctx.setStrokeColor(color)
            ctx.setLineWidth(line)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for k in 0..<3 {
                ctx.setAlpha(alphas[k])
                let points = Scribble.stroke(k, at: time)
                guard let first = points.first else { continue }
                ctx.beginPath()
                ctx.move(to: CGPoint(x: size / 2 + first.x * scale, y: size / 2 + first.y * scale))
                for point in points.dropFirst() {
                    ctx.addLine(to: CGPoint(x: size / 2 + point.x * scale, y: size / 2 + point.y * scale))
                }
                ctx.strokePath()
            }
            ctx.restoreGState()
            return
        }
        let scale = bounds.width / CGFloat(renderer.size)
        renderer.glowAllowed = bounds.width > 32
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        renderer.draw(in: ctx)
        ctx.restoreGState()
    }
}

/// The mark in SwiftUI, following `state`.
struct PippaMark: NSViewRepresentable {
    var size: CGFloat
    var state: MarkState
    var hovered = false
    /// Black or white at rest and still, like a symbol (an empty list); colour only when the state changes.
    var monochrome = false

    func makeNSView(context: Context) -> MarkNSView { MarkNSView(size: size, monochromeIdle: monochrome) }
    func updateNSView(_ view: MarkNSView, context: Context) {
        view.setState(state)
        view.setHovered(hovered)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkNSView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}
