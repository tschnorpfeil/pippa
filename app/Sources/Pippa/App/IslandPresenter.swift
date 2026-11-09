import AppKit
import PippaCore
import QuartzCore
import SwiftUI

/// Clear, borderless, non-activating window at menu bar level on every Space. It becomes key only while the island is
/// open (`allowsKey`), so the wing, the resting notch and a hover or drop never take focus from another app.
final class IslandPanel: NSPanel {
    var allowsKey = false

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
        title = "Pippa Island"
        setAccessibilityLabel("Pippa")
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The wing or capsule: a click opens or closes the island, files dropped on it go to the next question.
final class IslandHostingView<Content: View>: DropHostingView<Content> {
    var onClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// Draws the black silhouette and reveals the two contents inside it: the compact line, and the open panel.
final class IslandView: NSView {
    let compact: IslandHostingView<IslandCompactView>
    let panel: DropHostingView<IslandPanelView>
    private let clip = NSView()
    private var silhouette: IslandSilhouette?
    private var fillAlpha: CGFloat = 1
    /// Window origin in global coordinates; the geometry is global.
    private var origin = CGPoint.zero

    init(island: Island, onHeight: @escaping (CGFloat) -> Void) {
        compact = IslandHostingView(rootView: IslandCompactView(island: island))
        panel = DropHostingView(rootView: IslandPanelView(island: island, chat: .shared, setup: .shared, approvals: .shared, onHeight: onHeight))
        super.init(frame: .zero)
        wantsLayer = true
        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        clip.autoresizesSubviews = false
        // Only `show` sizes the contents; their own sizing would fight the animation.
        compact.sizingOptions = []
        panel.sizingOptions = []
        clip.addSubview(compact)
        clip.addSubview(panel)
        compact.feedback = .island
        panel.feedback = .island
        compact.setAccessibilityLabel("Pippa")
        addSubview(clip)
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }

    /// Lays out one moment: the compact shape `compactShape` (rest or wing, maybe mid-change) grown toward the open
    /// panel by `open`. `compactTarget` is where the compact content sits; `compactAlpha` how much of it shows.
    func show(_ placement: IslandPlacement, compactShape: CGRect, compactTarget: CGRect, compactAlpha: CGFloat,
              open: CGFloat, openRect: CGRect, origin: CGPoint) {
        self.origin = origin
        let shape = IslandGeometry.silhouette(placement, from: compactShape, to: openRect, progress: open)
        silhouette = shape
        var housingWidth: CGFloat?
        switch placement {
        case .notch(let housing, _):
            // Grows out of the black housing: it is black from the start.
            fillAlpha = 1
            housingWidth = housing.width
            clip.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        case .menuBar:
            fillAlpha = max(min(1, compactShape.height / IslandGeometry.capsuleHeight), IslandChoreography.backgroundAlpha(open))
            clip.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }
        if compact.rootView.housingWidth != housingWidth {
            compact.rootView = IslandCompactView(island: compact.rootView.island, housingWidth: housingWidth)
        }
        needsDisplay = true
        let body = shape.rect.offsetBy(dx: -origin.x, dy: -origin.y)
        clip.frame = body
        clip.layer?.cornerRadius = min(shape.radius, body.width / 2, body.height / 2)
        clip.isHidden = body.width < 1 || body.height < 1
        compact.frame = compactTarget.offsetBy(dx: -shape.rect.minX, dy: -shape.rect.minY)
        compact.alphaValue = compactAlpha * IslandChoreography.compactAlpha(open)
        // At the notch the panel's content starts below the housing.
        let top = openRect.maxY - housingHeight(placement)
        panel.frame = NSRect(x: openRect.minX - shape.rect.minX, y: openRect.minY - shape.rect.minY + IslandChoreography.contentDrop(open),
                             width: openRect.width, height: max(0, top - openRect.minY))
        panel.alphaValue = IslandChoreography.contentAlpha(open)
        panel.isHidden = open < 0.01
    }

