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
        if monochromeIdle && renderer.state == .ruht { palette = palette.monochromeIdle(dark: dark) }
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
        if !renderer.animates { stop() }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
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
