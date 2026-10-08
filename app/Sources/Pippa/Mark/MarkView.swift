import AppKit
import QuartzCore
import SwiftUI

/// One state for the whole app: all figures follow it.
@MainActor
final class MarkHub {
    static let shared = MarkHub()
    private(set) var state: MarkState = .ruht
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

    func set(_ state: MarkState) {
        guard state != self.state else { return }
        self.state = state
        for v in views.allObjects { v.setState(state) }
    }

    func pulse() { for v in views.allObjects { v.pulse() } }
}

/// Draws a figure at up to 30 frames per second. At rest it lives on only briefly after a change
/// (`MarkRenderer.idleLifeSeconds`); after that, and otherwise, the loop stops once the shape has settled.
final class MarkNSView: NSView {
    private var renderer: MarkRenderer
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var pending: Double = 0
    private var stepNeeded = false
    /// Menu bar: single-color at rest.
    var monochromeIdle = false { didSet { updatePalette() } }
    private var occlusionObserver: NSObjectProtocol?

    init(size: CGFloat, monochromeIdle: Bool = false) {
        let hub = MarkHub.shared
        renderer = MarkRenderer(size: Double(size), state: hub.state, palette: .light, reduced: hub.reduced)
        self.monochromeIdle = monochromeIdle
        renderer.alive = !monochromeIdle
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        hub.register(self)
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

    func pulse() {
        renderer.pulse()
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

/// SwiftUI shell for a figure in panels and messages.
struct PippaMarkView: NSViewRepresentable {
    var size: CGFloat
    func makeNSView(context: Context) -> MarkNSView { MarkNSView(size: size) }
    func updateNSView(_ nsView: MarkNSView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarkNSView, context: Context) -> CGSize? {
        CGSize(width: size, height: size)
    }
}
