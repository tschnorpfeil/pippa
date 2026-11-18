import AppKit
import PippaCore
import SwiftUI

/// Before anything from the Mac goes to an online AI: who receives it, the person's words, and each part Pippa read
/// here with where it came from, editable and each one can be left out. Parts whose source is set to "Only on this
/// Mac" are named, never shown or sent. Nothing is sent until Send; Cancel or closing keeps every edit with the
/// conversation it was opened in (`ShareDesk`), and the composer offers to continue it.
struct ShareReviewSheet: View {
    @ObservedObject var chat: ChatModel

    var body: some View {
        if let review = chat.review {
            VStack(alignment: .leading, spacing: Space.l) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Label(T("Send to %@", table: "App", review.plan.destination.label), systemImage: "cloud").font(Typo.headline)
                    SettingsNote(T("Only what is below goes to %@. Edit or leave out anything first. Web searches are asked separately.", table: "App",
                                   review.plan.destination.provider))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.l) {
                        question(review)
                        // What stays here comes first, so it is never below the fold.
                        if !review.plan.withheld.isEmpty { withheld(review.plan.withheld) }
                        ForEach(review.plan.pieces) { piece in part(piece) }
                        if review.loading {
                            HStack(spacing: Space.m) { ProgressView().controlSize(.small); Text(T("Reading on this Mac…", table: "App")) }
                                .font(Typo.footnote).foregroundStyle(Theme.ink2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 220, maxHeight: 460)
                if let problem = review.problem {
                    Text(problem).font(Typo.footnote).foregroundStyle(Theme.need).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: Space.xl) {
                    Button(T("Sharing Settings…", table: "App")) { SettingsWindow.shared.show(.ai) }.pippa(.quiet).fixedSize()
                    Spacer()
                    Button(T("Cancel", table: "App")) { chat.dismissReview() }.keyboardShortcut(.cancelAction).pippa(.secondary)
                    Button(T("Send to %@", table: "App", review.plan.destination.provider)) { chat.approveReview() }
                        .keyboardShortcut(.defaultAction).pippa(.primary)
                        .disabled(review.loading || !review.plan.canSend || chat.isAnswering)
                }
            }
            .font(Typo.callout).foregroundStyle(Theme.ink)
            .padding(Space.x3).frame(width: 600)
            .background(Color(nsColor: Theme.chatTint))
        }
    }

    private func question(_ review: ShareReview) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(T("Your message", table: "App")).font(Typo.footnote.weight(.semibold)).foregroundStyle(Theme.ink2)
            editor(Binding(get: { chat.review?.plan.question ?? "" }, set: { text in chat.updateReview { $0.question = text } }),
                   label: T("Your message", table: "App"), height: 60)
        }
    }

    private func part(_ piece: SharePiece) -> some View {
        let binding = { (key: WritableKeyPath<SharePiece, String>) in
            Binding(get: { chat.review?.plan.pieces.first { $0.id == piece.id }?[keyPath: key] ?? "" },
                    set: { text in chat.updateReview { plan in
                        if let index = plan.pieces.firstIndex(where: { $0.id == piece.id }) { plan.pieces[index][keyPath: key] = text }
                    } })
        }
        let included = Binding(get: { chat.review?.plan.pieces.first { $0.id == piece.id }?.included ?? false },
                               set: { on in chat.updateReview { plan in
                                   if let index = plan.pieces.firstIndex(where: { $0.id == piece.id }) { plan.pieces[index].included = on }
                               } })
        return VStack(alignment: .leading, spacing: Space.s) {
            Toggle(isOn: included) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(piece.title).font(Typo.footnote.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text(Self.origin(piece)).font(Typo.caption).foregroundStyle(Theme.ink3)
                }
            }
            .toggleStyle(.checkbox)
            if included.wrappedValue { editor(binding(\.text), label: piece.title, height: 140) }
        }
    }

    private func withheld(_ pieces: [SharePiece]) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Label(T("Stays on this Mac", table: "App"), systemImage: "lock").font(Typo.footnote.weight(.semibold)).foregroundStyle(Theme.ink2)
            ForEach(pieces) { piece in
                Text(piece.title + " · " + Self.origin(piece)).font(Typo.caption).foregroundStyle(Theme.ink3).lineLimit(2)
            }
            Text(T("Set to “Only on this Mac” in Settings.", table: "App")).font(Typo.caption).foregroundStyle(Theme.ink3)
        }
    }

    private func editor(_ text: Binding<String>, label: String, height: CGFloat) -> some View {
        TextEditor(text: text)
            .font(Typo.footnote).scrollContentBackground(.hidden)
            .padding(Space.s)
            .frame(height: height)
            .background(Theme.chatCard, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1) }
            .accessibilityLabel(label)
    }

    /// Where a part was read: "From Mail", "From Calendar and Mail", or unknown for older answers.
    static func origin(_ piece: SharePiece) -> String {
        if piece.unknownOrigin { return T("Read before Pippa noted its sources", table: "App") }
        if piece.sources.isEmpty { return T("Nothing read from your Mac", table: "App") }
        return T("From %@", table: "App", piece.sources.sorted().map(\.displayName).formatted(appList))
    }

    /// "Mail and Calendar" in the app's language, not the system region's.
    static var appList: ListFormatStyle<StringStyle, [String]> {
        .list(type: .and).locale(Locale(identifier: Bundle.module.preferredLocalizations.first ?? "en"))
    }
}
