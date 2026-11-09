import CoreGraphics
import Foundation
import PippaCore

/// Pippa Island's geometry and motion (PippaCore/Island): frames at the notch of two MacBook displays and under a menu
/// bar symbol, hit areas, the spring and the Reduce Motion path. Pure inputs, no windows.
func runIslandChecks() {
    func near(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 0.01) -> Bool { abs(a - b) <= tolerance }

    // Two notched displays as AppKit reports them: 14" (1512×982, housing 185×32) as the main display, 16"
    // (1728×1117) to its right with the auxiliary areas in global coordinates, and the 16" again with screen-relative areas.
    struct Display { let name: String; let screen: CGRect; let left: CGRect; let right: CGRect; let inset: CGFloat }
    let displays = [
        Display(name: "14-inch", screen: CGRect(x: 0, y: 0, width: 1512, height: 982),
                left: CGRect(x: 0, y: 950, width: 663.5, height: 32), right: CGRect(x: 848.5, y: 950, width: 663.5, height: 32), inset: 32),
        Display(name: "16-inch beside it", screen: CGRect(x: 1512, y: -135, width: 1728, height: 1117),
                left: CGRect(x: 1512, y: 950, width: 771.5, height: 32), right: CGRect(x: 2468.5, y: 950, width: 771.5, height: 32), inset: 32),
        Display(name: "16-inch, screen-relative areas", screen: CGRect(x: 1512, y: -135, width: 1728, height: 1117),
                left: CGRect(x: 0, y: 1085, width: 771.5, height: 32), right: CGRect(x: 956.5, y: 1085, width: 771.5, height: 32), inset: 32),
    ]
    for display in displays {
        check("Island: housing of the \(display.name) display is found between the menu bar areas") {
            guard let housing = IslandGeometry.housing(screen: display.screen, leftArea: display.left, rightArea: display.right,
                                                       topInset: display.inset) else { return false }
            return near(housing.width, 185) && near(housing.height, 32) && near(housing.maxY, display.screen.maxY)
                && near(housing.midX, display.screen.midX)
        }
        check("Island: on the \(display.name) display the wing and the panel are centred on the notch and flush with its lower edge") {
            guard let housing = IslandGeometry.housing(screen: display.screen, leftArea: display.left, rightArea: display.right,
                                                       topInset: display.inset) else { return false }
            let placement = IslandPlacement.notch(housing: housing, screen: display.screen)
            let wing = IslandGeometry.compact(placement, width: 120)
            let open = IslandGeometry.open(placement, contentHeight: 240)
            let rest = IslandGeometry.rest(placement)
            return near(wing.midX, housing.midX) && near(wing.minY, housing.minY) && near(wing.maxY, display.screen.maxY)
                && near(wing.width, housing.width + 240)
                && near(open.midX, housing.midX) && near(open.width, IslandGeometry.openWidth)
                && near(open.maxY, display.screen.maxY) && near(open.minY, housing.minY - 240)
                && housing.contains(rest) && near(rest.midX, housing.midX)
        }
    }
    check("Island: a display without a housing (Mac mini, external) has no notch placement") {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        return IslandGeometry.housing(screen: screen, leftArea: nil, rightArea: nil, topInset: 0) == nil
            && IslandGeometry.housing(screen: screen, leftArea: CGRect(x: 0, y: 1056, width: 960, height: 24),
                                      rightArea: CGRect(x: 960, y: 1056, width: 960, height: 24), topInset: 24) == nil
    }
    check("Island: wings stay within their limits and never leave the display") {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let housing = CGRect(x: 663.5, y: 950, width: 185, height: 32)
        let placement = IslandPlacement.notch(housing: housing, screen: screen)
        let narrow = IslandGeometry.compact(placement, width: 4), wide = IslandGeometry.compact(placement, width: 4000)
        return near(narrow.width, 185 + 2 * IslandGeometry.wingWidth.lowerBound)
            && near(wide.width, 185 + 2 * IslandGeometry.wingWidth.upperBound) && screen.contains(wide)
    }

    // 1080p display (this Mac mini): menu bar 24 pt, symbol 30 pt wide.
    let visible = CGRect(x: 0, y: 0, width: 1920, height: 1056)
    for (name, anchor) in [("in the middle", CGRect(x: 1200, y: 1056, width: 30, height: 24)),
                           ("at the right edge", CGRect(x: 1888, y: 1056, width: 30, height: 24)),
                           ("at the left edge", CGRect(x: 0, y: 1056, width: 30, height: 24))] {
        check("Island: under a menu bar symbol \(name), capsule and panel stay in the visible area below the bar") {
            let placement = IslandPlacement.menuBar(anchor: anchor, visible: visible)
            let capsule = IslandGeometry.compact(placement, width: 200)
            let open = IslandGeometry.open(placement, contentHeight: 300)
            let inside = visible.insetBy(dx: IslandGeometry.margin, dy: 0)
            let centred = name != "in the middle" || (near(capsule.midX, anchor.midX) && near(open.midX, anchor.midX))
            return inside.contains(capsule) && inside.contains(open) && centred
                && near(capsule.maxY, visible.maxY - IslandGeometry.menuBarGap) && near(open.maxY, capsule.maxY)
                && near(open.width, IslandGeometry.openWidth) && near(open.height, 300)
        }
    }
    check("Island: a panel taller than the display is cut to the visible area") {
        let placement = IslandPlacement.menuBar(anchor: CGRect(x: 600, y: 776, width: 30, height: 24),
                                                visible: CGRect(x: 0, y: 0, width: 1280, height: 776))
        let open = IslandGeometry.open(placement, contentHeight: 5000)
        return open.minY >= IslandGeometry.margin - 0.01 && open.height > 0
    }

    check("Island: hit areas follow the shape (notch at rest takes a click, the menu bar beside it does not)") {
        let housing = CGRect(x: 663.5, y: 950, width: 185, height: 32)
        let placement = IslandPlacement.notch(housing: housing, screen: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let rest = IslandGeometry.rest(placement)
        let atRest = IslandGeometry.silhouette(placement, from: rest, to: rest, progress: 0)
        let wing = IslandGeometry.silhouette(placement, from: rest, to: IslandGeometry.compact(placement, width: 100), progress: 1)
        return atRest.contains(CGPoint(x: housing.midX, y: housing.midY)) && !atRest.contains(CGPoint(x: housing.minX - 30, y: housing.midY))
            && wing.contains(CGPoint(x: housing.minX - 60, y: housing.midY)) && !wing.contains(CGPoint(x: housing.minX - 60, y: housing.minY - 4))
            && atRest.flare == 0 && wing.flare == IslandGeometry.flare
    }
    check("Island: the silhouette widens before it drops and ends exactly on the open panel") {
        let placement = IslandPlacement.menuBar(anchor: CGRect(x: 1200, y: 1056, width: 30, height: 24), visible: visible)
        let from = IslandGeometry.rest(placement), to = IslandGeometry.open(placement, contentHeight: 300)
        let early = IslandGeometry.silhouette(placement, from: from, to: to, progress: 0.3)
        let end = IslandGeometry.silhouette(placement, from: from, to: to, progress: 1)
        let widthShare = (early.rect.width - from.width) / (to.width - from.width)
        let heightShare = early.rect.height / to.height
        return widthShare > heightShare + 0.1 && end.rect == to && near(end.radius, IslandGeometry.cornerRadius)
            && near(early.rect.maxY, to.maxY)
    }
    check("Island: choreography fades the background in first, then the content, which settles 8 pt") {
        IslandChoreography.backgroundAlpha(0) == 0 && IslandChoreography.backgroundAlpha(0.55) == 1
            && IslandChoreography.contentAlpha(0.55) == 0 && IslandChoreography.contentAlpha(0.95) == 1
            && IslandChoreography.contentDrop(0) == 8 && IslandChoreography.contentDrop(1) == 0
            && IslandChoreography.compactAlpha(0) == 1 && IslandChoreography.compactAlpha(0.35) == 0
    }

    check("Island: the spring reaches its target without overshoot and snaps into place") {
        var spring = IslandSpring()
        spring.retarget(1, IslandSpring.opening)
        var time = 0.0, highest = 0.0
        while !spring.isSettled && time < 2 {
            spring.advance(by: 1.0 / 120)
            time += 1.0 / 120
            highest = max(highest, spring.value)
        }
        return spring.isSettled && spring.value == 1 && spring.velocity == 0 && highest <= 1 && time < 0.6
    }
    check("Island: closing is quicker than opening") {
        func settle(_ target: Double, _ parameters: IslandSpring.Parameters, from start: Double) -> Double {
            var spring = IslandSpring(value: start)
            spring.retarget(target, parameters)
            var time = 0.0
            while !spring.isSettled && time < 2 { spring.advance(by: 1.0 / 120); time += 1.0 / 120 }
            return time
        }
        return settle(0, IslandSpring.closing, from: 1) < settle(1, IslandSpring.opening, from: 0)
    }
    check("Island: a reversal in flight keeps value and velocity and turns back smoothly") {
        var spring = IslandSpring()
        spring.retarget(1, IslandSpring.opening)
        for _ in 0..<12 { spring.advance(by: 1.0 / 120) }
        let value = spring.value, velocity = spring.velocity
        spring.retarget(0, IslandSpring.closing)
        let kept = spring.value == value && spring.velocity == velocity && velocity > 0
        spring.advance(by: 1.0 / 120)
        let continuous = abs(spring.value - value) < 0.1
        var time = 0.0
        while !spring.isSettled && time < 2 { spring.advance(by: 1.0 / 120); time += 1.0 / 120 }
        return kept && value > 0.1 && value < 0.9 && continuous && spring.value == 0
    }
    check("Island: Reduce Motion jumps to the target with no step in between") {
        var spring = IslandSpring()
        spring.move(to: 1, IslandSpring.opening, reduceMotion: true)
        let opened = spring.value == 1 && spring.isSettled
        spring.move(to: 0, IslandSpring.closing, reduceMotion: true)
        var moving = IslandSpring()
        moving.move(to: 1, IslandSpring.opening, reduceMotion: false)
        return opened && spring.value == 0 && spring.isSettled && !moving.isSettled && moving.value == 0
    }
    check("Island: a stalled frame slows the motion instead of jumping") {
        var spring = IslandSpring()
        spring.retarget(1, IslandSpring.opening)
        spring.advance(by: 2)
        return spring.value < 0.6
    }
}
