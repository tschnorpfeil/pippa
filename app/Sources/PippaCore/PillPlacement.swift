import CoreGraphics

/// Where the pill sits: on one display, at a distance from that display's nearest edges.
///
/// The display is chosen only from the saved state, never from the mouse, the key window or
/// `NSScreen.main`, so clicking on another display never moves the pill. If the saved display
/// is missing, the pill shows on the primary display without forgetting its own one; when that
/// display returns, the pill goes back. Pure geometry (AppKit coordinates, y up), so it can be checked.
public enum PillPlacement {
    public struct Display: Equatable, Sendable {
        /// `CGDirectDisplayID` (`NSScreenNumber`).
        public var id: UInt32
        public var name: String
        public var frame: CGRect
        public var visibleFrame: CGRect

        public init(id: UInt32, name: String, frame: CGRect, visibleFrame: CGRect) {
            self.id = id
            self.name = name
            self.frame = frame
            self.visibleFrame = visibleFrame
        }
    }

    /// Saved by a drag (or once for the first default position); nothing else writes it.
    public struct Saved: Equatable, Sendable {
        public var displayID: UInt32
        public var displayName: String
        /// Distances are measured from the right / top edge of the display's frame when set,
        /// otherwise from the left / bottom edge. The frame, not the visible frame: the Dock
        /// moving between displays must not shift the pill.
        public var alignRight: Bool
        public var alignTop: Bool
        public var dx: CGFloat
        public var dy: CGFloat

        public init(displayID: UInt32, displayName: String, alignRight: Bool, alignTop: Bool, dx: CGFloat, dy: CGFloat) {
            self.displayID = displayID
            self.displayName = displayName
            self.alignRight = alignRight
            self.alignTop = alignTop
            self.dx = dx
            self.dy = dy
        }
    }

    /// Index of the display the pill belongs on: the saved one by id, else by unique name
    /// (ids can change when a display reconnects), else the primary display (index 0).
    public static func displayIndex(for saved: Saved, in displays: [Display]) -> Int? {
        guard !displays.isEmpty else { return nil }
        if let i = displays.firstIndex(where: { $0.id == saved.displayID }) { return i }
        let named = displays.indices.filter { !saved.displayName.isEmpty && displays[$0].name == saved.displayName }
        if named.count == 1 { return named[0] }
        return 0
    }

    /// Pill frame for a width on the given display, kept inside its visible frame.
    public static func frame(for saved: Saved, width: CGFloat, height: CGFloat, on display: Display, inset: CGFloat) -> CGRect {
        let f = display.frame
        let x = saved.alignRight ? f.maxX - saved.dx - width : f.minX + saved.dx
        let y = saved.alignTop ? f.maxY - saved.dy - height : f.minY + saved.dy
        return clamp(CGRect(x: x, y: y, width: width, height: height), to: display.visibleFrame, inset: inset)
    }

    /// State to save after the pill was dropped at `frame` on `display`. The side it is
    /// nearer to stays fixed, so a wider label grows away from that edge.
    public static func save(_ frame: CGRect, on display: Display) -> Saved {
        let f = display.frame
        let right = frame.midX > display.visibleFrame.midX
        let top = frame.midY > display.visibleFrame.midY
        return Saved(displayID: display.id, displayName: display.name, alignRight: right, alignTop: top,
                     dx: right ? f.maxX - frame.maxX : frame.minX - f.minX,
                     dy: top ? f.maxY - frame.maxY : frame.minY - f.minY)
    }

    /// First position ever: bottom right of the display the person is working on.
    public static func initial(width: CGFloat, height: CGFloat, on display: Display) -> Saved {
        let vis = display.visibleFrame
        return save(CGRect(x: vis.maxX - 20 - width, y: vis.minY + 20, width: width, height: height), on: display)
    }

    /// Positions saved before the display was stored (absolute screen coordinates).
    public static func migrate(left: CGFloat, right: CGFloat, y: CGFloat, height: CGFloat, in displays: [Display]) -> Saved? {
        let rect = CGRect(x: left, y: y, width: max(1, right - left), height: height)
        guard let i = displayIndex(containing: rect, in: displays) else { return nil }
        return save(rect, on: displays[i])
    }

    /// Display under the middle of a rect, else the one it overlaps most; nil if it overlaps none.
    public static func displayIndex(containing rect: CGRect, in displays: [Display]) -> Int? {
        let mid = CGPoint(x: rect.midX, y: rect.midY)
        if let i = displays.firstIndex(where: { $0.frame.contains(mid) }) { return i }
        var best: (index: Int, area: CGFloat)?
        for (i, d) in displays.enumerated() {
            let r = d.frame.intersection(rect)
            guard !r.isNull, r.width > 0, r.height > 0 else { continue }
            let area = r.width * r.height
            if area > (best?.area ?? 0) { best = (i, area) }
        }
        return best?.index
    }

    public static func clamp(_ r: CGRect, to vis: CGRect, inset i: CGFloat) -> CGRect {
        var r = r
        r.size.height = min(r.height, vis.height - 2 * i)
        r.size.width = min(r.width, vis.width - 2 * i)
        r.origin.x = max(vis.minX + i, min(vis.maxX - r.width - i, r.origin.x))
        r.origin.y = max(vis.minY + i, min(vis.maxY - r.height - i, r.origin.y))
        return r
    }
}
