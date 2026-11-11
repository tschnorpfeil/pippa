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
    /// Where the panel's lower edge is while its height springs: its last rows ride on it.
    let edge = IslandEdge()
    private let clip = NSView()
    private var silhouette: IslandSilhouette?
    private var fillAlpha: CGFloat = 1
    /// Window origin in global coordinates; the geometry is global.
    private var origin = CGPoint.zero
    /// The open panel just became visible: only now can its question field take the keyboard.
    var onPanelShown: (() -> Void)?

    init(island: Island, onHeight: @escaping (CGFloat) -> Void) {
        compact = IslandHostingView(rootView: IslandCompactView(island: island))
        panel = DropHostingView(rootView: IslandPanelView(island: island, chat: .shared, setup: .shared, approvals: .shared,
                                                          edge: edge, onHeight: onHeight))
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
    /// panel `openRect` by `open`. `compactTarget` is where the compact content sits; `compactAlpha` how much of it
    /// shows. `contentRect` holds the panel's content laid out at its own height (by default the open panel); its last
    /// rows follow the lower edge of `openRect` while the height springs (`IslandEdge`).
    func show(_ placement: IslandPlacement, compactShape: CGRect, compactTarget: CGRect, compactAlpha: CGFloat,
              open: CGFloat, openRect: CGRect, contentRect: CGRect? = nil, lag: CGFloat = 0, origin: CGPoint) {
        self.origin = origin
        let shape = IslandGeometry.silhouette(placement, from: compactShape, to: openRect, progress: open)
        silhouette = shape
        var housingWidth: CGFloat?
        var row: IslandPanelView.MenuBarRow?
        switch placement {
        case .notch(let housing, _):
            // The row left of the housing, from the panel's left edge: everything right of it is the camera or beyond.
            row = IslandPanelView.MenuBarRow(height: housing.height, besideHousing: max(0, openRect.maxX - housing.minX))
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
        if panel.rootView.menuBarRow != row {
            var view = panel.rootView
            view.menuBarRow = row
            panel.rootView = view
        }
        needsDisplay = true
        let body = shape.rect.offsetBy(dx: -origin.x, dy: -origin.y)
        clip.frame = body
        clip.layer?.cornerRadius = min(shape.radius, body.width / 2, body.height / 2)
        clip.isHidden = body.width < 1 || body.height < 1
        compact.frame = compactTarget.offsetBy(dx: -shape.rect.minX, dy: -shape.rect.minY)
        compact.alphaValue = compactAlpha * IslandChoreography.compactAlpha(open)
        // At the notch the panel's top row lies beside the housing: Pippa's mark and line stay in the menu bar.
        let content = contentRect ?? openRect
        panel.frame = NSRect(x: content.minX - shape.rect.minX, y: content.minY - shape.rect.minY + IslandChoreography.contentDrop(open),
                             width: content.width, height: content.height)
        if edge.lag != lag { edge.lag = lag }
        panel.alphaValue = IslandChoreography.contentAlpha(open)
        let hidden = open < 0.01
        let shown = panel.isHidden && !hidden
        panel.isHidden = hidden
        if shown { onPanelShown?() }
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
    /// The open panel's content height, on its own spring: when what it shows grows or shrinks, the lower edge
    /// follows smoothly (0.32 s growing, 0.24 s shrinking), whatever the opening is doing.
    private var height = IslandSpring(value: 180, bounds: 0...10_000, tolerance: 0.25)
    /// The tallest the panel has been since its height last settled: the window and the content keep that size until
    /// then, so neither is resized on every frame.
    private var heightReach: CGFloat = 180
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval = 0
    private var fadeToken = 0
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    /// Watches a press in another app until the button comes up (`pressedOutside`).
    private var pressWatch: Timer?
    /// The menu bar symbol: clicks there belong to its own toggle and never count as outside clicks.
    var sourceRect: () -> NSRect = { .zero }
    var onClosed: (() -> Void)?
    /// The close has finished: the island may move to another display now.
    var onIdle: (() -> Void)?
    var isIdle: Bool { !isPresented && opening.isSettled && opening.value == 0 && height.isSettled }
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
        view.onPanelShown = { [weak island] in island?.panelShown() }
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
        alphaTo = Self.compactAlpha(placement, compactWidth)
        alphaFrom = alphaTo
        wing.snap(to: 1)
        if !isPresented { opening.snap(to: 0) }
        render()
    }

    /// At the notch the mark stays visible at rest; under the menu bar the capsule leaves.
    private static func compactAlpha(_ placement: IslandPlacement, _ width: CGFloat?) -> CGFloat {
        width != nil || placement.isNotch ? 1 : 0
    }

    private func target(_ placement: IslandPlacement, _ width: CGFloat?) -> CGRect {
        width.map { IslandGeometry.compact(placement, width: $0) } ?? IslandGeometry.rest(placement)
    }

    /// The wing appears, changes width or goes back to rest; nil is rest.
    func setCompact(width: CGFloat?) {
        guard let placement else { return }
        let target = target(placement, width)
        let alpha = Self.compactAlpha(placement, width)
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
        guard let placement else { return }
        panel.allowsKey = true
        if key { panel.makeKeyAndOrderFront(nil) } else { panel.orderFrontRegardless() }
        keepBehindNotchTool(placement)
        guard !isPresented else { return }
        isPresented = true
        installMonitors()
        if reduceMotion() {
            opening.snap(to: 1)
            render()
            fade(from: 0)
        } else {
            cancelFade()
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
            // Still open while it closes: another notch tool stays in front.
            if let placement { keepBehindNotchTool(placement) }
        }
        onClosed?()
        if !animated {
            opening.snap(to: 0)
            height.snap(to: height.target)
            render()
            onIdle?()
        } else if reduceMotion() {
            fade(from: 1, to: 0) { [weak self] in
                self?.opening.snap(to: 0)
                if let self { self.height.snap(to: self.height.target) }
                self?.render()
                self?.panel.alphaValue = 1
                self?.onIdle?()
            }
        } else {
            cancelFade()
            opening.retarget(0, IslandSpring.closing)
            startLink()
        }
    }

    /// Another notch tool right of the housing (like tinyStats) stays in front of the open panel: the panel goes right
    /// behind its window, at its level if that is lower. Without one the panel is back at menu bar level.
    private func keepBehindNotchTool(_ placement: IslandPlacement) {
        let windows = Self.otherWindows()
        guard let index = IslandGeometry.notchTool(placement, windows: windows.map(\.frame)) else {
            panel.level = .statusBar
            return
        }
        let tool = windows[index]
        panel.level = NSWindow.Level(rawValue: min(NSWindow.Level.statusBar.rawValue, tool.layer))
        panel.order(.below, relativeTo: tool.number)
    }

    /// Other apps' on-screen windows at menu bar level or above: their number, level and frame in global AppKit
    /// coordinates. These need no permission (window titles would).
    private static func otherWindows() -> [(number: Int, layer: Int, frame: CGRect)] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let top = NSScreen.screens.first?.frame.maxY else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            guard (info[kCGWindowOwnerPID as String] as? Int32) != me, layer >= Int(CGWindowLevelForKey(.mainMenuWindow)),
                  let number = info[kCGWindowNumber as String] as? Int,
                  !["Window Server", "Dock"].contains(info[kCGWindowOwnerName as String] as? String ?? ""),
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
            // Window lists count from the top left of the main display, AppKit from its bottom left.
            return (number, layer, CGRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height))
        }
    }

    private func contentHeightChanged(_ newHeight: CGFloat) {
        let target = Double(newHeight)
        guard newHeight > 0, abs(target - height.target) > 0.5 else { return }
        heightReach = max(heightReach, CGFloat(height.value), newHeight)
        // Closed nothing shows it; under Reduce Motion sizes jump.
        let shown = isPresented || opening.value > 0
        if !shown || reduceMotion() {
            height.snap(to: target)
        } else {
            height.retarget(target, target > height.value ? IslandSpring.opening : IslandSpring.closing)
        }
        if height.isSettled { render() } else { startLink() }
    }

    // MARK: Drawing

    private func render() {
        guard let placement else { return }
        if wing.isSettled { compactFrom = compactTo; alphaFrom = alphaTo }
        if height.isSettled { heightReach = CGFloat(height.target) }
        let openRect = IslandGeometry.open(placement, contentHeight: CGFloat(height.value))
        let reach = IslandGeometry.open(placement, contentHeight: ceil(heightReach))
        let showsOpen = opening.value > 0 || opening.target > 0
        let frame = IslandGeometry.windowFrame(placement, covering: [compactFrom, compactTo] + (showsOpen ? [reach] : []))
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
            view.frame = NSRect(origin: .zero, size: frame.size)
        }
        view.show(placement, compactShape: currentCompact, compactTarget: compactTo, compactAlpha: currentCompactAlpha,
                  open: CGFloat(opening.value), openRect: openRect, contentRect: reach,
                  lag: CGFloat(height.value - height.target), origin: frame.origin)
        // At the notch the resting island hides in the housing and takes a click there; under the menu bar it leaves.
        let visible = placement.isNotch || alphaTo > 0 || alphaFrom > 0 || showsOpen
        if visible, !panel.isVisible { panel.orderFrontRegardless() }
        if !visible, panel.isVisible { panel.orderOut(nil) }
    }

    private func startLink() {
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
        height.advance(by: now - lastTick)
        // Closed, nothing shows the height: it does not keep the island from going idle.
        if !isPresented, opening.isSettled, opening.value == 0 { height.snap(to: height.target) }
        lastTick = now
        render()
        guard wing.isSettled && opening.isSettled && height.isSettled else { return }
        link.isPaused = true
        if isIdle { onIdle?() }
    }

    /// A spring takes over from a fade that is still running (Reduce Motion switched off mid-way).
    private func cancelFade() {
        fadeToken += 1
        panel.alphaValue = 1
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
            // Escape is the island's only when typed there; in the chat window it stays the chat's.
            let escape = event.type == .keyDown && event.keyCode == 53 && event.window === self?.panel
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
        let global = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, !self.sourceRect().contains(NSEvent.mouseLocation) else { return }
                if event.type == .leftMouseDown { self.pressedOutside() } else { self.close() }
            }
        }
        monitors = [local, global].compactMap { $0 }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
    }

    /// A press in another app may be the start of a drag onto the island ("drop a file here"), so the island waits for
    /// the button to come up: a plain click closes it then, and so does a drag that ends anywhere else. A drag that
    /// ends on the island leaves it open with the files.
    private func pressedOutside() {
        let drags = NSPasteboard(name: .drag).changeCount
        pressWatch?.invalidate()
        pressWatch = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self.pressWatch?.invalidate()
                self.pressWatch = nil
                let dragged = NSPasteboard(name: .drag).changeCount != drags
                let onIsland = self.view.shapeContains(self.panel.convertPoint(fromScreen: NSEvent.mouseLocation))
                if !(dragged && onIsland) { self.close() }
            }
        }
    }

    private func removeMonitors() {
        pressWatch?.invalidate()
        pressWatch = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
    }
}
