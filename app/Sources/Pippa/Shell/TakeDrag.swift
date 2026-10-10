import AppKit
import Combine
import PippaCore
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

// Taking: drag an item away from Pippa – into Mail, the Finder, an upload field.
//
// Results (Pippa's file in the cache) go out as a file promise plus file URL (Apple's pattern from
// "Supporting Drag and Drop Through File Promises": Mail and WebKit both find a file that way).
// Given items go out only as a URL to the person's file. Only copying is ever allowed: the Finder
// copies and never moves, the cache file stays for further promises.

/// What a promise carries (read on the write queue, hence Sendable).
struct TakePromise: Sendable {
    let cacheURL: URL
    let name: String
}

/// Shared write queue for all promises (AppKit calls the write there, not on the main thread).
nonisolated(unsafe) private let takeQueue: OperationQueue = {
    let q = OperationQueue()
    q.name = "Pippa.take"
    q.qualityOfService = .utility
    return q
}()

/// File promise that additionally offers the cache file as a file URL.
final class ResultPromiseProvider: NSFilePromiseProvider {
    /// The delegate together with the promise. NSFilePromiseProvider holds its delegate only weakly; here it lives as long as the promise.
    var writer: ResultPromiseWriter?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        if !types.contains(.fileURL) { types.append(.fileURL) }
        return types
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .fileURL, let promise = writer?.promise {
            return (promise.cacheURL as NSURL).pasteboardPropertyList(forType: .fileURL)
        }
        return super.pasteboardPropertyList(forType: type)
    }
}

