import AppKit
import PippaCore
import QuartzCore

// Items lying on Pippa, at rest: two or three tilted cards peek out from behind
// the pill. On hover they spring apart and show name and origin
// ("from Downloads"). Click opens the line, dragging takes the item along (TakeDrag.swift).
//
// A subview of the stage, BELOW the shape: what the pill covers stays covered.
// All frames here are in stage coordinates unless marked "local".

/// Layout of the cards around the pill, for rest and fanned out. Pure, no views.
struct TrayFanGeometry {
    static let card = CGSize(width: 34, height: 44)
    /// Rotation in degrees, front card first.
    static let restAngles: [CGFloat] = [-8, 5, -2]
    static let restOffsets: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 2), CGPoint(x: -8, y: 1)]
    static let fanAngles: [CGFloat] = [-2, 1.5, -1]
    static let fanStep: CGFloat = 40
    static let gap: CGFloat = 6
    /// Clear the 24pt remove target (14pt beyond the card) before the caption.
    static let captionGap: CGFloat = 20
    static let labelMax = CGSize(width: 220, height: 36)

    struct Slot: Equatable {
        var center: CGPoint
        var angle: CGFloat
        var rect: CGRect {
            CGRect(x: center.x - TrayFanGeometry.card.width / 2, y: center.y - TrayFanGeometry.card.height / 2,
                   width: TrayFanGeometry.card.width, height: TrayFanGeometry.card.height)
        }
    }

    /// Cards above the pill (otherwise below, if there's no room above).
    var above: Bool
    var rest: [Slot]
    var fan: [Slot]
    var label: CGRect
    /// Area that reacts to the mouse at rest (only the visible part above or below the pill).
    var restActive: CGRect
    /// Area that reacts to the mouse when fanned out (cards, caption, bridge to the pill).
    var fanActive: CGRect
    /// Frame of the whole view (covers both layouts so it doesn't jump when fanning out).
    var box: CGRect

    /// `focus`: index of the card the caption belongs to (the hovered one; the front one otherwise).
    init(count: Int, pill: CGRect, room: CGRect, labelSize: CGSize, focus: Int = 0) {
        let n = max(0, min(count, TrayRules.peekCount, Self.restAngles.count))
        let w = Self.card.width, h = Self.card.height
        let needed = h + Self.gap + Self.captionGap + Self.labelMax.height + 4
        above = pill.maxY + needed <= room.maxY || pill.minY - needed < room.minY
        let dir: CGFloat = above ? 1 : -1

        // Rest: behind the front third of the pill, about half peeks out.
        let restX = pill.minX + max(26, pill.width / 6)
        let restY = above ? pill.maxY + 2 : pill.minY - 2
        var rest: [Slot] = []
        for i in 0..<n {
            let o = Self.restOffsets[i]
            rest.append(Slot(center: CGPoint(x: restX + o.x, y: restY + dir * o.y), angle: Self.restAngles[i]))
        }

        // Fanned out: side by side, fully visible, at the front edge of the pill.
        var first = pill.minX + 4 + w / 2
        let last = first + CGFloat(max(0, n - 1)) * Self.fanStep
        let overflow = last + w / 2 + 4 - room.maxX
        if overflow > 0 { first -= overflow }
        first = max(first, room.minX + 4 + w / 2)
        let fanY = above ? pill.maxY + Self.gap + h / 2 : pill.minY - Self.gap - h / 2
        var fan: [Slot] = []
        for i in 0..<n {
            fan.append(Slot(center: CGPoint(x: first + CGFloat(i) * Self.fanStep, y: fanY), angle: Self.fanAngles[i]))
        }

        let fanCards = fan.reduce(CGRect.null) { $0.union($1.rect) }
        let restCards = rest.reduce(CGRect.null) { $0.union($1.rect) }
        let lw = min(Self.labelMax.width, max(40, labelSize.width))
        let lh = min(Self.labelMax.height, max(18, labelSize.height))
        let anchor = fan.indices.contains(focus) ? fan[focus].rect.minX : fanCards.minX
        var lx = fanCards.isNull ? pill.minX : anchor
        lx = max(room.minX + 4, min(lx, room.maxX - 4 - lw))
        // Reserved for the caption over any card: hovering along the row never changes the frame.
        let roomX = fanCards.isNull ? lx : max(room.minX + 4, min(fanCards.minX, room.maxX - 4 - Self.labelMax.width))
        let roomW = fanCards.isNull ? Self.labelMax.width
            : min(room.maxX - 4, fanCards.maxX + Self.labelMax.width) - roomX
        let ly = above ? (fanCards.isNull ? pill.maxY : fanCards.maxY) + Self.captionGap
                       : (fanCards.isNull ? pill.minY : fanCards.minY) - Self.captionGap - lh
        label = CGRect(x: lx, y: ly, width: lw, height: lh)

        // Rest: only the part outside the pill (the pill itself belongs to its own surface).
        if restCards.isNull {
            restActive = .null
        } else if above {
            restActive = CGRect(x: restCards.minX, y: pill.maxY, width: restCards.width, height: max(0, restCards.maxY - pill.maxY))
        } else {
            restActive = CGRect(x: restCards.minX, y: restCards.minY, width: restCards.width, height: max(0, pill.minY - restCards.minY))
        }
        // Bridge between pill and cards so the mouse isn't "outside" on the way there.
        let bridge = fanCards.isNull ? CGRect.null
            : CGRect(x: fanCards.minX, y: above ? pill.maxY - 2 : fanCards.maxY, width: fanCards.width, height: Self.gap + 4)
        fanActive = fanCards.insetBy(dx: -16, dy: -16).union(label).union(bridge)

        let labelRoom = CGRect(x: roomX, y: above ? ly : ly + lh - Self.labelMax.height,
                               width: max(Self.labelMax.width, roomW), height: Self.labelMax.height)
        box = restCards.union(fanActive).union(labelRoom).insetBy(dx: -14, dy: -14).integral
        self.rest = rest
        self.fan = fan
    }
}

