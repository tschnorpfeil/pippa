import AppKit
import Combine
import PippaCore
import QuartzCore
import SwiftUI


@MainActor
final class ShellController: NSObject {
    let model: AppModel
    let panel: ShellPanel
    private let stage = StageView()
    private let shadow = ShadowView(frame: .zero)
    private let clip = ClipView()
    private let inner = InnerView()
    private let effect = NSVisualEffectView()
    private let tint = TintView()
    private let hosting: ShellHostingView<ShellHostRoot>
    let mark = MarkNSView(size: 36)
    private let interaction: PillInteractionView
    /// Items lying on Pippa: cards behind the pill (at rest only).
    private let stack = TrayStackView()
    /// While Pippa works: the light around the pill and the thought bubble above it (PillAura).
    private let auraState: PillAuraState
    private let aura: PillAuraHost
    let reveal = RevealState()
    private var cancellables: Set<AnyCancellable> = []
    private var layoutScheduled = false

    // Geometry in stage coordinates (origin at the panel's bottom left).
    private(set) var shellRect: CGRect = .zero      // target frame of the shape
    private var unionRect: CGRect = .zero           // frame of the interior
    private var radius: CGFloat = ShellTokens.pillHeight / 2
    private var markRect: CGRect = .zero
    private var lastModeKey = ""
    private var workspace: WorkspacePlacement?
    private var generation = 0
    private var revealGeneration = 0
    /// Time of the last trigger (click/shortcut), for measuring up to the first frame.
    var triggerTime: CFTimeInterval?
    private(set) var lastLatency: CFTimeInterval?

    var hitRect: CGRect { stageVisible ? shellRect : .zero }
    private(set) var stageVisible = false
    /// The shell is deforming right now (between trigger and the spring settling).
    private(set) var morphing = false

    var isDraggingPill = false
    /// Pippa is dragging an item out itself: the pill must not become a drop target then.
    var takingOut = false
    /// Frame of the menu bar icon, anchor while the pill is hidden.
    var statusAnchor: (() -> NSRect?)?
    var dragPoll: Timer?
    var dragBaseline = NSPasteboard(name: .drag).changeCount
    var dragAnnounced = false
    var monitors: [Any] = []
    /// State of the drag pasteboard at the last press outside (click or start of a drag?).
    var outsideDragBaseline = NSPasteboard(name: .drag).changeCount

    /// Slow motion (developer check only): springs and fades run slower.
    var slowdown: Double = 1 {
        didSet {
            stage.layer?.speed = Float(1 / slowdown)
            reveal.slowdown = slowdown
        }
    }