    private func housingHeight(_ placement: IslandPlacement) -> CGFloat {
        if case .notch(let housing, _) = placement { return housing.height }
        return 0
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let silhouette, let context = NSGraphicsContext.current?.cgContext else { return }
        context.addPath(silhouette.path(offset: origin))
        context.setFillColor(NSColor.black.withAlphaComponent(fillAlpha).cgColor)
        context.fillPath()
    }

    func shapeContains(_ point: NSPoint) -> Bool {
        silhouette?.contains(CGPoint(x: point.x + origin.x, y: point.y + origin.y)) ?? false
    }
}

/// Moves the island between rest, compact and open: two critically damped springs on the display link, one for the
/// compact shape (rest ↔ wing, a longer or shorter line) and one for opening. Reversals keep value and velocity. Under
/// Reduce Motion the springs jump and the window only fades.
@MainActor
final class IslandPresenter: NSObject {
    let panel = IslandPanel()
    private(set) var view: IslandView!
    private(set) var placement: IslandPlacement?
    private(set) var isPresented = false
    private var compactFrom = CGRect.zero, compactTo = CGRect.zero
    private var alphaFrom: CGFloat = 0, alphaTo: CGFloat = 0
    private var wing = IslandSpring(value: 1)
    private var opening = IslandSpring()
    private var contentHeight: CGFloat = 180
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var fadeToken = 0
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    /// The menu bar symbol: clicks there belong to its own toggle and never count as outside clicks.
    var sourceRect: () -> NSRect = { .zero }
    var onClosed: (() -> Void)?
    /// The close has finished: the island may move to another display now.
    var onIdle: (() -> Void)?
    var isIdle: Bool { !isPresented && opening.isSettled && opening.value == 0 }
    /// Escape while open: true when it was used (a question declined), otherwise the island closes.
    var onEscape: (() -> Bool)?
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(island: Island) {
        super.init()
        view = IslandView(island: island) { [weak self] height in self?.contentHeightChanged(height) }
        panel.contentView = view
        view.compact.onClick = { [weak island] in island?.compactClicked() }
        view.compact.onDrop = { [weak island] in island?.attach($0) }
        view.panel.onDrop = { [weak island] in island?.attach($0) }
    }

    /// A new display or menu bar position: everything jumps to its resting place there.
    func place(_ placement: IslandPlacement?, compactWidth: CGFloat?) {
        guard placement != self.placement else { return }
        self.placement = placement
        guard let placement else {
            close(animated: false)
            panel.orderOut(nil)
            return
        }
        compactTo = target(placement, compactWidth)
        compactFrom = compactTo
        alphaTo = compactWidth == nil ? 0 : 1
        alphaFrom = alphaTo
        wing.snap(to: 1)
        if !isPresented { opening.snap(to: 0) }
        render()
    }

    private func target(_ placement: IslandPlacement, _ width: CGFloat?) -> CGRect {
        width.map { IslandGeometry.compact(placement, width: $0) } ?? IslandGeometry.rest(placement)
    }

    /// The wing appears, changes width or goes back to rest; nil is rest.
    func setCompact(width: CGFloat?) {
        guard let placement else { return }
        let target = target(placement, width)
        let alpha: CGFloat = width == nil ? 0 : 1
        guard target != compactTo || alpha != alphaTo else { return }
        compactFrom = currentCompact
        alphaFrom = currentCompactAlpha
        compactTo = target
        alphaTo = alpha
        wing.snap(to: 0)
        wing.move(to: 1, IslandSpring.opening, reduceMotion: reduceMotion())
        if wing.isSettled { render() } else { startLink() }
    }

    private var currentCompact: CGRect {
        guard let placement else { return compactTo }
        return IslandGeometry.silhouette(placement, from: compactFrom, to: compactTo, progress: wing.value).rect
    }

    private var currentCompactAlpha: CGFloat {
        let w = CGFloat(wing.value)
        let t = alphaTo > alphaFrom ? IslandChoreography.smoothstep(0.5, 1, w) : IslandChoreography.smoothstep(0, 0.4, w)
        return alphaFrom + (alphaTo - alphaFrom) * t
    }