@MainActor
final class TrayStackView: NSView {
    weak var controller: ShellController?

    private weak var tray: TrayController?
    private var items: [TrayItem] = []
    private var cards: [UUID: TakeSourceView] = [:]
    /// Where each card last stood (stage), for the spring from the old to the new spot.
    private var poses: [UUID: TrayFanGeometry.Slot] = [:]
    /// Already shown at the pill once (only new ones spring out, not every reappearance).
    private var seen: Set<UUID> = []
    private var pill: CGRect = .zero
    private var room: CGRect = .zero
    private var geometry: TrayFanGeometry?
    private var fanned = false
    private var stackHover = false
    private var pillHover = false
    private var takingOut = false
    private var removalLocked = false
    private var hoverGeneration = 0
    private var hoveredID: UUID?
    /// New results only spring out after the first showing (not already at start).
    private var primed = false
    private var tracking: NSTrackingArea?

    private let removeButton = TrayRemoveButton()

    private let labelBox = NSVisualEffectView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let originLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        isHidden = true

        labelBox.material = ShellTokens.material
        labelBox.blendingMode = .behindWindow
        labelBox.state = .active
        labelBox.wantsLayer = true
        labelBox.layer?.cornerRadius = 9
        labelBox.layer?.cornerCurve = .continuous
        labelBox.layer?.masksToBounds = true
        labelBox.alphaValue = 0
        for (field, size, weight, color) in [(nameLabel, CGFloat(12), NSFont.Weight.medium, NSColor.labelColor),
                                             (originLabel, CGFloat(11), NSFont.Weight.regular, NSColor.secondaryLabelColor)] {
            field.font = .systemFont(ofSize: size, weight: weight)
            field.textColor = color
            // A long file name keeps its start and extension; "from Downloads" is never cut mid-word.
            field.lineBreakMode = field === nameLabel ? .byTruncatingMiddle : .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.setAccessibilityElement(false)
            labelBox.addSubview(field)
        }
        labelBox.setAccessibilityElement(false)
        addSubview(labelBox)
        removeButton.isBordered = false
        removeButton.title = ""
        removeButton.target = self
        removeButton.action = #selector(removeHovered)
        removeButton.isHidden = true
        addSubview(removeButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }

    /// Area currently accepting mouse and clicks (stage); empty if nothing lies there.
    var activeFrame: CGRect {
        guard !isHidden, let g = geometry else { return .zero }
        let r = fanned ? g.fanActive : g.restActive
        return r.isNull ? .zero : r
    }

    #if DEBUG
    /// Native snapshot fixture; no synthesized mouse input or external application data.
    func previewFocusedAttachment(at index: Int) {
        guard items.indices.contains(index) else { return }
        hoveredID = items[index].id
        stackHover = true
        setFanned(true)
        relabel()
    }
    func previewRemoveFocusedAttachment() { removeHovered() }
    var previewFocusedCardFrame: CGRect? {
        guard let id = hoveredID, let card = cards[id] else { return nil }
        return card.frame.offsetBy(dx: frame.minX, dy: frame.minY)
    }
    #endif