    init(model: AppModel) {
        self.model = model
        panel = ShellPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        hosting = ShellHostingView(rootView: ShellHostRoot(model: model, reveal: reveal))
        interaction = PillInteractionView()
        let auraState = PillAuraState()
        self.auraState = auraState
        aura = PillAuraHost(rootView: PillAura(state: auraState))
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false                // the stage draws the shadow itself, never square
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true
        panel.onCancel = { [weak model] in model?.escape() }
        panel.setAccessibilityLabel("Pippa")

        stage.controller = self
        stage.wantsLayer = true
        stage.layer?.backgroundColor = .clear
        panel.contentView = stage

        stage.addSubview(shadow)

        clip.controller = self
        clip.wantsLayer = true
        if let l = clip.layer {
            l.masksToBounds = true
            l.cornerCurve = .continuous
            l.borderWidth = ShellTokens.edgeWidth
        }
        clip.registerForDraggedTypes(DropReader.types)
        stage.addSubview(clip)

        // Below the shape, above the shadow: the pill covers the lower part of the cards.
        stack.controller = self
        stage.addSubview(stack, positioned: .below, relativeTo: clip)

        // Directly behind the shape: the glow only shows around the pill's edge, the bubble above it.
        aura.sizingOptions = []
        aura.wantsLayer = true
        stage.addSubview(aura, positioned: .below, relativeTo: clip)

        inner.wantsLayer = true
        clip.addSubview(inner)

        effect.material = ShellTokens.material
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.autoresizingMask = [.width, .height]
        inner.addSubview(effect)
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        inner.addSubview(tint)

        hosting.sizingOptions = []
        hosting.controller = self
        hosting.registerForDraggedTypes(DropReader.types)
        hosting.wantsLayer = true
        inner.addSubview(hosting)

        stage.addSubview(mark)

        interaction.controller = self
        interaction.registerForDraggedTypes(DropReader.types)
        stage.addSubview(interaction)

        model.objectWillChange
            .sink { [weak self] _ in self?.scheduleLayout() }
            .store(in: &cancellables)

        TextScaleStore.shared.$factor.dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    // New text size: widths change too, so forget the old placement and default width.
                    self.workspace = nil
                    if self.customWorkspace == nil {
                        self.model.conversationSize = CGSize(width: Theme.conversationWidth, height: self.model.conversationSize.height)
                    }
                    self.layout(animated: false, force: true)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout(animated: false, force: true) }
        }

        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.appearanceChanged() }
            }
        }

        installMonitors()
        // Scripted QA snapshots must not react to drags meant for the installed Pippa.
        if DevSnapshot.directory == nil { startDragPoll() }
    }

    private var appearanceObservation: NSKeyValueObservation?

    /// Light/dark live: recolor the edge (colors, material and mark follow on their own).
    private func appearanceChanged() {
        let dark = stage.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.layer?.borderColor = (dark ? ShellTokens.edgeDark : ShellTokens.edgeLight).cgColor
        CATransaction.commit()
        shadow.setAppearance(dark: dark)
        tint.needsDisplay = true
        pillCache = nil
        layout(animated: false, force: true)
    }

    // MARK: Public

    func showInitially() {
        layout(animated: false, force: true)
        // Pre-warm the first measurement of the large surfaces so the first click doesn't wait.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            MainActor.assumeIsolated { self?.prewarm() }
        }
    }

    private func prewarm() {
        let size = CGSize(width: 2000, height: 4000)
        _ = NSHostingController(rootView: ConversationWorkspace(model: model, chat: model.conversations, mode: .input, measuring: true)).sizeThatFits(in: size)
        _ = NSHostingController(rootView: WorkingContent(model: model, title: "…", writes: nil)).sizeThatFits(in: size)
        _ = NSHostingController(rootView: MessageContent(model: model, title: "…", message: "…")).sizeThatFits(in: size)
    }

    /// Before the switch: leave the old content standing as a frozen mode (SwiftUI only redraws afterwards).
    func modeWillChange() {
        let t0 = CACurrentMediaTime()
        defer { snapshotTime = CACurrentMediaTime() - t0 }
        measureTime = 0
        guard stageVisible, !MarkHub.shared.reduced, hosting.bounds.width > 1 else { return }
        // Old content stays briefly and fades out (no snapshot needed, costs nothing).
        if reveal.frozen == nil {
            reveal.frozen = model.mode
            frozenRect = hosting.frame.offsetBy(dx: unionRect.minX, dy: unionRect.minY)
        }
    }

    /// Frame of the old content left standing (stage).
    private var frozenRect: CGRect = .zero

    /// Switch: start immediately with the last measured size of this surface (first frame < 16 ms),
    /// re-measure the exact size after the first frame and, if needed, retarget from the running motion.
    func modeChanged() {
        if model.mode.shape == .pill || model.mode.shape == .target { pillCache = nil }
        preferCache = true
        cacheHit = false
        layout(animated: true)
        preferCache = false
        guard cacheHit else { return }
        cacheHit = false
        let motion = lastMotion
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.forcedMotion = motion
                self.layout(animated: true)
                self.forcedMotion = nil
            }
        }
    }

    private var measureCache: [String: (size: CGSize, slot: CGRect?)] = [:]
    private var preferCache = false
    private var cacheHit = false
    private var lastMotion: Motion = .expand
    private var forcedMotion: Motion?

    func pillVisibilityChanged() {
        workspace = nil
        layout(animated: true, force: true)
    }

    func pulseMark() { mark.pulse() }

    #if DEBUG
    func previewFocusedAttachment(at index: Int) { stack.previewFocusedAttachment(at: index) }
    func previewRemoveFocusedAttachment() { stack.previewRemoveFocusedAttachment() }
    var previewFocusedAttachmentFrame: CGRect? { stack.previewFocusedCardFrame }
    #endif

    private func scheduleLayout() {
        guard !layoutScheduled else { return }
        layoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.layoutScheduled = false
                self?.layout(animated: true)
                // The drop target can change without the shape moving.
                self?.updateStack(animated: true)
                self?.updateAura()
            }
        }
    }

    // MARK: Geometry (screen coordinates)

    /// Screen under the middle of a rect, else the one it overlaps most, else the pill's screen.
    /// Never `NSScreen.main`: that follows the key window, i.e. the last click.
    private func screen(containing rect: NSRect) -> NSScreen {
        let screens = NSScreen.screens
        if let i = PillPlacement.displayIndex(containing: rect, in: screens.map(Self.display)) { return screens[i] }
        return pillScreen
    }

    private static func display(_ s: NSScreen) -> PillPlacement.Display {
        let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return PillPlacement.Display(id: id, name: s.localizedName, frame: s.frame, visibleFrame: s.visibleFrame)
    }

    /// The pill's screen comes only from its saved position. A missing display falls back to the
    /// primary one (the pill returns when the display does); mouse and key window never count.
    var pillScreen: NSScreen {
        let screens = NSScreen.screens
        let i = PillPlacement.displayIndex(for: savedPill(width: pillCache?.width ?? 90), in: screens.map(Self.display)) ?? 0
        return screens[i]
    }

    /// Screen of the visible shell (pill or opened workspace); toasts and cards open here.
    var shellScreen: NSScreen { screen(containing: shellScreenRect) }

    private var pillPlacement: PillPlacement.Saved?

    /// Saved pill position. Written by a drag; the very first default (on `NSScreen.main`, the
    /// display the person works on at first launch) and older absolute positions are saved once.
    private func savedPill(width: CGFloat) -> PillPlacement.Saved {
        if let p = pillPlacement { return p }
        let d = UserDefaults.standard
        let displays = NSScreen.screens.map(Self.display)
        var placement: PillPlacement.Saved?
        if d.object(forKey: "pill.display") != nil {
            placement = PillPlacement.Saved(displayID: UInt32(truncatingIfNeeded: d.integer(forKey: "pill.display")),
                                            displayName: d.string(forKey: "pill.displayName") ?? "",
                                            alignRight: d.bool(forKey: "pill.alignRight"), alignTop: d.bool(forKey: "pill.alignTop"),
                                            dx: d.double(forKey: "pill.dx"), dy: d.double(forKey: "pill.dy"))
        } else if d.object(forKey: "pill.y") != nil {
            placement = PillPlacement.migrate(left: d.double(forKey: "pill.left"), right: d.double(forKey: "pill.right"),
                                              y: d.double(forKey: "pill.y"), height: ShellTokens.pillHeight, in: displays)
            if let placement { storePill(placement) }
        }
        if placement == nil {
            let main = NSScreen.main ?? NSScreen.screens[0]
            placement = PillPlacement.initial(width: width, height: ShellTokens.pillHeight, on: Self.display(main))
            storePill(placement!)
        }
        pillPlacement = placement
        return placement!
    }

    private func storePill(_ p: PillPlacement.Saved) {
        pillPlacement = p
        let d = UserDefaults.standard
        d.set(Int(p.displayID), forKey: "pill.display")
        d.set(p.displayName, forKey: "pill.displayName")
        d.set(p.alignRight, forKey: "pill.alignRight")
        d.set(p.alignTop, forKey: "pill.alignTop")
        d.set(p.dx, forKey: "pill.dx")
        d.set(p.dy, forKey: "pill.dy")
    }

    /// Saved position of the pill, for a given width. Never discarded: a Dock or a smaller
    /// display only clamps it for showing, the saved state stays until the next drag.
    func pillFrame(width: CGFloat) -> NSRect {
        let saved = savedPill(width: width)
        let screens = NSScreen.screens
        let displays = screens.map(Self.display)
        let i = PillPlacement.displayIndex(for: saved, in: displays) ?? 0
        return PillPlacement.frame(for: saved, width: width, height: ShellTokens.pillHeight, on: displays[i], inset: ShellTokens.screenInset)
    }

    func savePill(_ frame: NSRect) {
        workspace = nil
        customWorkspace = nil
        storePill(PillPlacement.save(frame, on: Self.display(screen(containing: frame))))
    }

    private func clamp(_ r: NSRect, to vis: NSRect) -> NSRect {
        PillPlacement.clamp(r, to: vis, inset: ShellTokens.screenInset)
    }

    /// Dragging the pill: edge magnet and minimum distance.
    func magnetized(_ r: NSRect) -> NSRect {
        let vis = screen(containing: r).visibleFrame
        var r = clamp(r, to: vis)
        let i = ShellTokens.screenInset, m = ShellTokens.edgeMagnet
        if r.minX - vis.minX < m { r.origin.x = vis.minX + i }
        if vis.maxX - r.maxX < m { r.origin.x = vis.maxX - r.width - i }
        if r.minY - vis.minY < m { r.origin.y = vis.minY + i }
        if vis.maxY - r.maxY < m { r.origin.y = vis.maxY - r.height - i }
        return r
    }

    /// Developer measurement: time to measure and freeze the old content at the last switch.
    private(set) var measureTime: CFTimeInterval = 0
    /// Natural height of the last measured shape (without height cap), for the developer capture.
    private(set) var lastMeasuredHeight: CGFloat = 0
    private(set) var snapshotTime: CFTimeInterval = 0

    /// Size of the content and the mark's slot (top left, y down) for the current shape.
    private func measure(width: CGFloat?, fixed: CGSize? = nil) -> (size: CGSize, slot: CGRect?) {
        let t0 = CACurrentMediaTime()
        defer { measureTime += CACurrentMediaTime() - t0 }
        let key = "\(model.mode.key)|\(width ?? 0)|\(fixed.map { "\($0)" } ?? "")"
        // Always measure pill and drop target fresh (label changes, greeting, light/dark).
        // The attachment row changes both height and the mark's vertical slot. Measure
        // the compact line before opening so it never starts from a stale below-field layout.
        let cacheable = !["line", "resume"].contains(model.mode.key) && [.input, .panel, .sheet].contains(model.mode.shape)
        if preferCache, cacheable, let c = measureCache[key] {
            cacheHit = true
            return c
        }
        if preferCache, cacheable {
            // Never measured: start immediately with an estimate, measure exactly after the first frame.
            let guess: CGSize? = switch model.mode.shape {
            case .input: CGSize(width: Theme.inputWidth, height: 100)
            case .panel: CGSize(width: Theme.panelWidth, height: 260)
            case .sheet: CGSize(width: width ?? Theme.sheetWidth, height: 560)
            default: nil
            }
            if let guess {
                cacheHit = true
                return (guess, nil)
            }
        }
        // Fresh pass: a reused controller returns stale sizes after switches.
        let box = MeasureBox()
        let hc = NSHostingController(rootView: MeasureRoot(model: model, fixed: fixed, box: box))
        let size = fixed ?? hc.sizeThatFits(in: CGSize(width: width ?? 2000, height: 4000))
        hc.view.frame = CGRect(origin: .zero, size: size)
        hc.view.layoutSubtreeIfNeeded()
        let slot = box.value
        let result = (size: size, slot: slot.isNull || slot.width < 1 ? nil : slot)
        measureCache[key] = result
        return result
    }

    private struct Target {
        var frame: NSRect          // screen
        var radius: CGFloat
        var mark: NSRect           // relative to the shape, top left, y down
        var hidden: Bool           // hidden pill: shrinks into the menu bar icon
    }

    private var pillCache: (key: String, width: CGFloat, slot: CGRect?)?

    private func pillMeasure() -> (width: CGFloat, slot: CGRect?) {
        // The living pill grows with its words (PillStatus); the width is measured once per label and tone.
        let status = model.pillStatus
        let key = "\(status.label)|\(status.tone.rawValue)|\(status.hand)|\(status.progress != nil)|\(model.parked != nil)"
        if let c = pillCache, c.key == key { return (c.width, c.slot) }
        let m = measure(width: nil)
        let w = ceil(m.size.width)
        pillCache = (key, w, m.slot)
        return (w, m.slot)
    }

    private func target() -> Target {
        let shape = model.mode.shape
        let pillW: (width: CGFloat, slot: CGRect?) = shape == .pill ? pillMeasure() : (pillCache.map { ($0.width, $0.slot) } ?? (90, nil))
        let pill = pillFrame(width: pillW.width)
        let menuAnchor = model.pillVisible ? nil : statusAnchor?()
        let anchor = menuAnchor ?? pill
        // Expanded states open on the pill's screen, wherever the mouse or the key window is.
        let vis = (menuAnchor.map { screen(containing: $0) } ?? pillScreen).visibleFrame

        switch shape {
        case .pill:
            if let m = menuAnchor {
                let f = NSRect(x: m.midX - 12, y: vis.maxY - 4, width: 24, height: 4)
                return Target(frame: f, radius: 2, mark: NSRect(x: 0, y: -10, width: 24, height: 24), hidden: true)
            }
            let defaultSlotY = (ShellTokens.pillHeight - 28) / 2
            let slot = pillW.slot ?? NSRect(x: 10, y: defaultSlotY, width: 28, height: 28)
            return Target(frame: pill, radius: ShellTokens.radius(.pill, height: pill.height), mark: slot, hidden: false)
        case .target:
            // The pill itself becomes the drop target: same corner, grown around its vertical center.
            let m = measure(width: nil)
            let w = ceil(m.size.width), h = ceil(m.size.height)
            let alignRight = anchor.midX > vis.midX
            let f = clamp(NSRect(x: alignRight ? anchor.maxX - w : anchor.minX, y: anchor.midY - h / 2, width: w, height: h), to: vis)
            let slot = m.slot ?? NSRect(x: 10, y: (h - 28) / 2, width: 28, height: 28)
            return Target(frame: f, radius: ShellTokens.radius(.target, height: h), mark: slot, hidden: false)
        case .input, .panel, .sheet:
            // All steps share the same reading start. No centering of
            // tables, no direction change of the input field, no drifting on progress.
            let inset = max(ShellTokens.screenInset, 20)
            if let custom = customWorkspace, DevSnapshot.directory == nil {
                // Moved or resized: stay there, on the screen of this frame.
                let customVis = screen(containing: custom).visibleFrame
                if workspace == nil || workspace?.visibleFrame != customVis {
                    workspace = WorkspacePlacement(frame: custom, visibleFrame: customVis, minimumSize: ShellTokens.workspaceMin, inset: inset)
                }
            } else if workspace == nil || workspace?.visibleFrame != vis {
                workspace = WorkspacePlacement(anchor: anchor, visibleFrame: vis,
                                               maximumSize: DevSnapshot.workspaceSize, inset: inset)
            }
            let place = workspace!
            if ["line", "resume"].contains(model.mode.key) {
                let width = min(Theme.inputWidth, place.bounds.width)
                if model.compactInputWidth != width { model.compactInputWidth = width }
            }
            if model.mode.isConversation {
                let requested = customWorkspace?.size ?? model.conversationSize
                let size = CGSize(width: min(requested.width, place.bounds.width),
                                  height: min(requested.height, place.bounds.height))
                if model.conversationSize != size { model.conversationSize = size }
                let frame = place.frame(for: size)
                return Target(frame: frame, radius: ShellTokens.radius(.panel, height: frame.height),
                              mark: NSRect(x: 20, y: 16, width: 32, height: 32), hidden: false)
            }
            let m = measure(width: shape == .sheet ? place.bounds.width : nil)
            lastMeasuredHeight = m.size.height
            // Taller than the space (small screen): the content then scrolls from the top (OnboardingContent),
            // the mark stays in the measured slot, which sits at the same spot unscrolled.
            let f = place.frame(for: m.size)
            let slot = m.slot ?? NSRect(x: 20, y: 16, width: 32, height: 32)
            return Target(frame: f, radius: ShellTokens.radius(shape, height: f.height), mark: slot, hidden: false)
        }
    }

    // MARK: Stage

    /// Screen → stage
    private func toStage(_ r: NSRect) -> CGRect { r.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY) }

    /// Frame of the mark in stage coordinates from the top-left slot in the shape.
    private func markFrame(_ slot: NSRect, in shell: CGRect) -> CGRect {
        CGRect(x: shell.minX + slot.minX, y: shell.maxY - slot.minY - slot.height, width: slot.width, height: slot.height)
    }

    /// What is currently visible (mid-motion: the presentation values).
    private func presentedShell() -> (rect: CGRect, radius: CGFloat) {
        guard let l = clip.layer else { return (shellRect, radius) }
        let p = l.presentation() ?? l
        let b = p.bounds
        let origin = CGPoint(x: p.position.x - p.anchorPoint.x * b.width, y: p.position.y - p.anchorPoint.y * b.height)
        return (CGRect(origin: origin, size: b.size), p.cornerRadius)
    }

    private func presentedMark() -> CGRect {
        guard let l = mark.layer else { return markRect }
        let p = l.presentation() ?? l
        let k = p.transform.m11
        let size = p.bounds.width * k
        let origin = CGPoint(x: p.position.x - p.anchorPoint.x * size, y: p.position.y - p.anchorPoint.y * size)
        return CGRect(origin: origin, size: CGSize(width: size, height: size))
    }

    private func shapePath(_ r: CGRect, _ radius: CGFloat) -> CGPath {
        let rr = max(0.5, min(radius, r.width / 2 - 0.01, r.height / 2 - 0.01))
        return CGPath(roundedRect: r, cornerWidth: rr, cornerHeight: rr, transform: nil)
    }

    private func cutoutPath(_ r: CGRect, _ radius: CGFloat) -> CGPath {
        let p = CGMutablePath()
        p.addRect(shadow.bounds.insetBy(dx: -200, dy: -200))
        // 1 pt below the edge so a light seam never appears between shadow and glass.
        p.addPath(shapePath(r.insetBy(dx: 1, dy: 1), max(0.5, radius - 1)))
        return p
    }

    private enum Motion { case expand, collapse, resize }

    private func spring(_ m: Motion) -> ShellTokens.Spring {
        switch m {
        case .expand: ShellTokens.expand
        case .collapse: ShellTokens.collapse
        case .resize: ShellTokens.resize
        }
    }

    /// When the spring visibly rests (within 0.25 % of the distance, i.e. < 1 px at 400 px).
    static func settleTime(_ s: ShellTokens.Spring) -> Double {
        var x = 0.0, v = 0.0, t = 0.0, settled: Double?
        let dt = 0.0005
        while t < 1.5 {
            let a = (-Double(s.stiffness) * (x - 1) - Double(s.damping) * v) / Double(s.mass)
            v += a * dt; x += v * dt; t += dt
            if abs(x - 1) < 0.0025 && abs(v) < 0.05 { if settled == nil { settled = t } } else { settled = nil }
        }
        return settled ?? 0.5
    }

    /// Time at which the spring has covered a fraction of the distance.
    static func time(toReach fraction: Double, _ s: ShellTokens.Spring) -> Double {
        var x = 0.0, v = 0.0, t = 0.0
        let dt = 0.0005
        while x < fraction && t < 2 {
            let a = (-Double(s.stiffness) * (x - 1) - Double(s.damping) * v) / Double(s.mass)
            v += a * dt
            x += v * dt
            t += dt
        }
        return t
    }

    /// Model position and frame of the layer if the view had this frame.
    private func layerGeometry(of view: NSView, frame: CGRect) -> (position: CGPoint, bounds: CGRect) {
        view.frame = frame
        return (view.layer?.position ?? .zero, view.layer?.bounds ?? .zero)
    }

    func layout(animated: Bool, force: Bool = false) {
        guard !isDraggingPill else { return }
        if model.mode.shape == .pill { workspace = nil; customWorkspace = nil }
        let t = target()
        // Conversation cards replace content inside one workspace. They are not
        // separate shell openings and must not restart its fade/spring sequence.
        let modeKey = model.mode.isConversation ? "conversation" : model.mode.key
        let withinConversation = modeKey == "conversation" && lastModeKey == "conversation"
        let attachmentHandoff = modeKey == "conversation" && lastModeKey == "line"
        let modeChanged = modeKey != lastModeKey
        let anchorScreen = screen(containing: t.frame)

        let wantVisible = !t.hidden || model.isExpanded

        // The stage covers the shell's screen; it only changes when the shell changes screens.
        let stageMoves = panel.frame != anchorScreen.frame
        if stageMoves { panel.setFrame(anchorScreen.frame, display: false) }
        let to = toStage(t.frame)
        let toMark = markFrame(t.mark, in: to)
        if !force && !modeChanged && !stageMoves && to == shellRect && t.radius == radius && toMark == markRect
            && stageVisible == wantVisible { return }

        let reduced = MarkHub.shared.reduced
        let firstShow = !stageVisible && wantVisible
        let canAnimate = animated && (stageVisible || firstShow) && !stageMoves && !withinConversation
        let motion: Motion = forcedMotion ?? (!modeChanged ? .resize : (model.isExpanded ? .expand : .collapse))
        lastMotion = motion
        let from: (rect: CGRect, radius: CGFloat) = !canAnimate ? (to, t.radius) : (firstShow ? fromHiddenOrigin(to) : presentedShell())
        let fromMark = !canAnimate ? toMark : (firstShow ? markFrame(t.mark, in: from.rect) : presentedMark())

        lastModeKey = modeKey
        generation += 1
        let gen = generation
        morphing = canAnimate

        // Window and focus
        let expanded = model.isExpanded
        if wantVisible && !panel.isVisible { panel.orderFrontRegardless() }
        stageVisible = wantVisible
        interaction.isHidden = expanded
        interaction.mode = model.mode.shape
        effect.material = !model.mode.isConversation && model.mode.shape == .sheet ? ShellTokens.sheetMaterial : ShellTokens.material
        if expanded {
            panel.allowsKey = DevSnapshot.directory == nil || DevSnapshot.testsKeyboard
            // A non-activating panel could visually show field focus while keyboard and
            // Edit shortcuts still went to the previous app. Activate only on opening; later
            // background replies must not pull focus back from another app.
            // The line needs the keyboard just like the conversation.
            if panel.allowsKey && modeChanged && (model.mode.isConversation || ["line", "resume"].contains(model.mode.key)) { NSApp.activate() }
            if panel.allowsKey && (modeChanged || firstShow) && !panel.isKeyWindow { panel.makeKeyAndOrderFront(nil) }
        } else {
            panel.allowsKey = stack.hasKeyboardFocus
        }

        // Set the end state (model values) without implicit animations.
        let union = canAnimate ? from.rect.union(to).integral : to
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let fromClip = layerGeometry(of: clip, frame: from.rect)
        let toClip = layerGeometry(of: clip, frame: to)
        let fromInner = layerGeometry(of: inner, frame: CGRect(x: union.minX - from.rect.minX, y: union.minY - from.rect.minY,
                                                               width: union.width, height: union.height))
        let toInner = layerGeometry(of: inner, frame: CGRect(x: union.minX - to.minX, y: union.minY - to.minY,
                                                             width: union.width, height: union.height))
        effect.frame = inner.bounds
        tint.frame = inner.bounds
        tint.conversation = model.mode.isConversation
        tint.solid = model.mode.shape == .sheet
        let contentRect = (canAnimate && reveal.frozen != nil) ? frozenRect : to
        hosting.frame = contentRect.offsetBy(dx: -union.minX, dy: -union.minY)
        clip.layer?.cornerRadius = t.radius
        let dark = clip.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        clip.layer?.borderColor = (dark ? ShellTokens.edgeDark : ShellTokens.edgeLight).cgColor
        shadow.frame = stage.bounds
        shadow.fit()
        shadow.setShape(shapePath(to, t.radius))
        shadow.cutout.path = cutoutPath(to, t.radius)
        mark.layer?.transform = CATransform3DIdentity
        let fromMarkPos = layerGeometry(of: mark, frame: CGRect(origin: fromMark.origin, size: CGSize(width: fromMark.width, height: fromMark.width))).position
        let toMarkPos = layerGeometry(of: mark, frame: toMark).position
        interaction.frame = to
        let opacity: Float = wantVisible ? 1 : 0
        for l in [clip.layer, shadow.layer, mark.layer].compactMap({ $0 }) { l.opacity = opacity }
        CATransaction.commit()

        shellRect = to
        unionRect = union
        radius = t.radius
        markRect = toMark
        updateStack(animated: canAnimate)
        updateAura()
        updateMouseIgnoring()

        let finish: @MainActor () -> Void = { [weak self] in
            guard let self, self.generation == gen else { return }
            self.settle(expanded: expanded, visible: wantVisible)
        }

        guard canAnimate else {
            for l in [clip.layer, inner.layer, mark.layer, hosting.layer].compactMap({ $0 }) { l.removeAllAnimations() }
            shadow.removeAnimations()
            reveal.frozen = nil
            reveal.shown = true
            finish()
            return
        }

        if reduced {
            // Reduce motion: brief cross-fade, no springs.
            CATransaction.begin()
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { finish() } }
            for l in [clip.layer, inner.layer, mark.layer].compactMap({ $0 }) { l.removeAllAnimations() }
            shadow.removeAnimations()
            if modeChanged || firstShow || !wantVisible {
                for l in [clip.layer, shadow.layer, mark.layer].compactMap({ $0 }) {
                    let a = CABasicAnimation(keyPath: "opacity")
                    a.fromValue = wantVisible ? 0.0 : 1.0
                    a.toValue = opacity
                    a.duration = ShellTokens.reducedFade
                    l.add(a, forKey: "fade")
                }
            }
            reveal.shown = true
            CATransaction.commit()
            return
        }

        let sp = spring(motion)
        func springAnim(_ key: String, from: Any, to: Any) -> CASpringAnimation {
            let a = CASpringAnimation(keyPath: key)
            a.mass = sp.mass
            a.stiffness = sp.stiffness
            a.damping = sp.damping
            a.fromValue = from
            a.toValue = to
            // settlingDuration runs down to fractions of a pixel; to the eye the shape rests earlier.
            a.duration = min(a.settlingDuration, Self.settleTime(sp))
            a.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            return a
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { finish() } }
        if let l = clip.layer {
            l.add(springAnim("position", from: NSValue(point: fromClip.position), to: NSValue(point: toClip.position)), forKey: "position")
            l.add(springAnim("bounds", from: NSValue(rect: fromClip.bounds), to: NSValue(rect: toClip.bounds)), forKey: "bounds")
            l.add(springAnim("cornerRadius", from: from.radius, to: t.radius), forKey: "cornerRadius")
        }
        inner.layer?.add(springAnim("position", from: NSValue(point: fromInner.position), to: NSValue(point: toInner.position)), forKey: "position")
        shadow.animateShape { springAnim("shadowPath", from: shapePath(from.rect, from.radius), to: shapePath(to, t.radius)) }
        shadow.cutout.add(springAnim("path", from: cutoutPath(from.rect, from.radius), to: cutoutPath(to, t.radius)), forKey: "path")
        if let l = mark.layer {
            let k = fromMark.width / max(1, toMark.width)
            l.add(springAnim("position", from: NSValue(point: fromMarkPos), to: NSValue(point: toMarkPos)), forKey: "position")
            l.add(springAnim("transform", from: NSValue(caTransform3D: CATransform3DMakeScale(k, k, 1)),
                             to: NSValue(caTransform3D: CATransform3DIdentity)), forKey: "transform")
        }
        if firstShow || !wantVisible {
            for l in [clip.layer, shadow.layer, mark.layer].compactMap({ $0 }) {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = wantVisible ? 0.0 : 1.0
                a.toValue = opacity
                a.duration = wantVisible ? 0.12 : 0.2
                if !wantVisible {
                    a.beginTime = l.convertTime(CACurrentMediaTime(), from: nil) + 0.08
                    a.fillMode = .backwards
                }
                l.add(a, forKey: "fade")
            }
        }
        if modeChanged {
            crossfade(spring: sp, attachmentHandoff: attachmentHandoff)
        }
        CATransaction.commit()
        if let t0 = triggerTime {
            lastLatency = CACurrentMediaTime() - t0
            triggerTime = nil
        }
    }

    /// Starting frame when the shell appears from nothing (hidden pill: from the menu bar icon).
    private func fromHiddenOrigin(_ to: CGRect) -> (rect: CGRect, radius: CGFloat) {
        if let a = statusAnchor?() {
            return (toStage(NSRect(x: a.midX - 12, y: a.minY - 4, width: 24, height: 4)), 2)
        }
        return (to.insetBy(dx: to.width * 0.1, dy: to.height * 0.1), radius)
    }

    /// Old content fades out quickly (60–80 ms), then switches; new content arrives staggered from ~45 % of the shape motion.
    private func crossfade(spring sp: ShellTokens.Spring, attachmentHandoff: Bool) {
        // During line → chat the mark travels past the attachment header. Reveal
        // the new content near its final position, so it cannot draw through the chips.
        var fraction = attachmentHandoff ? 0.94 : ShellTokens.contentRevealAt
        if case .working = model.mode { fraction = ShellTokens.contentRevealWorking }
        let revealAt = max(Self.time(toReach: fraction, sp), ShellTokens.fadeOut + 0.01)
        revealGeneration += 1
        let rgen = revealGeneration
        let fadeOut = reveal.frozen == nil ? 0 : ShellTokens.fadeOut
        if let l = hosting.layer {
            let start = Double(l.presentation()?.opacity ?? 1)
            let total = revealAt + ShellTokens.contentFadeIn
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = [start, 0.0, 0.0, 1.0]
            a.keyTimes = [0, NSNumber(value: fadeOut / total), NSNumber(value: revealAt / total), 1]
            a.timingFunctions = [CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeOut)]
            a.duration = total
            l.add(a, forKey: "fadeIn")
            if fadeOut > 0 {
                // Old content: shrink slightly (0.98, around the center) and blur, only while fading out.
                let k = ShellTokens.fadeOutScale
                let b = l.bounds.size
                let shrink = CATransform3DScale(CATransform3DMakeTranslation((1 - k) * (0.5 - l.anchorPoint.x) * b.width,
                                                                            (1 - k) * (0.5 - l.anchorPoint.y) * b.height, 0), k, k, 1)
                let t = CAKeyframeAnimation(keyPath: "transform")
                t.values = [NSValue(caTransform3D: CATransform3DIdentity), NSValue(caTransform3D: shrink), NSValue(caTransform3D: CATransform3DIdentity)]
                t.keyTimes = [0, 1, 1]
                t.duration = fadeOut
                t.timingFunctions = [CAMediaTimingFunction(name: .easeIn), CAMediaTimingFunction(name: .linear)]
                l.add(t, forKey: "fadeOutScale")
                if let blur = CIFilter(name: "CIGaussianBlur") {
                    blur.name = "blur"
                    blur.setValue(0, forKey: kCIInputRadiusKey)
                    hosting.layerUsesCoreImageFilters = true
                    l.filters = [blur]
                    let r = CABasicAnimation(keyPath: "filters.blur.inputRadius")
                    r.fromValue = 0
                    r.toValue = ShellTokens.fadeOutBlur
                    r.duration = fadeOut
                    l.add(r, forKey: "fadeOutBlur")
                }
            }
        }
        let swap: @MainActor () -> Void = { [weak self] in
            guard let self, self.revealGeneration == rgen else { return }
            self.reveal.shown = false
            self.reveal.frozen = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.hosting.layer?.filters = nil
            self.hosting.layer?.removeAnimation(forKey: "fadeOutBlur")
            self.hosting.frame = self.shellRect.offsetBy(dx: -self.unionRect.minX, dy: -self.unionRect.minY)
            CATransaction.commit()
        }
        if fadeOut == 0 { swap() } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + fadeOut * slowdown) { MainActor.assumeIsolated { swap() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + revealAt * slowdown) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.revealGeneration == rgen else { return }
                self.reveal.shown = true
            }
        }
    }

    /// After the motion: shrink the interior to the shape, give focus back, hide if needed.
    private func settle(expanded: Bool, visible: Bool) {
        morphing = false
        reveal.frozen = nil
        hosting.layer?.filters = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if unionRect != shellRect {
            unionRect = shellRect
            inner.frame = CGRect(origin: .zero, size: shellRect.size)
            effect.frame = inner.bounds
            tint.frame = inner.bounds
            hosting.frame = inner.bounds
        }
        CATransaction.commit()
        reveal.shown = true
        if !expanded && panel.isKeyWindow {
            // Give the keyboard back to the previous app.
            panel.orderOut(nil)
            if visible { panel.orderFrontRegardless() }
        }
        if !visible { panel.orderOut(nil) }
        updateMouseIgnoring()
    }

    // MARK: Move and resize the conversation

    /// Explicit placement belongs to this open interaction; a fresh opening starts at the pill.
    private var customWorkspace: NSRect?
    private var workspaceDrag: (mouse: NSPoint, frame: NSRect, resize: Bool)?

    /// Dragging the header moves, the bottom-right corner resizes (top-left corner stays put).
    /// Works with the mouse position on screen, not with the view, which moves along.
    func dragWorkspace(resize: Bool) {
        guard model.mode.isConversation else { return }
        let mouse = NSEvent.mouseLocation
        if workspaceDrag == nil { workspaceDrag = (mouse, shellScreenRect, resize) }
        guard let start = workspaceDrag else { return }
        let dx = mouse.x - start.mouse.x, dy = mouse.y - start.mouse.y
        var f = start.frame
        if start.resize {
            f.size.width = max(ShellTokens.workspaceMin.width, f.width + dx)
            f.size.height = max(ShellTokens.workspaceMin.height, f.height - dy)
            f.origin.y = start.frame.maxY - f.height
        } else {
            f.origin.x += dx
            f.origin.y += dy
        }
        let vis = screen(containing: f).visibleFrame
        customWorkspace = f
        workspace = WorkspacePlacement(frame: f, visibleFrame: vis, minimumSize: ShellTokens.workspaceMin,
                                       inset: max(ShellTokens.screenInset, 20))
        layout(animated: false, force: true)
    }

    func endWorkspaceDrag() {
        guard workspaceDrag != nil else { return }
        workspaceDrag = nil
        let frame = shellScreenRect
        customWorkspace = frame
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: "workspace.frame")
    }

    // MARK: Move the pill (no animation)

    func movePill(to screenRect: NSRect) {
        let sc = screen(containing: screenRect)
        if panel.frame != sc.frame { panel.setFrame(sc.frame, display: false) }
        let to = toStage(screenRect)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [clip.layer, inner.layer, mark.layer].compactMap({ $0 }) { l.removeAllAnimations() }
        shadow.removeAnimations()
        clip.frame = to
        inner.frame = CGRect(origin: .zero, size: to.size)
        effect.frame = inner.bounds
        tint.frame = inner.bounds
        hosting.frame = inner.bounds
        shadow.frame = stage.bounds
        shadow.fit()
        shadow.setShape(shapePath(to, radius))
        let defaultSlotY = (ShellTokens.pillHeight - 28) / 2
        let slot = pillCache?.slot ?? NSRect(x: 10, y: defaultSlotY, width: 28, height: 28)
        mark.frame = markFrame(slot, in: to)
        interaction.frame = to
        CATransaction.commit()
        shellRect = to
        unionRect = to
        markRect = mark.frame
        updateStack(animated: false)
        updateAura()
    }

    /// Frame of the shell in screen coordinates.
    var shellScreenRect: NSRect { shellRect.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY) }

    // MARK: Pill

    func pillClicked() {
        triggerTime = CACurrentMediaTime()
        // Parked → back; something lies on Pippa → the line; otherwise input (AppModel+Tray).
        model.activatePill()
    }

    // MARK: Items on Pippa

    /// Hits the shell or (at rest) the cards behind it.
    func hits(_ p: CGPoint) -> Bool {
        guard stageVisible else { return false }
        return shellRect.contains(p) || stack.activeFrame.contains(p)
    }

    /// Area of the cards in screen coordinates; nil if none are visible.
    var stackScreenRect: NSRect? {
        let r = stack.activeFrame
        guard stageVisible, !stack.isHidden, r.width > 0, r.height > 0 else { return nil }
        return r.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
    }

    /// Mouse on the pill: the cards fan out after a short dwell.
    func pillHover(_ on: Bool) {
        stack.setPillHover(on && model.mode.key == "pill")
    }

    /// Cards only at rest, with the pill visible; the line shows its own.
    func updateStack(animated: Bool) {
        let visible = stageVisible && model.pillVisible && model.mode.key == "pill"
        let room = toStage(screen(containing: shellScreenRect).visibleFrame)
        stack.update(items: visible ? model.tray.peek : [], tray: model.tray, pill: shellRect, room: room,
                     animated: animated && !MarkHub.shared.reduced)
    }

    /// Glow and thought bubble only around the collapsed pill; the open conversation shows the same steps itself.
    func updateAura() {
        if aura.frame != stage.bounds { aura.frame = stage.bounds }
        let height = stage.bounds.height
        func flipped(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height) }
        let atRest = stageVisible && model.pillVisible && model.mode.key == "pill"
        let chat = model.conversations
        let running = atRest && chat.isRunning && chat.thought.isVisible
        let room = toStage(screen(containing: shellScreenRect).visibleFrame)
        auraState.update(pill: flipped(shellRect), mark: flipped(markRect), below: room.maxY - shellRect.maxY < 120,
                         working: atRest && model.pillStatus.tone == .working,
                         step: running ? chat.thought.bubbles.last : nil, startedAt: running ? chat.thought.startedAt : nil,
                         slowText: ThoughtLine.slowNote)
    }

    @discardableResult
    func focusAttachments() -> Bool {
        guard model.mode.key == "pill", !model.tray.peek.isEmpty else { return false }
        panel.allowsKey = true
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        return stack.focusAttachments()
    }

    func showPillMenu(with event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        menu.addItem(MenuAction.item(T("Ask Pippa…", table: "App")) { [weak self] in self?.model.openInput() })
        menu.addItem(MenuAction.item(T("Look at a Folder…", table: "App")) { [weak self] in self?.model.chooseFolder() })
        menu.addItem(MenuAction.item(T("Look at Selected Mail", table: "App")) { [weak self] in self?.model.readSelectedMail() })
        if !model.tray.peek.isEmpty {
            menu.addItem(MenuAction.item(T("Show Attachments", table: "Shelf")) { [weak self] in self?.focusAttachments() })
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction.item(T("Hide Pippa", table: "App")) { [weak self] in self?.model.pillVisible = false })
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
}
