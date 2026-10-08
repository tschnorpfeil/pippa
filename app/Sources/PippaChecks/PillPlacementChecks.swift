import CoreGraphics
import PippaCore

@MainActor func runPillPlacementChecks() {
    typealias D = PillPlacement.Display
    // Primary left (menu bar 25 pt), external right; the Dock can move between them.
    let built = D(id: 1, name: "Built-in Retina Display", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                  visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 957))
    let external = D(id: 7, name: "LG UltraFine", frame: CGRect(x: 1512, y: -200, width: 2560, height: 1440),
                     visibleFrame: CGRect(x: 1512, y: -200, width: 2560, height: 1415))
    let inset: CGFloat = 8, h: CGFloat = 46
    let dropped = CGRect(x: 3900, y: -150, width: 90, height: h)   // bottom right of the external display
    let saved = PillPlacement.save(dropped, on: external)

    check("Pill placement: the saved display decides, not order or the main display") {
        PillPlacement.displayIndex(for: saved, in: [built, external]) == 1
            && PillPlacement.displayIndex(for: saved, in: [external, built]) == 0
            && PillPlacement.frame(for: saved, width: 90, height: h, on: external, inset: inset) == dropped
    }
    check("Pill placement: the Dock arriving on the pill's display clamps for showing, the saved state stays") {
        var docked = external
        docked.visibleFrame = CGRect(x: 1512, y: -120, width: 2560, height: 1335)
        let f = PillPlacement.frame(for: saved, width: 90, height: h, on: docked, inset: inset)
        return f.minY == -112 && f.minX == dropped.minX && docked.frame.contains(f)
            && PillPlacement.frame(for: saved, width: 90, height: h, on: external, inset: inset) == dropped
    }
    check("Pill placement: display removed → primary display; returned → back to its spot") {
        let gone = PillPlacement.displayIndex(for: saved, in: [built])
        let f = PillPlacement.frame(for: saved, width: 90, height: h, on: built, inset: inset)
        return gone == 0 && built.visibleFrame.contains(f)
            && PillPlacement.displayIndex(for: saved, in: [built, external]) == 1
            && PillPlacement.frame(for: saved, width: 90, height: h, on: external, inset: inset) == dropped
    }
    check("Pill placement: reconnected display with a new id is found by its name") {
        var renumbered = external
        renumbered.id = 99
        var twin = external
        twin.id = 98
        return PillPlacement.displayIndex(for: saved, in: [built, renumbered]) == 1
            && PillPlacement.displayIndex(for: saved, in: [built, renumbered, twin]) == 0
    }
    check("Pill placement: display rearranged → same spot relative to that display") {
        var moved = external
        moved.frame = moved.frame.offsetBy(dx: -4072, dy: 200)
        moved.visibleFrame = moved.visibleFrame.offsetBy(dx: -4072, dy: 200)
        return PillPlacement.frame(for: saved, width: 90, height: h, on: moved, inset: inset) == dropped.offsetBy(dx: -4072, dy: 200)
    }
    check("Pill placement: a wider label grows away from the saved edge and stays on its display") {
        let wide = PillPlacement.frame(for: saved, width: 160, height: h, on: external, inset: inset)
        let left = PillPlacement.save(CGRect(x: 1520, y: -150, width: 90, height: h), on: external)
        let leftWide = PillPlacement.frame(for: left, width: 160, height: h, on: external, inset: inset)
        return saved.alignRight && wide.maxX == dropped.maxX && wide.minX == dropped.maxX - 160
            && !left.alignRight && leftWide.minX == 1520
            && PillPlacement.displayIndex(containing: wide, in: [built, external]) == 1
    }
    check("Pill placement: a pill near the shared edge stays on its display when it widens") {
        let edge = PillPlacement.save(CGRect(x: 1520, y: 400, width: 90, height: h), on: external)
        let f = PillPlacement.frame(for: edge, width: 300, height: h, on: external, inset: inset)
        return !edge.alignRight && f.minX == 1520 && external.frame.contains(f)
    }
    check("Pill placement: first default sits bottom right of the given display") {
        let first = PillPlacement.initial(width: 90, height: h, on: external)
        let f = PillPlacement.frame(for: first, width: 90, height: h, on: external, inset: inset)
        return first.displayID == 7 && f == CGRect(x: 4072 - 110, y: -180, width: 90, height: h)
    }
    check("Pill placement: old absolute positions migrate to their display") {
        let m = PillPlacement.migrate(left: dropped.minX, right: dropped.maxX, y: dropped.minY, height: h, in: [built, external])
        let off = PillPlacement.migrate(left: -5000, right: -4910, y: 0, height: h, in: [built, external])
        return m == saved && off == nil
    }
    check("Pill placement: a rect between displays picks the one it overlaps most") {
        // Middle below the external display's bottom edge, mostly on it.
        let r = CGRect(x: 3000, y: -230, width: 90, height: 46)
        return PillPlacement.displayIndex(containing: r, in: [built, external]) == 1
    }
}