    var hasKeyboardFocus: Bool { window?.firstResponder is TrayFocusCard }

    @discardableResult
    func focusAttachments() -> Bool {
        guard let item = items.first, let card = cards[item.id], let window else { return false }
        removalLocked = false
        hoveredID = item.id
        setFanned(true)
        return window.makeFirstResponder(card)
    }

    private func moveFocus(from id: UUID, backwards: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items.isEmpty else { return }
        let next = (index + (backwards ? items.count - 1 : 1)) % items.count
        if let card = cards[items[next].id] { window?.makeFirstResponder(card) }
    }

    // MARK: From the shell

    /// New layout: what lies there (front first), where the pill is, how much room the screen leaves.
    /// An empty list fades out.
    func update(items newItems: [TrayItem], tray newTray: TrayController, pill newPill: CGRect, room newRoom: CGRect, animated: Bool) {
        tray = newTray
        let shown = Array(newItems.prefix(TrayRules.peekCount))
        guard !shown.isEmpty else {
            if !isHidden { hide() }
            return
        }
        let appearing = isHidden
        let unchanged = !appearing && shown == items && newPill == pill && newRoom == room
        if unchanged { return }
        items = shown
        seen.formIntersection(Set(shown.map(\.id)))
        pill = newPill
        room = newRoom
        isHidden = false
        syncCards()
        relayout(animated: animated, appearing: appearing)
        if appearing && animated, let l = layer {
            // Only when the shape nearly rests: fade in briefly.
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 0.0
            a.toValue = 1.0
            a.duration = 0.16
            a.beginTime = l.convertTime(CACurrentMediaTime(), from: nil) + 0.12
            a.fillMode = .backwards
            l.add(a, forKey: "appear")
        }
        primed = true
    }

