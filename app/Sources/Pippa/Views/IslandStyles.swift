import SwiftUI

/// Capsule buttons that read on black: quiet, or the one primary action in Pippa's blue with white text.
struct IslandButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(IslandStyle.detail)
            .lineLimit(1)
            .foregroundStyle(prominent ? Color.white : IslandStyle.white(IslandStyle.primary))
            .padding(.horizontal, IslandStyle.gap)
            .frame(height: IslandStyle.controlHeight)
            .background(Capsule().fill(prominent ? IslandStyle.accentFill.opacity(configuration.isPressed ? 0.8 : 1)
                                                 : IslandStyle.white(configuration.isPressed ? 0.24 : 0.14)))
            .contentShape(Capsule())
            .fixedSize()
    }
}

/// One choice of a question: a full-width row in the island's quiet well, lighter under the pointer, in up to two
/// lines.
struct IslandChoiceStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IslandChoiceRow(configuration: configuration)
    }

    private struct IslandChoiceRow: View {
        let configuration: Configuration
        private let hoverState = State(initialValue: false)

        var body: some View {
            configuration.label
                .font(IslandStyle.small)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(IslandStyle.white(IslandStyle.primary))
                .frame(maxWidth: .infinity, minHeight: IslandStyle.controlHeight, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: IslandStyle.wellRadius, style: .continuous)
                    .fill(IslandStyle.white(configuration.isPressed ? 0.22 : hoverState.wrappedValue ? 0.16 : 0.08)))
                .contentShape(RoundedRectangle(cornerRadius: IslandStyle.wellRadius, style: .continuous))
                .onHover { hoverState.wrappedValue = $0 }
        }
    }
}

extension View {
    /// A text field's quiet well on the island, as tall as the buttons beside it.
    func islandWell() -> some View {
        padding(.horizontal, 10)
            .frame(height: IslandStyle.controlHeight)
            .background(RoundedRectangle(cornerRadius: IslandStyle.wellRadius, style: .continuous).fill(IslandStyle.white(0.1)))
    }
}