/// Writes the promised file: a copy of the cache file at the destination (never move). One delegate per promise,
/// so nothing from `userInfo` has to be read off the main thread.
final class ResultPromiseWriter: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let promise: TakePromise

    init(promise: TakePromise) {
        self.promise = promise
        super.init()
    }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        promise.name
    }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                         completionHandler: @escaping (Error?) -> Void) {
        do {
            try FileManager.default.copyItem(at: promise.cacheURL, to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { takeQueue }
}

/// A card that can be dragged away. A real preview lies on a sheet of paper; anything with only an icon
/// (folders, apps, files Quick Look can't draw) stands free as its Finder icon, without paper. Click → `onClick`.
/// Serves the cards at the pill (TrayStackView) and the result in the line (TakeHandle).
class TakeSourceView: NSView {
    /// The item on the card.
    var item: TrayItem? { didSet { if oldValue != item { refreshImage(); updateActions() } } }
    weak var tray: TrayController? { didSet { updateActions() } }
    var onClick: (() -> Void)?
    /// true at the start, false at the end of a drag to the outside.
    var onDragState: ((Bool) -> Void)?
    /// Under the mouse or focused: a deeper shadow (the lift itself is the stack's transform).
    var lifted = false { didSet { if oldValue != lifted { applyLook() } } }
    /// Keyboard focus: an accent ring around the real shape, rotating with it.
    var showsFocusRing = false { didSet { if oldValue != showsFocusRing { applyLook() } } }

    /// Paper (rotated and sprung from outside); `picture` sits inside.
    let paper = CALayer()
    private let picture = CALayer()
    private let ring = CAShapeLayer()
    /// true while only the icon is shown (no paper).
    private(set) var iconOnly = true
    private var downPoint: NSPoint?
    private var dragStarted = false
    private var thumbnailWatch: AnyCancellable?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        paper.cornerRadius = 3
        paper.cornerCurve = .continuous
        paper.shadowColor = NSColor.black.cgColor
        paper.shadowOffset = CGSize(width: 0, height: -1)
        picture.cornerCurve = .continuous
        picture.shadowColor = NSColor.black.cgColor
        paper.addSublayer(picture)
        ring.fillColor = nil
        ring.lineWidth = 2.5
        ring.isHidden = true
        paper.addSublayer(ring)
        layer?.addSublayer(paper)
        placePaper()
        // Comes in the willSet of `revision` (main thread); the new image is already ready then.
        thumbnailWatch = TrayThumbnails.shared.$revision.sink { [weak self] _ in self?.refreshImage() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placePaper()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLook()
    }

    /// Where the icon stands when there is no paper: a square a little wider than the card, centred.
    private var iconRect: CGRect {
        let size = bounds.size
        let side = min(size.width + 6, size.height)
        return CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
    }

    /// Top right corner of what is actually visible (sheet or opaque part of the icon), in own coordinates.
    var visibleCorner: CGPoint {
        guard iconOnly, let item else { return CGPoint(x: bounds.maxX, y: bounds.maxY) }
        let unit = TrayThumbnails.shared.opaqueBounds(for: item)
        let r = iconRect
        return CGPoint(x: r.minX + unit.maxX * r.width, y: r.minY + unit.maxY * r.height)
    }

    private func placePaper() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = bounds.size
        paper.bounds = CGRect(origin: .zero, size: size)
        paper.position = CGPoint(x: size.width / 2, y: size.height / 2)
        layoutContent()
        CATransaction.commit()
    }

    private func layoutContent() {
        if iconOnly {
            picture.frame = iconRect
            paper.shadowPath = nil
        } else {
            picture.frame = paper.bounds.insetBy(dx: 2, dy: 2)
            paper.shadowPath = CGPath(roundedRect: paper.bounds, cornerWidth: 3, cornerHeight: 3, transform: nil)
        }
        let shape: CGRect
        if iconOnly, let item {
            let unit = TrayThumbnails.shared.opaqueBounds(for: item)
            let r = iconRect
            shape = CGRect(x: r.minX + unit.minX * r.width, y: r.minY + unit.minY * r.height,
                           width: unit.width * r.width, height: unit.height * r.height)
        } else {
            shape = paper.bounds
        }
        let outline = shape.insetBy(dx: -3.5, dy: -3.5)
        ring.path = CGPath(roundedRect: outline, cornerWidth: iconOnly ? 6 : 5, cornerHeight: iconOnly ? 6 : 5, transform: nil)
    }

    /// Colours and shadows for sheet or free icon, at rest or lifted (resolved for the current appearance).
    private func applyLook() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if iconOnly {
                paper.backgroundColor = nil
                paper.borderWidth = 0
                paper.shadowOpacity = 0
                picture.masksToBounds = false
                picture.cornerRadius = 0
                picture.shadowOpacity = lifted ? 0.28 : 0.22
                picture.shadowRadius = lifted ? 3 : 1.5
                picture.shadowOffset = CGSize(width: 0, height: lifted ? -3 : -1)
            } else {
                paper.backgroundColor = NSColor.white.cgColor
                paper.borderWidth = 0.5
                paper.borderColor = NSColor(white: 0, alpha: 0.09).cgColor
                paper.shadowOpacity = lifted ? 0.3 : 0.22
                paper.shadowRadius = lifted ? 5 : 2.5
                paper.shadowOffset = CGSize(width: 0, height: lifted ? -4 : -1)
                picture.masksToBounds = true
                picture.cornerRadius = 1.5
                picture.shadowOpacity = 0
            }
            ring.strokeColor = NSColor.keyboardFocusIndicatorColor.withAlphaComponent(1).cgColor
        }
        ring.isHidden = !showsFocusRing
        CATransaction.commit()
    }

    /// Set the thumbnail anew. A finished preview goes on paper (fading in briefly); an icon stands free.
    func refreshImage() {
        guard let item else { return }
        let thumbs = TrayThumbnails.shared
        let image = thumbs.image(for: item)
        let real = thumbs.hasImage(for: item)
        let becomesPaper = iconOnly && real && picture.contents != nil
        if becomesPaper && !MarkHub.shared.reduced {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.15
            paper.add(fade, forKey: "paper")
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        iconOnly = !real
        picture.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        picture.contentsGravity = real ? .resizeAspectFill : .resizeAspect
        picture.contents = image
        layoutContent()
        CATransaction.commit()
        applyLook()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint, !dragStarted, let item else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) >= 4 else { return }
        dragStarted = true
        beginTake(item, event: event)
    }

    override func mouseUp(with event: NSEvent) {
        let clicked = downPoint != nil && !dragStarted
        downPoint = nil
        dragStarted = false
        if clicked { onClick?() }
    }

    private func beginTake(_ item: TrayItem, event: NSEvent) {
        let dragItem = NSDraggingItem(pasteboardWriter: Self.writer(for: item))
        dragItem.setDraggingFrame(bounds, contents: TrayThumbnails.shared.image(for: item))
        onDragState?(true)
        let session = beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    /// Result: promise (+ file URL). Given: only the URL of the person's file.
    static func writer(for item: TrayItem) -> any NSPasteboardWriting {
        guard item.role == .result else { return item.url as NSURL }
        let ext = item.url.pathExtension
        let type = (ext.isEmpty ? nil : UTType(filenameExtension: ext))?.identifier ?? UTType.data.identifier
        let writer = ResultPromiseWriter(promise: TakePromise(cacheURL: item.url, name: item.name))
        let provider = ResultPromiseProvider(fileType: type, delegate: writer)
        provider.writer = writer
        return provider
    }

    fileprivate func dragEnded(_ operation: NSDragOperation) {
        downPoint = nil
        dragStarted = false
        onDragState?(false)
        guard operation != [], let item else { return }
        tray?.took(item.id, target: .dragged)
    }

    // MARK: VoiceOver

    /// What VoiceOver says: "Scans 06.10.2026.pdf, done" / "Rechnung.pdf, from Downloads".
    nonisolated static func spokenName(_ item: TrayItem) -> String {
        if item.role == .result { return T("%@, ready", table: "Shelf", item.name) }
        if let origin = item.origin, !origin.isEmpty { return T("%1$@, from %2$@", table: "Shelf", item.name, origin) }
        return item.name
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? {
        MainActor.assumeIsolated { item.map { TakeSourceView.spokenName($0) } }
    }
    override func accessibilityHelp() -> String? {
        T("Click to see what I can do with it. Drag it to where you need it.", table: "Shelf")
    }
    override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated {
            guard let onClick else { return false }
            onClick()
            return true
        }
    }

    /// "Save…" as a VoiceOver action. Assigned rather than overridden: the actions aren't Sendable values.
    private func updateActions() {
        guard let id = item?.id, tray != nil else {
            setAccessibilityCustomActions(nil)
            return
        }
        let save = NSAccessibilityCustomAction(name: T("Save…", table: "Shelf")) { [weak self] in
            MainActor.assumeIsolated {
                guard let tray = self?.tray else { return false }
                tray.save(id)
                return true
            }
        }
        setAccessibilityCustomActions([save])
    }
}

extension TakeSourceView: @preconcurrency NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragEnded(operation)
    }
}

/// The same drag source for SwiftUI: the result in the line, to drag away.
struct TakeHandle: NSViewRepresentable {
    var item: TrayItem
    var tray: TrayController
    var size: CGSize

    func makeNSView(context: Context) -> TakeSourceView {
        let view = TakeSourceView(frame: CGRect(origin: .zero, size: size))
        view.tray = tray
        view.item = item
        view.onClick = { [weak view] in
            guard let view, let item = view.item, item.role == .result else { return }
            view.tray?.showResult(item.id)
        }
        return view
    }

    func updateNSView(_ view: TakeSourceView, context: Context) {
        view.tray = tray
        if view.item != item { view.item = item }
        if view.frame.size != size { view.setFrameSize(size) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TakeSourceView, context: Context) -> CGSize? {
        size
    }
}