    /// Mouse over the pill: fan out after a short dwell.
    func setPillHover(_ on: Bool) {
        pillHover = on
        if !on, let window {
            let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if !bounds.contains(p) { removalLocked = false }
        }
        guard !isHidden else { return }
        if on && !removalLocked {
            hoverGeneration += 1
            let gen = hoverGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.hoverGeneration == gen, self.pillHover, !self.isHidden else { return }
                    self.setFanned(true)
                }
            }
        } else {
            scheduleFold()
        }
    }

    // MARK: Cards

    private func hide() {
        isHidden = true
        fanned = false
        stackHover = false
        pillHover = false
        hoveredID = nil
        labelBox.alphaValue = 0
        items = []
        for card in cards.values { card.removeFromSuperview() }
        cards = [:]
        poses = [:]
        geometry = nil
        updateTrackingAreas()
    }

    private func syncCards() {
        let ids = Set(items.map(\.id))
        for (id, card) in cards where !ids.contains(id) {
            card.removeFromSuperview()
            cards[id] = nil
            poses[id] = nil
        }
        if let h = hoveredID, !ids.contains(h) { hoveredID = nil }
        for item in items {
            let card = cards[item.id] ?? makeCard()
            cards[item.id] = card
            card.tray = tray
            if card.item != item { card.item = item }
        }
        // Front card on top: bring to front in reverse order (only if needed).
        let wanted = items.reversed().compactMap { cards[$0.id] }
        let current = subviews.compactMap { $0 as? TakeSourceView }
        if current.map(ObjectIdentifier.init) != wanted.map(ObjectIdentifier.init) {
            for card in wanted { addSubview(card) }
        }
    }

    private func makeCard() -> TakeSourceView {
        let card = TrayFocusCard(frame: CGRect(origin: .zero, size: TrayFanGeometry.card))
        card.onFocus = { [weak self, weak card] focused in
            guard let self else { return }
            if focused {
                self.hoveredID = card?.item?.id
                self.setFanned(true)
                self.relabel()
            } else {
                self.updateHighlight()
                self.scheduleFold()
            }
        }
        card.onNavigate = { [weak self, weak card] backwards in
            guard let self, let id = card?.item?.id else { return }
            self.moveFocus(from: id, backwards: backwards)
        }
        card.onRemove = { [weak self, weak card] in
            guard let self, let id = card?.item?.id else { return }
            self.removeItem(id)
        }
        card.onClick = { [weak self, weak card] in
            guard let controller = self?.controller else { return }
            controller.triggerTime = CACurrentMediaTime()
            if let item = card?.item, item.role == .result {
                controller.model.tray.showResult(item.id)
            } else {
                controller.model.openLine()
            }
        }
        card.onDragState = { [weak self] on in
            guard let self else { return }
            self.takingOut = on
            self.controller?.takingOut = on
            self.updateHighlight()
            if !on { self.scheduleFold() }
        }
        return card
    }

    private func setFanned(_ on: Bool) {
        guard fanned != on, !isHidden else { return }
        fanned = on
        if !on { hoveredID = nil }
        relayout(animated: !MarkHub.shared.reduced, appearing: false)
    }

    private func scheduleFold() {
        hoverGeneration += 1
        let gen = hoverGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hoverGeneration == gen else { return }
                guard !self.stackHover, !self.pillHover, !self.takingOut,
                      !(self.window?.firstResponder is TrayFocusCard) else { return }
                self.setFanned(false)
            }
        }
    }

    private func relayout(animated: Bool, appearing: Bool) {
        let shownItem = items.first { $0.id == hoveredID } ?? items.first
        let labelSize = setLabel(for: shownItem)
        let g = TrayFanGeometry(count: items.count, pill: pill, room: room, labelSize: labelSize, focus: focusIndex)
        geometry = g
        let box = g.box
        let slots = fanned ? g.fan : g.rest
        let spring = fanned ? ShellTokens.expand : ShellTokens.collapse
        let pillCenter = CGPoint(x: pill.midX, y: pill.midY)
        let reduced = MarkHub.shared.reduced

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        frame = box
        for (i, item) in items.enumerated() where i < slots.count {
            guard let card = cards[item.id] else { continue }
            let slot = slots[i]
            let old = poses[item.id]
            let toT = Self.rotation(slot.angle)
            var fromT: CATransform3D?
            if animated && !reduced {
                if !seen.contains(item.id) && primed && item.role == .result {
                    // New result: springs out of the middle of the pill (0.6 → 1).
                    let d = CGPoint(x: pillCenter.x - slot.center.x, y: pillCenter.y - slot.center.y)
                    fromT = CATransform3DConcat(CATransform3DMakeScale(0.6, 0.6, 1), CATransform3DMakeTranslation(d.x, d.y, 0))
                } else if let old, !appearing, old != slot {
                    let presented = card.paper.presentation()?.transform ?? card.paper.transform
                    let dx = old.center.x - slot.center.x, dy = old.center.y - slot.center.y
                    fromT = CATransform3DConcat(presented, CATransform3DMakeTranslation(dx, dy, 0))
                }
            }
            card.frame = slot.rect.offsetBy(dx: -box.minX, dy: -box.minY)
            card.paper.transform = toT
            poses[item.id] = slot
            seen.insert(item.id)
            if let fromT {
                card.paper.add(Self.springAnimation(from: fromT, to: toT, spring), forKey: "transform")
            } else if old != slot {
                card.paper.removeAnimation(forKey: "transform")
            }
        }
        labelBox.frame = g.label.offsetBy(dx: -box.minX, dy: -box.minY)
        layoutLabel()
        CATransaction.commit()

        let alpha: CGFloat = fanned ? 1 : 0
        if labelBox.alphaValue != alpha {
            if animated && !reduced {
                let box = labelBox
                let duration = fanned ? 0.16 : 0.1
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = duration
                    box.animator().alphaValue = alpha
                }
            } else {
                labelBox.alphaValue = alpha
            }
        }
        updateHighlight()
        updateTrackingAreas()
    }

    /// Hovered card: 8 % larger and 3 pt away from the pill (none with Reduce Motion).
    private static let lift: CGFloat = 1.08
    private var liftOffset: CGFloat { geometry?.above == false ? -3 : 3 }

    private static func rotation(_ degrees: CGFloat) -> CATransform3D {
        CATransform3DMakeRotation(degrees * .pi / 180, 0, 0, 1)
    }

    private static func springAnimation(from: CATransform3D, to: CATransform3D, _ sp: ShellTokens.Spring) -> CASpringAnimation {
        let a = CASpringAnimation(keyPath: "transform")
        a.mass = sp.mass
        a.stiffness = sp.stiffness
        a.damping = sp.damping
        a.fromValue = NSValue(caTransform3D: from)
        a.toValue = NSValue(caTransform3D: to)
        a.duration = min(a.settlingDuration, ShellController.settleTime(sp))
        return a
    }

    // MARK: Caption

    /// Card the caption stands over: the hovered or focused one, otherwise the front one.
    private var focusIndex: Int { items.firstIndex { $0.id == hoveredID } ?? 0 }

    /// Name and origin of the item under the mouse (otherwise the front one); returns the desired size.
    private func setLabel(for item: TrayItem?) -> CGSize {
        guard let item else { return .zero }
        nameLabel.stringValue = item.name
        nameLabel.toolTip = item.name
        originLabel.stringValue = Self.originLine(item)
        let wide = max(nameLabel.intrinsicContentSize.width, originLabel.intrinsicContentSize.width)
        let height: CGFloat = originLabel.stringValue.isEmpty ? 22 : 36
        return CGSize(width: ceil(wide) + 22, height: height)
    }

    private func layoutLabel() {
        let b = labelBox.bounds
        let inset: CGFloat = 9
        if originLabel.stringValue.isEmpty {
            originLabel.isHidden = true
            nameLabel.frame = CGRect(x: inset, y: (b.height - 16) / 2, width: max(0, b.width - 2 * inset), height: 16)
        } else {
            originLabel.isHidden = false
            nameLabel.frame = CGRect(x: inset, y: b.height - 5 - 16, width: max(0, b.width - 2 * inset), height: 16)
            originLabel.frame = CGRect(x: inset, y: 4, width: max(0, b.width - 2 * inset), height: 14)
        }
    }

    /// "from Downloads" ("Folder from Downloads" for a folder), "Ready" for results; nothing if the origin is unknown.
    private static func originLine(_ item: TrayItem) -> String {
        if item.role == .result { return T("Ready", table: "Shelf") }
        let folder = TrayThumbnails.isFolder(item)
        guard let origin = item.origin, !origin.isEmpty else { return folder ? T("Folder", table: "Shelf") : "" }
        return folder ? T("Folder from %@", table: "Shelf", origin) : T("from %@", table: "Shelf", origin)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        tracking = nil
        guard !isHidden, let g = geometry else { return }
        let active = (fanned ? g.fanActive : g.restActive)
        guard !active.isNull, active.width > 0, active.height > 0 else { return }
        let local = active.offsetBy(dx: -frame.minX, dy: -frame.minY)
        let t = NSTrackingArea(rect: local, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        guard !removalLocked else { return }
        stackHover = true
        hoverGeneration += 1
        setFanned(true)
    }

    override func mouseExited(with event: NSEvent) {
        removalLocked = false
        stackHover = false
        scheduleFold()
    }

    override func mouseMoved(with event: NSEvent) {
        guard fanned, !takingOut else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !removeButton.isHidden && removeButton.frame.contains(p) { return }
        let id = items.first { cards[$0.id]?.frame.contains(p) == true }?.id
        guard let id, id != hoveredID else { return }
        hoveredID = id
        updateHighlight()
        relabel()
    }

    /// Switch only the caption (running card springs stay untouched).
    private func relabel() {
        let shownItem = items.first { $0.id == hoveredID } ?? items.first
        let g = TrayFanGeometry(count: items.count, pill: pill, room: room, labelSize: setLabel(for: shownItem), focus: focusIndex)
        guard g.box == frame else {
            relayout(animated: !MarkHub.shared.reduced, appearing: false)
            return
        }
        geometry = g
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        labelBox.frame = g.label.offsetBy(dx: -frame.minX, dy: -frame.minY)
        layoutLabel()
        CATransaction.commit()
        updateHighlight()
        updateTrackingAreas()
    }

    /// Hit only cards (and, when fanned out, the gaps between them); the rest lets clicks through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        let local = convert(point, from: superview)
        if !removeButton.isHidden && removeButton.frame.contains(local) { return removeButton }
        let active = activeFrame.offsetBy(dx: -frame.minX, dy: -frame.minY)
        for item in items {
            if let card = cards[item.id], card.frame.contains(local) { return card }
        }
        return fanned && active.contains(local) ? self : nil
    }


    private func updateHighlight() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in items {
            guard let card = cards[item.id], let pose = poses[item.id] else { continue }
            var transform = Self.rotation(pose.angle)
            let highlighted = fanned && !takingOut && hoveredID == item.id
            card.lifted = highlighted
            card.showsFocusRing = highlighted && (card as? TrayFocusCard)?.hasFocus == true
            if highlighted && !MarkHub.shared.reduced {
                transform = CATransform3DConcat(CATransform3DScale(transform, Self.lift, Self.lift, 1),
                                                CATransform3DMakeTranslation(0, liftOffset, 0))
            }
            card.paper.transform = transform
            card.toolTip = TakeSourceView.spokenName(item)
            let removeName = T("Remove %@", table: "Shelf", item.name)
            let existing = (card.accessibilityCustomActions() ?? []).filter { $0.name != removeName }
            let remove = NSAccessibilityCustomAction(name: removeName) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.controller?.model.isActiveWork != true, self.tray?.isWorking != true else { return false }
                    self.removeItem(item.id)
                    return true
                }
            }
            card.setAccessibilityCustomActions(existing + [remove])
        }
        let wasHidden = removeButton.isHidden
        removeButton.isHidden = !fanned || takingOut || hoveredID == nil
        removeButton.isEnabled = controller?.model.isActiveWork != true && tray?.isWorking != true
        if let id = hoveredID, let card = cards[id], let item = items.first(where: { $0.id == id }) {
            // Centre of the 24 pt target a little outside the visible top right corner, after lift and scale.
            let corner = card.visibleCorner
            let lifted = !MarkHub.shared.reduced
            let scale = lifted ? Self.lift : 1
            let dx = (corner.x - card.bounds.midX) * scale, dy = (corner.y - card.bounds.midY) * scale
            let center = CGPoint(x: card.frame.midX + dx + 3, y: card.frame.midY + dy + 3 + (lifted ? liftOffset : 0))
            removeButton.frame = CGRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24)
            removeButton.setAccessibilityLabel(T("Remove %@", table: "Shelf", item.name))
            removeButton.toolTip = T("Remove %@", table: "Shelf", item.name)
            addSubview(removeButton, positioned: .above, relativeTo: nil)
        }
        CATransaction.commit()
        if wasHidden && !removeButton.isHidden && !MarkHub.shared.reduced {
            removeButton.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                removeButton.animator().alphaValue = 1
            }
        } else if MarkHub.shared.reduced {
            removeButton.alphaValue = 1
        }
    }

    @objc private func removeHovered() {
        guard let id = hoveredID else { return }
        removeItem(id)
    }

    private func removeItem(_ id: UUID) {
        guard !takingOut, controller?.model.isActiveWork != true, tray?.isWorking != true else { return }
        // Fold before mutation: a different attachment never inherits the clicked remove target.
        hoveredID = nil
        removalLocked = true
        stackHover = false
        pillHover = false
        setFanned(false)
        removeButton.isHidden = true
        tray?.remove(id)
    }

    override func mouseDown(with event: NSEvent) {}
}

