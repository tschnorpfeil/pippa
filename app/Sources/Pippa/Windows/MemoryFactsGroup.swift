import PippaCore
import SwiftUI

/// "Was Pippa über dich weiß": every fact Pippa keeps about the person, each with "Forget". The same file Pi's
/// `remember` tool writes; a forgotten fact is gone from the next conversation on.
struct MemoryFactsGroup: View {
    private let file = PiConversationDefault.memoryFile(support: Pippa.supportDirectory)
    private let factsState = State<[String]>(initialValue: [])
    private let errorState = State<String?>(initialValue: nil)

    var body: some View {
        SettingsGroup(title: T("What Pippa knows about you", table: "Settings"),
                      note: factsState.wrappedValue.isEmpty ? nil
                          : T("Pippa only keeps what you tell it about yourself, on this Mac. A forgotten fact is gone from the next conversation on.", table: "Settings")) {
            if factsState.wrappedValue.isEmpty {
                SettingsRow(title: T("Nothing yet", table: "Settings"),
                            detail: T("When you tell Pippa something about yourself that should last, such as your doctor’s name, it appears here.", table: "Settings"),
                            icon: "person.text.rectangle", tint: .teal, divider: false) { EmptyView() }
            } else {
                ForEach(Array(factsState.wrappedValue.enumerated()), id: \.offset) { index, fact in
                    SettingsRow(title: fact, detail: nil, icon: index == 0 ? "person.text.rectangle" : nil, tint: .teal, divider: index > 0) {
                        Button(T("Forget", table: "Settings")) { forget([fact]) }
                            .pippa(.quiet)
                            .accessibilityLabel(T("Forget “%@”", table: "Settings", fact))
                    }
                }
                if factsState.wrappedValue.count > 1 {
                    SettingsRow(title: T("Forget everything", table: "Settings"), detail: nil) {
                        Button(T("Forget All", table: "Settings")) { forget(nil) }.pippa(.quiet)
                    }
                }
            }
            if let error = errorState.wrappedValue {
                Text(error).font(Fonts.hint).foregroundStyle(Theme.need)
                    .fixedSize(horizontal: false, vertical: true).padding(12)
            }
        }
        .onAppear { factsState.wrappedValue = MemoryFacts.read(file) }
    }

    private func forget(_ facts: Set<String>?) {
        errorState.wrappedValue = nil
        do {
            try MemoryFacts.forget(facts, in: file)
        } catch {
            errorState.wrappedValue = T("I couldn’t forget that just now. Please try again.", table: "Settings")
            UserMessage.record(error, context: "gedaechtnis-vergessen")
        }
        factsState.wrappedValue = MemoryFacts.read(file)
    }
}
