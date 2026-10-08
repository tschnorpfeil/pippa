import SwiftUI

/// The existing mark breathes gently; the wording describes only known activity.
struct PippaActivityIndicator: View {
    var text: String
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    private let breathingState = State<Bool>(initialValue: false)

    var body: some View {
        HStack(spacing: 10) {
            PippaMarkView(size: 24)
                .scaleEffect(reducedMotion ? 1 : (breathingState.wrappedValue ? 1.04 : 0.96))
                .opacity(reducedMotion ? 1 : (breathingState.wrappedValue ? 1 : 0.78))
                .accessibilityHidden(true)
            Text(text).font(Fonts.hint).foregroundStyle(Theme.ink2)
        }
        .onAppear { breathe() }
        .onChange(of: reducedMotion) { _, _ in breathe() }
        .accessibilityElement(children: .combine)
    }

    private func breathe() {
        breathingState.wrappedValue = false
        guard !reducedMotion else { return }
        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
            breathingState.wrappedValue = true
        }
    }
}
