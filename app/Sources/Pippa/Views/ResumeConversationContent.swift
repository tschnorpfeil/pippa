import PippaCore
import SwiftUI

/// A compact return to the same conversation. The composer shares the full chat's draft.
struct ResumeConversationContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var chat: ConversationController
    var measuring: Bool
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(chat.current?.title ?? T("Your Conversation", table: "Views"))
                        .font(Fonts.hint.weight(.medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                        .help(chat.current?.title ?? T("Your Conversation", table: "Views"))
                    if sourceCount > 0 {
                        Button { model.resumeConversation() } label: {
                            Label(sourceCount == 1 ? T("1 source", table: "Views") : T("%lld sources", table: "Views", sourceCount), systemImage: "paperclip")
                                .font(.scaled(size: 11)).foregroundStyle(Theme.ink3)
                        }
                        .buttonStyle(.plain)
                        .help(T("Open Conversation", table: "Views"))
                    }
                }
                Spacer(minLength: 4)
                Button { model.resumeConversation() } label: {
                    Label(T("Open Conversation", table: "Views"), systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.scaled(size: 11.5, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .help(T("Open Conversation", table: "Views"))
                .accessibilityLabel(T("Open Conversation", table: "Views"))
                Button(T("New Topic", table: "Views")) { model.newConversation() }
                    .buttonStyle(.plain)
                    .font(.scaled(size: 11.5))
                    .foregroundStyle(Theme.ink2)
                    .disabled(model.isActiveWork)
                    .help(T("Start a new conversation", table: "Views"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)

            HStack(spacing: 10) {
                MarkSlot(size: 28)
                TextField(T("Continue this conversation…", table: "Views"), text: $model.query)
                    .textFieldStyle(.plain)
                    .font(Fonts.lead)
                    .focused($focused)
                    .onSubmit { submit() }
                    .accessibilityLabel(T("Continue this conversation…", table: "Views"))
                Button { submit() } label: {
                    Image(systemName: "arrow.up")
                        .font(.scaled(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .disabled(!canSubmit)
                .accessibilityLabel(T("Send Message", table: "Views"))
                .accessibilityHint(model.chatBlockedReason ?? "")
                .help(model.chatBlockedReason ?? T("Send Message", table: "Views"))
            }
            .padding(.leading, 10)
            .padding(.trailing, 16)
            .frame(height: ShellTokens.pillHeight)
            if let reason = model.chatBlockedReason {
                Text(reason).font(Fonts.hint).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }
        }
        .workflowWidth(model.compactInputWidth)
        .accessibilityElement(children: .contain)
        .onAppear { if !measuring { focused = true } }
        .onChange(of: model.composerFocus) { _, _ in if !measuring { focused = true } }
    }

    private var sourceCount: Int {
        let files = Set((chat.current?.context?.files ?? []).map { $0.standardizedFileURL.path })
        return files.count + (chat.current?.context?.selectedText == nil ? 0 : 1)
    }

    private var canSubmit: Bool {
        !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (model.isActiveWork || model.sendBlockedReason(for: model.query) == nil)
    }

    private func submit() {
        guard canSubmit else { return }
        let draft = model.query
        model.resumeConversation()
        model.route(draft)
    }
}
