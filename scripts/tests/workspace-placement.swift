import Foundation

@main
struct PlacementChecks {
    static func main() {
        var checks = 0
        for screen in [CGRect(x: 0, y: 30, width: 1440, height: 850), CGRect(x: -1920, y: 0, width: 1920, height: 1080)] {
            let available = screen.insetBy(dx: 20, dy: 20)
            for x in [available.minX, screen.midX, available.maxX - 100] {
                for y in [available.minY, screen.midY, available.maxY - 36] {
                    let pill = CGRect(x: x, y: y, width: 100, height: 36)
                    let placement = WorkspacePlacement(anchor: pill, visibleFrame: screen, maximumSize: CGSize(width: 800, height: 700), inset: 20)
                    for size in [CGSize(width: 260, height: 130), CGSize(width: 600, height: 440), CGSize(width: 1200, height: 1200)] {
                        let frame = placement.frame(for: size)
                        precondition(available.contains(frame), "Surface escaped visible screen")
                        let expectedX = pill.midX > screen.midX ? pill.maxX - frame.width : pill.minX
                        let expectedY = pill.midY > screen.midY ? pill.maxY - frame.height : pill.minY
                        precondition(frame.minX == max(available.minX, min(expectedX, available.maxX - frame.width)))
                        precondition(frame.minY == max(available.minY, min(expectedY, available.maxY - frame.height)))
                        checks += 1
                    }
                }
            }
            let moved = CGRect(x: screen.midX - 220, y: screen.midY - 150, width: 440, height: 300)
            let manual = WorkspacePlacement(frame: moved, visibleFrame: screen, minimumSize: CGSize(width: 200, height: 150), inset: 20)
            precondition(manual.frame(for: moved.size) == moved, "Manual placement changed")
            let disconnected = WorkspacePlacement(frame: CGRect(x: 5000, y: 5000, width: 440, height: 300), visibleFrame: screen, minimumSize: CGSize(width: 200, height: 150), inset: 20)
            precondition(available.contains(disconnected.frame(for: CGSize(width: 440, height: 300))))
            checks += 2
        }
        print("Workspace placement: \(checks) checks passed")
    }
}
