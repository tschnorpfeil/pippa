import SwiftUI

// The settings window's look: the chat's background, groups like the chat's cards, one small set of type sizes.
// Roles: row title 13 (`Typo.callout`), explanation and status 12 in `Theme.ink2` (`Typo.footnote`), section title 13
// semibold. Switches, pop-up buttons and text fields stay macOS controls.

/// One page: a scroll view of sections on the chat's background. It scrolls only when the page is taller than the screen.
struct SettingsScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) { content }
                .padding(Space.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .font(Typo.callout)
        .foregroundStyle(Theme.ink)
        .background(Color(nsColor: Theme.chatTint))
    }
}

/// A group of rows with its title above it and, if given, a sentence below it. The group is the only surface: rows are
/// separated by `SettingsDivider`, never boxed again.
struct SettingsSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let title {
                Text(title).font(Typo.callout.weight(.semibold)).foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, Space.xl).padding(.vertical, Space.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.chatCard, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1) }
            if let footer { SettingsNote(footer) }
        }
    }
}

/// The line between two rows of a group.
struct SettingsDivider: View {
    var body: some View { Rectangle().fill(Theme.hairline).frame(height: 1) }
}

/// An explanation: 12 pt, `ink2`.
struct SettingsNote: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Typo.footnote).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
    }
}

/// A status: a sign (green check for "Connected", "Ready") and the words, 12 pt. The colour is never the only signal.
struct SettingsStatus: View {
    var symbol: String
    var color: Color
    var text: String
    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            Text(text).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .font(Typo.footnote)
        .accessibilityElement(children: .combine)
    }
}

/// Calm pill marking Pi's recommended model for a provider.
struct RecommendedBadge: View {
    var body: some View {
        Text(T("Recommended", table: "Settings"))
            .font(Typo.caption.weight(.medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.xxs)
            .background(Theme.accentTint, in: Capsule())
            .fixedSize()
    }
}

/// Visual 3-step summary shown before online sign-in: where typed text goes, what stays gated, and how to switch back.
struct OnlineDataFlowStrip: View {
    var providerName: String?

    private var destination: String {
        providerName ?? T("Chosen provider", table: "Settings")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                flowNode(symbol: "laptopcomputer", label: T("This Mac", table: "Settings"))
                flowConnector
                Image(systemName: "lock.fill")
                    .font(Typo.caption)
                    .foregroundStyle(Theme.ink3)
                flowConnector
                flowNode(symbol: "cloud", label: destination)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(T("Data flow: This Mac directly to %@", table: "Settings", destination))

            VStack(alignment: .leading, spacing: Space.xs) {
                point(symbol: "arrow.right", text: T("Direct to the provider, no middleman", table: "Settings"))
                point(symbol: "eye", text: T("Mail, files, Calendar, Reminders & Photos only after you review", table: "Settings"))
                point(symbol: "arrow.uturn.backward", text: T("Switch back to this Mac anytime", table: "Settings"))
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.ml)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chatInset, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
    }

    private func flowNode(symbol: String, label: String) -> some View {
        HStack(spacing: Space.xs) {
            Image(systemName: symbol).font(Typo.footnote).foregroundStyle(Theme.ink2)
            Text(label).font(Typo.footnote.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(1)
        }
    }

    private var flowConnector: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1).frame(maxWidth: 28)
    }

    private func point(symbol: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: symbol)
                .font(Typo.caption)
                .foregroundStyle(Theme.ink3)
                .frame(width: 14, alignment: .center)
                .accessibilityHidden(true)
            Text(text)
                .font(Typo.footnote)
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One row in a group: title, explanation, control.
struct SettingsRow<Trailing: View>: View {
    var title: String
    var detail: String?
    var selectable = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title).font(Typo.callout).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(Typo.footnote).foregroundStyle(Theme.ink2).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .modifier(Selectable(on: selectable))
            .layoutPriority(1)
            Spacer(minLength: Space.m)
            // The control keeps its whole label and the text on the left wraps instead: German labels run longer.
            trailing.fixedSize()
        }
        .settingsBlock()
    }
}

private struct Selectable: ViewModifier {
    var on: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if on { content.textSelection(.enabled) } else { content }
    }
}

extension View {
    /// The vertical rhythm of a group's rows (the group adds the rest of its 16 pt inner padding).
    func settingsBlock() -> some View {
        padding(.vertical, Space.l).frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum ButtonKind {
    /// The page's one main action: accent fill, white text. At most one per page.
    case primary
    /// A standard bordered button.
    case secondary
    /// A link: accent text, no border.
    case quiet
}

extension View {
    @ViewBuilder func pippa(_ kind: ButtonKind) -> some View {
        switch kind {
        case .primary: buttonStyle(MainButtonStyle())
        case .secondary: buttonStyle(.bordered)
        case .quiet: buttonStyle(LinkButtonStyle())
        }
    }
}

/// A capsule filled with `Theme.accentFill` (not the lighter `accent`, which white text doesn't read on).
private struct MainButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.callout.weight(.medium))
            .foregroundStyle(enabled ? Color.white : Theme.ink3)
            .padding(.horizontal, Space.xl).frame(height: 28)
            .background(enabled ? Theme.accentFill : Theme.fill3, in: Capsule())
            .brightness(enabled && configuration.isPressed ? -0.08 : 0)
            .contentShape(Capsule())
    }
}

/// The one link look: accent text.
private struct LinkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? Theme.accent : Theme.ink3)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}