    /// Opens the island; `key` makes it key for typing (the person asked for it). A question that opens it by itself
    /// does not take the keyboard from the app in front.
    func open(key: Bool) {
        guard placement != nil else { return }
        panel.allowsKey = true
        if key { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
        guard !isPresented else { return }
        isPresented = true
        installMonitors()
        if reduceMotion() {
            opening.snap(to: 1)
            render()
            fade(from: 0)
        } else {
            opening.retarget(1, IslandSpring.opening)
            startLink()
        }
    }

    func close(animated: Bool = true) {
        guard isPresented else { return }
        isPresented = false
        removeMonitors()
        panel.allowsKey = false
        // Hand the keyboard back: a window that stays on screen keeps key focus until it is ordered out once.
        if panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        onClosed?()
        if !animated {
            opening.snap(to: 0)
            render()
            onIdle?()
        } else if reduceMotion() {
            fade(from: 1, to: 0) { [weak self] in
                self?.opening.snap(to: 0)
                self?.render()
                self?.panel.alphaValue = 1
                self?.onIdle?()
            }
        } else {
            opening.retarget(0, IslandSpring.closing)
            startLink()
        }
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard height > 0, abs(height - contentHeight) > 0.5 else { return }
        contentHeight = height
        render()
    }

    // MARK: Drawing

    private func render() {
        guard let placement else { return }
        if wing.isSettled { compactFrom = compactTo; alphaFrom = alphaTo }
        let openRect = IslandGeometry.open(placement, contentHeight: ceil(contentHeight))
        let showsOpen = opening.value > 0 || opening.target > 0
        let frame = IslandGeometry.windowFrame(placement, covering: [compactFrom, compactTo] + (showsOpen ? [openRect] : []))
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
            view.frame = NSRect(origin: .zero, size: frame.size)
        }
        view.show(placement, compactShape: currentCompact, compactTarget: compactTo, compactAlpha: currentCompactAlpha,
                  open: CGFloat(opening.value), openRect: openRect, origin: frame.origin)
        // At the notch the resting island hides in the housing and takes a click there; under the menu bar it leaves.
        let visible = placement.isNotch || alphaTo > 0 || alphaFrom > 0 || showsOpen
        if visible, !panel.isVisible { panel.orderFrontRegardless() }
        if !visible, panel.isVisible { panel.orderOut(nil) }
    }

    private func startLink() {
        fadeToken += 1
        if link == nil {
            let link = view.displayLink(target: self, selector: #selector(tick(_:)))
            link.isPaused = true
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        guard let link, link.isPaused else { return }
        lastTick = CACurrentMediaTime()
        link.isPaused = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        // Step by presented frame time; callback time jitters from frame to frame.
        let now = link.targetTimestamp
        wing.advance(by: now - lastTick)
        opening.advance(by: now - lastTick)
        lastTick = now
        render()
        guard wing.isSettled && opening.isSettled else { return }
        link.isPaused = true
        if isIdle { onIdle?() }
    }

    /// Reduce Motion: the window fades instead of the shape moving.
    private func fade(from start: CGFloat, to end: CGFloat = 1, completion: (@MainActor @Sendable () -> Void)? = nil) {
        fadeToken += 1
        let token = fadeToken
        panel.alphaValue = start
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = end
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadeToken == token else { return }
                completion?()
            }
        }
    }

    // MARK: Events while open

    private func installMonitors() {
        removeMonitors()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        let local = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown)) { [weak self] event in
            let escape = event.type == .keyDown && event.keyCode == 53
            if event.type == .keyDown && !escape { return event }
            let inPanel = event.window === self?.panel
            let location = event.locationInWindow
            MainActor.assumeIsolated {
                guard let self else { return }
                if escape {
                    if self.onEscape?() != true { self.close() }
                } else if inPanel {
                    if !self.view.shapeContains(location) { self.close() }
                } else if !self.sourceRect().contains(NSEvent.mouseLocation) {
                    self.close()
                }
            }
            return escape ? nil : event
        }
        // Clicks in other apps are always outside; only the menu bar symbol keeps them.
        let global = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.sourceRect().contains(NSEvent.mouseLocation) else { return }
                self.close()
            }
        }
        monitors = [local, global].compactMap { $0 }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
    }
}