/// Focus uses the same stable card frame as pointer interaction.
private final class TrayFocusCard: TakeSourceView {
    var onFocus: ((Bool) -> Void)?
    var onRemove: (() -> Void)?
    var onNavigate: ((Bool) -> Void)?
    /// Set before `onFocus` runs (the window only records the new first responder afterwards).
    private(set) var hasFocus = false
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { hasFocus = true; onFocus?(true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { hasFocus = false; onFocus?(false) }
        return accepted
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 48: onNavigate?(event.modifierFlags.contains(.shift))
        case 123: onNavigate?(true)
        case 124: onNavigate?(false)
        case 36, 49: onClick?()
        case 51, 117: onRemove?()
        default: super.keyDown(with: event)
        }
    }
}

/// Remove target: an 18 pt disc with a small cross, inside a 24 pt hit area.
private final class TrayRemoveButton: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        imagePosition = .noImage
        focusRingType = .none
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: 24, height: 24) }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let disc = NSRect(x: bounds.midX - 9, y: bounds.midY - 9, width: 18, height: 18)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.4 : 0.22)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        (dark ? NSColor(srgbRed: 0.23, green: 0.24, blue: 0.27, alpha: 1) : NSColor.white).setFill()
        NSBezierPath(ovalIn: disc).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        let rim = NSBezierPath(ovalIn: disc.insetBy(dx: 0.25, dy: 0.25))
        rim.lineWidth = 0.5
        rim.stroke()
        let cross = NSBezierPath()
        let r: CGFloat = 3.25
        cross.move(to: NSPoint(x: disc.midX - r, y: disc.midY - r)); cross.line(to: NSPoint(x: disc.midX + r, y: disc.midY + r))
        cross.move(to: NSPoint(x: disc.midX + r, y: disc.midY - r)); cross.line(to: NSPoint(x: disc.midX - r, y: disc.midY + r))
        cross.lineWidth = 1.7
        cross.lineCapStyle = .round
        (isEnabled ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor).setStroke()
        cross.stroke()
    }
}
