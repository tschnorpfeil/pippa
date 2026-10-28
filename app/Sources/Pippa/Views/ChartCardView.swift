import AppKit
import Charts
import PippaCore
import SwiftUI
import UniformTypeIdentifiers

/// The marks of a chart card: bars side by side per series, lines, or a ring. Only the card's values, never text
/// from the answer.
struct ChartCanvas: View {
    var card: ChartCard
    private static let seriesKey: String = "series"

    private struct Point: Identifiable {
        let id: Int
        let label: String
        let series: String
        let value: Double
    }

    /// Label by label, so the x axis keeps the card's order (dates in time order) even where a series has a gap.
    private var points: [Point] {
        var out: [Point] = []
        for (index, label) in card.labels.enumerated() {
            for series in card.series where index < series.values.count {
                if let value = series.values[index] { out.append(Point(id: out.count, label: label, series: series.name, value: value)) }
            }
        }
        return out
    }

    /// At most about eight labels under a long line chart; every label when they fit.
    private var axisLabels: [String] {
        let step = max(1, Int((Double(card.labels.count) / 8).rounded(.up)))
        return card.labels.enumerated().filter { $0.offset % step == 0 }.map { $0.element }
    }

    private var legend: Visibility { card.series.count > 1 || card.kind == .pie ? .visible : .hidden }

    var body: some View {
        switch card.kind {
        case .bar: bars
        case .line: lines
        case .pie: pie
        }
    }

    private var bars: some View {
        Chart(points) { p in
            BarMark(x: .value(card.xTitle, p.label), y: .value(p.series, p.value))
                .foregroundStyle(by: .value(Self.seriesKey, p.series))
                .position(by: .value(Self.seriesKey, p.series))
        }
        .chartLegend(legend)
    }

    private var lines: some View {
        Chart(points) { p in
            LineMark(x: .value(card.xTitle, p.label), y: .value(p.series, p.value))
                .foregroundStyle(by: .value(Self.seriesKey, p.series))
        }
        .chartXAxis { AxisMarks(values: axisLabels) }
        .chartLegend(legend)
    }

    private var pie: some View {
        Chart(points) { p in
            SectorMark(angle: .value(p.series, p.value), innerRadius: .ratio(0.5), angularInset: 1)
                .foregroundStyle(by: .value(card.xTitle, p.label))
        }
        .chartLegend(legend)
    }
}

/// A chart Pippa computed from a table file, under the answer: title, chart, what was left out, where it comes from,
/// and "Save as PNG…".
struct ChartCardView: View {
    var card: ChartCard
    private let problemState = State<String?>(initialValue: nil)
    private var problem: String? { get { problemState.wrappedValue } nonmutating set { problemState.wrappedValue = newValue } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: Self.icon(card.kind)).font(.scaled(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text(verbatim: card.title).font(.scaled(size: 15, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityAddTraits(.isHeader)
            ChartCanvas(card: card).frame(height: 220)
            if let note = card.note {
                Text(verbatim: note).font(Fonts.hint).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
            // The button sits with the footer: next to a long title it would not fit at 400 points.
            HStack(alignment: .center, spacing: 0) {
                Text(verbatim: card.footer).font(.scaled(size: 11)).foregroundStyle(Theme.ink3).lineLimit(2)
                Spacer(minLength: 8)
                Button(T("Save as PNG…", table: "Views")) { save() }.pippa(.quiet).fixedSize()
            }
            if let problem {
                Text(problem).font(.scaled(size: 12)).foregroundStyle(Theme.need).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14).resultCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(T("Chart of %@", table: "Views", card.title))
    }

    static func icon(_ kind: ChartCard.Kind) -> String {
        switch kind {
        case .bar: "chart.bar"
        case .line: "chart.xyaxis.line"
        case .pie: "chart.pie"
        }
    }

    /// The chart as a picture on white: 720 points of content plus margins at scale 2, so always 1,536 pixels wide.
    @MainActor static func png(_ card: ChartCard) -> Data? {
        let content = VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: card.title).font(.system(size: 18, weight: .semibold))
            ChartCanvas(card: card).frame(height: 420)
            Text(verbatim: card.footer).font(.system(size: 12))
        }
        .frame(width: 720, alignment: .leading)
        .padding(24)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// "Save as PNG…": choose a place, write the picture there. Like the tray's "Save…" (TrayController.save).
    private func save() {
        NSApp.activate()
        let panel = NSSavePanel()
        let name = Naming.sanitize(card.title)
        panel.nameFieldStringValue = (name.isEmpty ? "Chart" : name) + ".png"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        // State is written only on the main thread (assumeIsolated below).
        nonisolated(unsafe) let problem = problemState
        let data = Self.png(card)
        problem.wrappedValue = nil
        panel.begin { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                do {
                    guard let data else { throw CocoaError(.fileWriteUnknown) }
                    try data.write(to: url, options: .atomic)
                } catch {
                    problem.wrappedValue = T("Couldn’t save the picture. Please try again.", table: "Views")
                }
            }
        }
    }
}
