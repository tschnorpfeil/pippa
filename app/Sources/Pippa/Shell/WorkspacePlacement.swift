import Foundation
import CoreGraphics

/// Sizes are bounded by available room; each actual surface is anchored to the invoking pill.
struct WorkspacePlacement {
    let visibleFrame: CGRect
    let bounds: CGRect
    private let anchor: CGRect?
    private let inset: CGFloat

    init(anchor: CGRect, visibleFrame: CGRect, maximumSize: CGSize, inset: CGFloat) {
        self.visibleFrame = visibleFrame
        self.inset = inset
        self.anchor = anchor
        let available = visibleFrame.insetBy(dx: inset, dy: inset)
        let size = CGSize(width: min(maximumSize.width, available.width),
                          height: min(maximumSize.height, available.height))
        let right = anchor.midX > visibleFrame.midX
        let below = anchor.midY > visibleFrame.midY
        let x = right ? anchor.maxX - size.width : anchor.minX
        let y = below ? anchor.maxY - size.height : anchor.minY
        bounds = CGRect(x: max(available.minX, min(x, available.maxX - size.width)),
                        y: max(available.minY, min(y, available.maxY - size.height)),
                        width: size.width, height: size.height)
    }

    /// Moved or resized by the person: this frame, brought onto the screen.
    init(frame: CGRect, visibleFrame: CGRect, minimumSize: CGSize, inset: CGFloat) {
        self.visibleFrame = visibleFrame
        self.inset = inset
        self.anchor = nil
        let available = visibleFrame.insetBy(dx: inset, dy: inset)
        let size = CGSize(width: min(max(frame.width, minimumSize.width), available.width),
                          height: min(max(frame.height, minimumSize.height), available.height))
        bounds = CGRect(x: max(available.minX, min(frame.minX, available.maxX - size.width)),
                        y: max(available.minY, min(frame.maxY - size.height, available.maxY - size.height)),
                        width: size.width, height: size.height)
    }

    func frame(for size: CGSize) -> CGRect {
        let width = min(ceil(size.width), bounds.width)
        let height = min(ceil(size.height), bounds.height)
        guard let anchor else {
            return CGRect(x: bounds.minX, y: bounds.maxY - height, width: width, height: height)
        }
        let available = visibleFrame.insetBy(dx: inset, dy: inset)
        let x = anchor.midX > visibleFrame.midX ? anchor.maxX - width : anchor.minX
        let y = anchor.midY > visibleFrame.midY ? anchor.maxY - height : anchor.minY
        return CGRect(x: max(available.minX, min(x, available.maxX - width)),
                      y: max(available.minY, min(y, available.maxY - height)), width: width, height: height)
    }
}
