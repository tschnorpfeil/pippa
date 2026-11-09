import AppKit
import PippaCore
import SwiftUI

/// What the answer read, as chips; a click opens the file or the page.
struct SourceChips: View {
    var sources: [ChatSource]
    private let shown = 3

    var body: some View {
        HStack(spacing: Space.s) {
            ForEach(sources.prefix(shown), id: \.self) { source in SourceChip(source: source) }
            if sources.count > shown {
                Text(verbatim: "+\(sources.count - shown)").font(Typo.caption).monospacedDigit().foregroundStyle(Theme.ink3)
            }
        }
    }

    /// Long names shortened in the middle, so a chip keeps its own width.
    static func short(_ name: String, limit: Int = 30) -> String {
        guard name.count > limit else { return name }
        return name.prefix(limit / 2 - 1) + "…" + name.suffix(limit / 2 - 1)
    }

    static func symbol(_ kind: ChatSource.Kind) -> String {
        switch kind {
        case .file: "doc.text"
        case .mail: "envelope"
        case .web: "globe"
        }
    }

    static func open(_ source: ChatSource) {
        switch source.kind {
        case .file: NSWorkspace.shared.open(URL(fileURLWithPath: source.location))
        case .web: if let url = URL(string: source.location), ["http", "https"].contains(url.scheme) { NSWorkspace.shared.open(url) }
        case .mail: break
        }
    }
}

private struct SourceChip: View {
    var source: ChatSource
    private let hoverState = State(initialValue: false)

    var body: some View {
        Button { SourceChips.open(source) } label: {
            HStack(spacing: 5) {
                Image(systemName: SourceChips.symbol(source.kind)).font(Typo.caption)
                Text(SourceChips.short(source.name)).lineLimit(1)
            }
            .fixedSize()
            .font(Typo.caption).foregroundStyle(hoverState.wrappedValue ? Theme.ink : Theme.ink2)
            .padding(.horizontal, Space.m).frame(height: 24)
            .background(hoverState.wrappedValue ? Theme.rowHover : .clear, in: Capsule())
            .overlay(Capsule(style: .circular).inset(by: 0.5).stroke(Theme.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(source.location.isEmpty)
        .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering && !source.location.isEmpty } }
        .help(source.detail.map { "\(source.name) · \($0)" } ?? source.name)
    }
}
