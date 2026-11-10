import CoreGraphics

/// Where Pippa Island lives on a display. Global AppKit coordinates (origin bottom left, y up).
public enum IslandPlacement: Equatable, Sendable {
    /// Hanging from the camera housing: `housing` is its bounding box, `screen` the display's frame.
    case notch(housing: CGRect, screen: CGRect)
    /// Under the menu bar symbol `anchor`, kept inside `visible` (the display's `visibleFrame`).
    case menuBar(anchor: CGRect, visible: CGRect)

    public var isNotch: Bool { if case .notch = self { true } else { false } }
}

/// The black shape at one moment: a rectangle with rounded lower corners. At the notch it is flush with the top of
/// the display and meets the menu bar with concave flares; under the menu bar symbol it floats with four round corners.
public struct IslandSilhouette: Equatable, Sendable {
    public var rect: CGRect
    public var radius: CGFloat
    /// Width of the concave flares beside the top edge (notch only, 0 while the shape is inside the housing).
    public var flare: CGFloat
    public var hangsFromTop: Bool

    /// The outline in global coordinates; `offset` moves it into a window (pass the window origin).
    public func path(offset: CGPoint = .zero) -> CGPath {
        let r = rect.offsetBy(dx: -offset.x, dy: -offset.y)
        let path = CGMutablePath()
        guard r.width > 0.01, r.height > 0.01 else { return path }
        let radius = min(radius, r.width / 2, r.height / 2)
        guard hangsFromTop else {
            path.addRoundedRect(in: r, cornerWidth: radius, cornerHeight: radius)
            return path
        }
        let f = min(flare, r.height / 2)
        path.move(to: CGPoint(x: r.minX - f, y: r.maxY))
        path.addLine(to: CGPoint(x: r.maxX + f, y: r.maxY))
        if f > 0.01 {
            path.addArc(center: CGPoint(x: r.maxX + f, y: r.maxY - f), radius: f, startAngle: .pi / 2, endAngle: .pi, clockwise: false)
        }
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + radius))
        if radius > 0.01 {
            path.addArc(center: CGPoint(x: r.maxX - radius, y: r.minY + radius), radius: radius, startAngle: 0, endAngle: -.pi / 2, clockwise: true)
        }
        path.addLine(to: CGPoint(x: r.minX + radius, y: r.minY))
        if radius > 0.01 {
            path.addArc(center: CGPoint(x: r.minX + radius, y: r.minY + radius), radius: radius, startAngle: -.pi / 2, endAngle: -.pi, clockwise: true)
        }
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY - f))
        if f > 0.01 {
            path.addArc(center: CGPoint(x: r.minX - f, y: r.maxY - f), radius: f, startAngle: 0, endAngle: .pi / 2, clockwise: false)
        }
        path.closeSubpath()
        return path
    }

    /// Hit area: inside the shape, flares excluded.
    public func contains(_ point: CGPoint) -> Bool { path().contains(point) && rect.contains(point) }
}

/// Frames of Pippa Island. Pure functions of the display's public geometry (`NSScreen.frame`, `safeAreaInsets.top`,
/// `auxiliaryTopLeftArea`, `auxiliaryTopRightArea`, `visibleFrame`) and the menu bar symbol, so checks can run them
/// for any Mac. Three resting shapes: `rest` (Pippa's mark just left of the housing, or nothing), `compact` (a wing on
/// the left of the housing, or a small capsule under the symbol) and `open` (the panel).
///
/// At the notch Pippa keeps to the left of the housing: tools like tinyStats live on its right, and the menu bar
/// symbols there should stay readable. The shapes reach into the housing up to 6 pt from its right edge: there they
/// stay hidden in the camera cutout (their corner curves up before the housing's does), and a click anywhere on the
/// notch still opens the island. Open, the panel is centred on the housing unless another notch tool shows right of
/// it (`toolRightOfHousing`); then it, too, ends on the housing's right edge.
public enum IslandGeometry {
    public static let openWidth: CGFloat = 380
    public static let cornerRadius: CGFloat = 22
    public static let wingRadius: CGFloat = 10
    public static let flare: CGFloat = 6
    /// Distance to the display's edges.
    public static let margin: CGFloat = 8
    /// Between the menu bar and a floating island.
    public static let menuBarGap: CGFloat = 6
    public static let capsuleHeight: CGFloat = 28
    /// Width of the wing left of the housing.
    public static let wingWidth: ClosedRange<CGFloat> = 40...260
    /// At rest at the notch: just Pippa's mark, left of the housing.
    public static let earWidth: CGFloat = 40
    public static let capsuleMaxWidth: CGFloat = 300

