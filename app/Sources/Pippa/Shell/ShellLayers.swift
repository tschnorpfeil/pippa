import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Borderless panel: the pill stays passive, an open conversation takes keyboard focus.
final class ShellPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

// MARK: - Stage
//
// The shell is ONE view in a transparent panel covering the whole screen.
// The window never moves; only Core Animation springs deform the shell (frame, corners,
// shadow, mark) in the render server. No layout runs per frame. Empty areas let clicks through.

/// Root of the stage. Hit-tests only inside the shell (and on the cards behind it).
final class StageView: NSView {
    weak var controller: ShellController?
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let controller, controller.hits(point) else { return nil }
        return super.hitTest(point)
    }
}

/// Shadow only outside the shape (even-odd mask) so the glass doesn't turn grey.
final class ShadowView: NSView {
    private let group = CALayer()
    /// Soft falloff.
    let shadowLayer = CALayer()
    /// Fine contour right at the edge.
    let contour = CALayer()
    let cutout = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        for l in [shadowLayer, contour] {
            l.shadowColor = ShellTokens.shadowColor.cgColor
            group.addSublayer(l)
        }
        shadowLayer.shadowRadius = ShellTokens.shadowRadius
        shadowLayer.shadowOffset = ShellTokens.shadowOffset
        contour.shadowRadius = 0.6
        contour.shadowOffset = .zero
        cutout.fillRule = .evenOdd
        cutout.fillColor = NSColor.black.cgColor
        group.mask = cutout
        layer?.addSublayer(group)
        setAppearance(dark: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setAppearance(dark: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.shadowColor = (dark ? NSColor.black : ShellTokens.shadowColor).cgColor
        contour.shadowColor = (dark ? NSColor.black : ShellTokens.shadowColor).cgColor
        shadowLayer.shadowOpacity = dark ? ShellTokens.shadowOpacityDark : ShellTokens.shadowOpacity
        contour.shadowOpacity = dark ? ShellTokens.contourOpacityDark : ShellTokens.contourOpacity
        CATransaction.commit()
    }

    func setShape(_ path: CGPath) {
        shadowLayer.shadowPath = path
        contour.shadowPath = path
    }

    func animateShape(_ make: () -> CAAnimation) {
        shadowLayer.add(make(), forKey: "shadowPath")
        contour.add(make(), forKey: "shadowPath")
    }

    func removeAnimations() {
        for l in [shadowLayer, contour, cutout] { l.removeAllAnimations() }
    }

    func fit() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        group.frame = bounds
        for l in [shadowLayer, contour, cutout] { l.frame = bounds }
        CATransaction.commit()
    }
}

/// Glass tint over the material (board: hint of sage, light .74 / dark .70; sheet more opaque).
final class TintView: NSView {
    var conversation = false { didSet { needsDisplay = true; updateLayer() } }
    var solid = false { didSet { needsDisplay = true; updateLayer() } }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (conversation ? Theme.chatTint : solid ? Theme.materialTintSolid : Theme.materialTint).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Accepts dropped files and passes them on to the shell (shape and pill).
class ShellDropView: NSView {
    weak var controller: ShellController?
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { controller?.draggingEntered() ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { controller?.canDrop == true ? .copy : [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.draggingExited() }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { controller?.canDrop == true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { controller?.performDrop(sender.draggingPasteboard) ?? false }
}

/// The shape: clips glass and content to the rounded contour (continuous corners).
final class ClipView: ShellDropView {
    override var isFlipped: Bool { false }
}

/// Interior in fixed screen coordinates: moves opposite to the shape so glass
/// and content stay still while deforming and only the contour moves.
final class InnerView: NSView {
    override var isFlipped: Bool { false }
}

/// Root of the content with fade-in control and coordinate space for the mark.
struct ShellHostRoot: View {
    @ObservedObject var model: AppModel
    @ObservedObject var reveal: RevealState

    var body: some View {
        TextScaleRoot {
            ShellRootView(model: model, frozen: reveal.frozen)
                .environment(\.reveal, reveal)
                .coordinateSpace(name: "shell")
        }
    }
}

/// Measuring pass: size of the content and the mark's slot within it.
struct MeasureRoot: View {
    var model: AppModel
    var fixed: CGSize?
    var box: MeasureBox

    var body: some View {
        Group {
            if let fixed {
                ShellContentView(model: model, measuring: true).frame(width: fixed.width, height: fixed.height)
            } else {
                ShellContentView(model: model, measuring: true)
            }
        }
        .coordinateSpace(name: "shell")
        .onPreferenceChange(MarkSlotKey.self) { rect in box.set(rect) }
    }
}

final class MeasureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var rect: CGRect = .null
    func set(_ r: CGRect) { lock.withLock { rect = r } }
    var value: CGRect { lock.withLock { rect } }
}
