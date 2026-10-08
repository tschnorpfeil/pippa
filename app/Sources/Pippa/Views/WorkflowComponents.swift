import PippaCore
import SwiftUI

// Building blocks shared by conversation, shell and previews: embedded presentation,
// reading width, suggestion buttons from the skills, wrapping button rows, conversation card.

private struct EmbeddedWorkflowKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var embeddedWorkflow: Bool {
        get { self[EmbeddedWorkflowKey.self] }
        set { self[EmbeddedWorkflowKey.self] = newValue }
    }
}

/// The same view fills the available width as a chat card; outside it keeps its panel width.
private struct WorkflowWidth: ViewModifier {
    @Environment(\.embeddedWorkflow) private var embedded
    var standalone: CGFloat
    func body(content: Content) -> some View {
        content
            .frame(width: embedded ? nil : standalone)
            .frame(maxWidth: embedded ? .infinity : nil, alignment: .leading)
    }
}

extension View {
    func workflowWidth(_ standalone: CGFloat) -> some View {
        modifier(WorkflowWidth(standalone: standalone))
    }
}

/// What Pippa can do, fitting the spot in the conversation: a few buttons, each calls a bundled skill (`PippaSkill`).
struct SkillActions: View {
    @ObservedObject var model: AppModel
    var place: PippaSkill.Place
    var body: some View {
        let skills = PippaSkill.suggestions(for: place)
        AdaptiveActions {
            ForEach(skills) { skill in
                Button(skill.title ?? skill.name) { model.runSkill(skill, offered: skills, place: place) }
                    .pippa(.quiet)
                    .disabled(model.isActiveWork || model.chatBlockedReason != nil)
                    .help(model.chatBlockedReason ?? skill.prompt)
            }
        }
    }
}

/// Short action groups wrap as a unit instead of squeezing button labels.
struct AdaptiveActions<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) { content }
        }
    }
}

extension View {
    /// Card in the conversation: white surface with a fine border.
    func chatCard() -> some View {
        background(Theme.chatCard, in: RoundedRectangle(cornerRadius: 16))
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.chatBorder, lineWidth: 0.5) }
    }
}
