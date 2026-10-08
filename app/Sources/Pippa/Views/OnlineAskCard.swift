import SwiftUI
import PippaCore

/// Pippa asks before every request to the user's own online service (PippaOnlineService). The card states exactly what
/// would leave: where to, how much, which shown items are included. "Just this time" (this message) · "For this
/// conversation" · "On this Mac" (this answer with the local AI) · "No".
struct OnlineAskSlot: View {
    @ObservedObject var service = PippaOnlineService.shared

    var body: some View {
        if let ask = service.ask { OnlineAskCard(ask: ask) { service.answer($0) }.id("online-ask") }
    }
}

struct OnlineAskCard: View {
    let ask: PippaOnlineAsk
    var decide: (PippaOnlineService.Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(PippaOnlineService.title(ask))
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.whatGoes(ask))
                .font(Fonts.body).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if !ask.shownIncluded.isEmpty {
                Text(T("Included: %@", table: "App", ask.shownIncluded.joined(separator: ", ")))
                    .font(Fonts.hint).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(T("Goes to %@ (model %@). Your service’s usual costs apply.", table: "App", ask.host, ask.model))
                .font(Fonts.hint).foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text(T("Applies to this message. Newly shown things need a new OK.", table: "App"))
                .font(Fonts.hint).foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
            AdaptiveActions {
                // Like the web card: if shown items go along, Return sends nothing ("No" is the default button).
                if ask.shownIncluded.isEmpty {
                    Button(T("Just This Once", table: "App")) { decide(.once) }.pippa(.primary).keyboardShortcut(.defaultAction)
                    Button(T("For This Conversation", table: "App")) { decide(.conversation) }.pippa(.secondary)
                    Button(T("On This Mac", table: "App")) { decide(.local) }.pippa(.secondary)
                    Button(T("No", table: "App")) { decide(.deny) }.pippa(.quiet)
                } else {
                    Button(T("No", table: "App")) { decide(.deny) }.pippa(.primary).keyboardShortcut(.defaultAction)
                    Button(T("On This Mac", table: "App")) { decide(.local) }.pippa(.secondary)
                    Button(T("Just This Once", table: "App")) { decide(.once) }.pippa(.quiet)
                    Button(T("For This Conversation", table: "App")) { decide(.conversation) }.pippa(.quiet)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(PippaOnlineService.title(ask) + " " + Self.whatGoes(ask))
    }

    /// "Your message and the history so far (5 messages), including 2 results from my tools. 14 KB in total."
    static func whatGoes(_ ask: PippaOnlineAsk) -> String {
        var text = T("Your message and this conversation so far (%lld messages)", table: "App", ask.messages)
        if ask.toolResults > 0 { text += T(", with %lld results from my tools, for example files I read", table: "App", ask.toolResults) }
        if ask.images > 0 { text += T(", %lld pictures", table: "App", ask.images) }
        text += T(". Together %@.", table: "App", ByteCountFormatter.string(fromByteCount: Int64(ask.bytes), countStyle: .file))
        return text
    }
}