    /// The camera housing's bounding box, or nil on a display without one. The auxiliary areas are the menu bar parts
    /// left and right of the housing; AppKit reports them in global coordinates, some displays relative to the screen,
    /// so both are accepted.
    public static func housing(screen: CGRect, leftArea: CGRect?, rightArea: CGRect?, topInset: CGFloat) -> CGRect? {
        guard var left = leftArea, var right = rightArea, !left.isEmpty, !right.isEmpty, !screen.isEmpty,
              topInset.isFinite, topInset >= 16 else { return nil }
        if abs(left.maxY - screen.maxY) > 0.5, abs(left.maxY - screen.height) <= 0.5 {
            left = left.offsetBy(dx: screen.minX, dy: screen.minY)
            right = right.offsetBy(dx: screen.minX, dy: screen.minY)
        }
        guard abs(left.maxY - screen.maxY) <= 0.5, abs(right.maxY - screen.maxY) <= 0.5,
              left.minX >= screen.minX - 0.5, right.maxX <= screen.maxX + 0.5,
              right.minX - left.maxX >= 40 else { return nil }
        return CGRect(x: left.maxX, y: screen.maxY - topInset, width: right.minX - left.maxX, height: topInset)
    }

    /// Lower edge a floating island hangs from: just below the menu bar (the symbol is shorter than the bar).
    static func attachY(anchor: CGRect, visible: CGRect) -> CGFloat {
        min(anchor.minY, visible.maxY) - menuBarGap
    }

    /// At rest: Pippa's mark left of the housing (it takes a click there and on the notch); under the menu
    /// bar, a line with no height under the symbol.
    public static func rest(_ placement: IslandPlacement) -> CGRect {
        switch placement {
        case .notch:
            return compact(placement, width: earWidth)
        case .menuBar(let anchor, let visible):
            let x = min(max(anchor.minX, visible.minX + margin), visible.maxX - margin - anchor.width)
            return CGRect(x: x, y: attachY(anchor: anchor, visible: visible), width: anchor.width, height: 0)
        }
    }

    /// Working, needs you, done: `width` is the wing's width left of the housing at the notch, the whole capsule under
    /// the menu bar. The wing ends inside the housing, where no corner of it can show.
    public static func compact(_ placement: IslandPlacement, width: CGFloat) -> CGRect {
        switch placement {
        case .notch(let housing, let screen):
            let wing = min(max(width, wingWidth.lowerBound), wingWidth.upperBound, max(0, housing.minX - screen.minX - margin))
            return CGRect(x: housing.minX - wing, y: housing.minY, width: wing + housing.width - 6, height: housing.height)
        case .menuBar(let anchor, let visible):
            let width = min(max(width, capsuleHeight), capsuleMaxWidth, visible.width - 2 * margin)
            let top = attachY(anchor: anchor, visible: visible)
            return CGRect(x: clampedX(center: anchor.midX, width: width, in: visible), y: top - capsuleHeight,
                          width: width, height: capsuleHeight)
        }
    }

