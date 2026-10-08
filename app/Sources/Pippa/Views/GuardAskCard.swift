import SwiftUI
import PiRPC
import PippaCore

/// A question from Pippa's guard (runtime/pippa-guard) before Pi changes something: one everyday sentence, the
/// answers as buttons, and the exact command only behind "Details". Shown in the conversation instead of a window.
struct GuardAsk: Identifiable, Equatable {
    let id = UUID()
    /// "Darf Pippa das?"
    let title: String
    /// The everyday sentence ("Pippa möchte im Ordner ‚Downloads‘ zwei Dateien umbenennen. OK?").
    let sentence: String
    /// Command, folder, undo note; for people who want to know exactly.
    let detail: String
    /// Answers in the guard's words (e.g. "Erlauben", "Für diese Aufgabe erlauben", "Nicht erlauben"); the first is
    /// the default. For a plain confirm: allow / don't allow.
    let options: [String]
    let isConfirm: Bool

    /// Splits Pi's request like the old prompt did: `select` carries "Frage⏎⏎Satz⏎⏎Zusatz" in the title.
    init?(_ request: PiUIRequest) {
        var title = request.title, message = request.message
        if request.method == "select", message.isEmpty, let cut = title.range(of: "\n\n") {
            message = String(title[cut.upperBound...]); title = String(title[..<cut.lowerBound])
        }
        switch request.method {
        case "confirm":
            options = []; isConfirm = true
        case "select" where !request.options.isEmpty && request.options.count <= 3:
            options = request.options; isConfirm = false
        default:
            return nil
        }
        // The guard always writes German; its fixed heading follows the app language.
        self.title = title.isEmpty || title == "Darf Pippa das?" ? T("May Pippa do this?", table: "App") : title
        let parts = message.components(separatedBy: "\n\n")
        sentence = parts.first ?? message
        detail = parts.dropFirst().joined(separator: "\n\n")
    }
}

struct GuardAskCard: View {
    let ask: GuardAsk
    var decide: (PiUIResponse) -> Void
    // @State is not available without Xcode (macro plugin): storage by hand.
    private let detailState = State(initialValue: false)
    private var showsDetail: Bool { detailState.wrappedValue }
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || MarkHub.shared.reduced }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ask.title)
                .font(Fonts.hint).foregroundStyle(Theme.ink2)
            Text(ask.sentence)
                .font(Fonts.body).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if ask.isConfirm {
                    Button(T("Allow", table: "App")) { decide(.confirmed(true)) }.pippa(.primary).keyboardShortcut(.defaultAction)
                    Button(T("Don’t Allow", table: "App")) { decide(.confirmed(false)) }.pippa(.quiet)
                } else {
                    ForEach(Array(ask.options.enumerated()), id: \.offset) { index, option in
                        if index == 0 {
                            Button(Self.label(option)) { decide(.value(option)) }.pippa(.primary).keyboardShortcut(.defaultAction)
                        } else {
                            Button(Self.label(option)) { decide(.value(option)) }.pippa(.quiet)
                        }
                    }
                }
            }
            if !ask.detail.isEmpty {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { detailState.wrappedValue.toggle() }
                } label: {
                    Label(T("Details", table: "App"), systemImage: showsDetail ? "chevron.down" : "chevron.right")
                        .font(Fonts.hint).foregroundStyle(Theme.ink3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsDetail ? T("Hide details", table: "App") : T("Show details", table: "App"))
                if showsDetail {
                    Text(ask.detail)
                        .font(Fonts.hint).foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ask.title + " " + ask.sentence)
    }

    /// The guard answers in German; shown in the app's language. Unknown answers as they are.
    static func label(_ option: String) -> String {
        switch option {
        case "Erlauben": T("Allow", table: "App")
        case "Für diese Aufgabe erlauben": T("Allow for This Task", table: "App")
        case "Nicht erlauben": T("Don’t Allow", table: "App")
        default: option
        }
    }
}
