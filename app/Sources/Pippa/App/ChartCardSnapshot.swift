import AppKit
import PiRPC
import PippaCore
import SwiftUI

#if DEBUG
/// The chart card at 400 points and its PNG export, from a synthetic table. No save panel, model or personal file.
@MainActor enum ChartCardSnapshot {
    static func run(directory: URL) async -> [String] {
        var checks: [String] = []
        func check(_ value: Bool, _ name: String) { checks.append("\(value ? "PASS" : "FAIL"): chart card \(name)") }
        let grid = SheetGrid(rows: [
            [SheetCell(.text("Monat")), SheetCell(.text("Miete")), SheetCell(.text("Strom und Heizung im Mehrfamilienhaus"))],
            [SheetCell(.text("Januar")), SheetCell(.number(980)), SheetCell(.number(142.5))],
            [SheetCell(.text("Februar")), SheetCell(.number(980)), SheetCell(.number(131.2))],
            [SheetCell(.text("März")), SheetCell(.number(980)), SheetCell(.text("98,40 €"))],
            [SheetCell(.text("April")), SheetCell(.number(1010)), SheetCell()],
            [SheetCell(.text("Summe")), SheetCell(.number(3950)), SheetCell(.number(372.1))],
        ])
        guard case .success(let card) = ChartBuilder.build(grid, x: "Monat", y: ["Miete", "Strom"], aggregate: .sum, kind: .bar,
                                                           source: "Haushaltsbuch 2026.xlsx") else {
            check(false, "builds from the fixture table"); return checks
        }
        check(card.labels == ["Januar", "Februar", "März", "April"] && card.series.count == 2 && card.note != nil,
              "computes the fixture without the total row and notes the missing number")
        var receipt = PiTurnReceipt()
        receipt.observe(.toolStarted(id: "chart-fixture", name: "mcp__pippa__make_chart", arguments: "{}"))
        receipt.observe(.toolEnded(id: "chart-fixture", name: "mcp__pippa__make_chart", isError: false, result: "{}"))
        let note = PippaMCPReadNote(tool: PippaMCPChart.name, read: true, line: "Chart: Haushaltsbuch 2026.xlsx", card: .chart(card))
        let mapped = PiRPCChat.actions(receipt, reads: [note])
        check(mapped?.cards == [.chart(card)] && mapped?.items.count == 1 && mapped?.items.first?.action == "read"
              && mapped?.items.first?.outcome == "done", "survives the production chat mapping as a read with its card")
        await render(card, name: "chart-card", directory: directory, checks: &checks)
        if let png = ChartCardView.png(card), let image = NSBitmapImageRep(data: png) {
            do {
                try png.write(to: directory.appendingPathComponent("chart-export.png"))
                checks.append("PASS: chart-export captured")
            } catch { checks.append("FAIL: chart-export capture file") }
            check(image.pixelsWide == 1536, "export is 1536 pixels wide (\(image.pixelsWide))")
        } else {
            checks.append("FAIL: chart-export renders")
        }
        return checks
    }

    /// Like PreparedFilesCardSnapshot.render: the card at 400 points in a window, captured as PNG.
    private static func render(_ card: ChartCard, name: String, directory: URL, checks: inout [String]) async {
        let host = NSHostingView(rootView: ChartCardView(card: card).padding(12).frame(width: 400).background(Theme.paper))
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        panel.contentView = host; panel.makeKeyAndOrderFront(nil)
        defer { panel.orderOut(nil) }
        try? await Task.sleep(for: .milliseconds(200))
        let size = host.fittingSize
        checks.append("\(size.width <= 400.5 && size.height < 700 ? "PASS" : "FAIL"): \(name) fits 400 points")
        host.frame = NSRect(x: 0, y: 0, width: 400, height: ceil(size.height)); panel.setContentSize(host.frame.size)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { checks.append("FAIL: \(name) renders"); return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { checks.append("FAIL: \(name) capture"); return }
        do { try png.write(to: directory.appendingPathComponent(name + ".png")); checks.append("PASS: \(name) captured") }
        catch { checks.append("FAIL: \(name) capture file") }
    }
}
#endif