    /// The open panel, `contentHeight` tall below the housing (or below the menu bar). At the notch it is centred on
    /// the housing, unless `besideTool`: another notch tool (like tinyStats) shows right of the housing, and the panel
    /// then ends on the housing's right edge, leaving that tool alone. Either way the row beside the housing holds
    /// Pippa's mark and name.
    public static func open(_ placement: IslandPlacement, contentHeight: CGFloat, besideTool: Bool = false) -> CGRect {
        switch placement {
        case .notch(let housing, let screen):
            let width = min(openWidth, screen.width - 2 * margin)
            let height = housing.height + max(0, contentHeight)
            guard besideTool else {
                return CGRect(x: clampedX(center: housing.midX, width: width, in: screen), y: screen.maxY - height,
                              width: width, height: height)
            }
            let x = min(max(housing.maxX - width, screen.minX + margin), screen.maxX - margin - width)
            return CGRect(x: x, y: screen.maxY - height, width: width, height: height)
        case .menuBar(let anchor, let visible):
            let width = min(openWidth, visible.width - 2 * margin)
            let top = attachY(anchor: anchor, visible: visible)
            let height = min(max(0, contentHeight), max(0, top - visible.minY - margin))
            return CGRect(x: clampedX(center: anchor.midX, width: width, in: visible), y: top - height,
                          width: width, height: height)
        }
    }

    /// Whether another app's window (global AppKit frames of on-screen windows at menu bar level or above, none of
    /// Pippa's) is a notch tool right of the housing: it hangs from the top of the display, starts in the housing or right
    /// at its edge as notch tools do, and continues to its right. Menu bar symbols keep a gap to the housing; overlays as
    /// wide as half the display are no notch tool.
    public static func toolRightOfHousing(_ placement: IslandPlacement, windows: [CGRect]) -> Bool {
        guard case .notch(let housing, let screen) = placement else { return false }
        return windows.contains { w in
            abs(w.maxY - screen.maxY) <= 2 && w.width < screen.width / 2
                && w.minX <= housing.maxX + 2 && w.maxX > housing.maxX + 8
        }
    }

    private static func clampedX(center: CGFloat, width: CGFloat, in bounds: CGRect) -> CGFloat {
        let low = bounds.minX + margin, high = bounds.maxX - margin - width
        return min(max((center - width / 2).rounded(), low), max(low, high))
    }

    /// The shape between `from` (rest or compact) and `to` (compact or open) at `progress` 0...1. Width leads height
    /// (`IslandChoreography.widthProgress`); the top edge stays where both shapes have it.
    public static func silhouette(_ placement: IslandPlacement, from: CGRect, to: CGRect, progress: CGFloat) -> IslandSilhouette {
        let p = min(max(progress, 0), 1)
        let w = IslandChoreography.widthProgress(p)
        func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
        let minX = mix(from.minX, to.minX, w), maxX = mix(from.maxX, to.maxX, w)
        let maxY = mix(from.maxY, to.maxY, p), minY = mix(from.minY, to.minY, p)
        let rect = CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
        switch placement {
        case .notch(let housing, _):
            func radius(_ r: CGRect) -> CGFloat { r.height > housing.height + 1 ? cornerRadius : wingRadius }
            // The flare beside the left edge; the right one lies inside the housing until the panel opens.
            let flare = max(0, min(Self.flare, housing.minX - rect.minX, rect.maxX - housing.minX))
            return IslandSilhouette(rect: rect, radius: mix(radius(from), radius(to), p), flare: flare, hangsFromTop: true)
        case .menuBar:
            return IslandSilhouette(rect: rect, radius: min(cornerRadius, rect.height / 2, rect.width / 2), flare: 0, hangsFromTop: false)
        }
    }

    /// One window large enough for every shape in `rects` (and the flares beside them), in whole points.
    public static func windowFrame(_ placement: IslandPlacement, covering rects: [CGRect]) -> CGRect {
        let union = rects.dropFirst().reduce(rects.first ?? .zero) { $0.union($1) }
        let outset = placement.isNotch ? flare : 0
        let minX = (union.minX - outset).rounded(.down), maxX = (union.maxX + outset).rounded(.up)
        let minY = union.minY.rounded(.down), maxY = union.maxY.rounded(.up)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: max(1, maxY - minY))
    }
}
