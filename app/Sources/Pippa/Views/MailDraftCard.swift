import SwiftUI
import PippaCore

/// A saved, editable draft. Opening Mail creates an unsent message, never a send action.
struct MailDraftCard: View {
    @ObservedObject var model: AppModel
    @ObservedObject var chat: ConversationController
    let messageID: UUID
    let draft: ConversationMailDraft
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case recipient, subject, body }
    private let recipientState: State<String>
    private let subjectState: State<String>
    private let bodyState: State<String>
    private let failureState = State<Bool>(initialValue: false)

    init(model: AppModel, chat: ConversationController, messageID: UUID, draft: ConversationMailDraft) {
        self.model = model; self.chat = chat; self.messageID = messageID; self.draft = draft
        recipientState = State(initialValue: draft.to)
        subjectState = State(initialValue: draft.subject)
        bodyState = State(initialValue: draft.body)
    }

    private var isSimulation: Bool { model.engine is StubEngine }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch draft.state {
            case .draft, .opening:
                editableDraft
            case .opened:
                Text(isSimulation ? T("Handoff simulated · Mail was not opened", table: "Views") : T("Opened in Mail · not sent", table: "Views"))
                    .font(Fonts.body).foregroundStyle(Theme.ink2)
                retainedDraft
            case .discarded:
                Text(T("Draft discarded", table: "Views"))
                    .font(Fonts.body).foregroundStyle(Theme.ink3)
                retainedDraft
            case .uncertain:
                Text(isSimulation ? T("Test handoff could not be confirmed · Mail was not opened", table: "Views") : T("Check Mail before continuing. The draft may already be open; nothing was sent.", table: "Views"))
                    .font(Fonts.body).foregroundStyle(Theme.ink)
                // The person's click after checking Mail is the only way back; never an automatic retry.
                Button(T("Back to Draft", table: "Views")) { model.reviseUncertainMailDraft(messageID: messageID) }
                    .pippa(.secondary).disabled(model.isActiveWork)
                retainedDraft
            }
            if draft.state == .opening, let search = model.mailDraftSearch {
                HStack(spacing: 8) {
                    Text(T("Looking for the original in Mail (%lld of %lld) …", table: "Views", search.done, search.total))
                        .font(Fonts.hint).foregroundStyle(Theme.ink2).lineLimit(1)
                    Spacer(minLength: 8)
                    Button(T("Stop", table: "Views")) { model.stopMailDraftOpening() }
                        .pippa(.quiet)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.paper, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.chatBorder, lineWidth: 0.5) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(T("Draft", table: "Views"))
        .onChange(of: draft) { _, updated in
            if focusedField == nil || updated.state != .draft {
                recipientState.wrappedValue = updated.to
                subjectState.wrappedValue = updated.subject
                bodyState.wrappedValue = updated.body
                failureState.wrappedValue = false
                if updated.state != .draft { focusedField = nil }
            }
        }
        .onChange(of: focusedField) { previous, _ in
            if previous != nil, draft.state == .draft { _ = persist() }
        }
        .onDisappear { if draft.state == .draft { _ = persist() } }
        .task(id: [editedDraft.to, editedDraft.subject, editedDraft.body, editedDraft.state.rawValue]) {
            guard draft.state == .draft else { return }
            do {
                try await Task.sleep(for: .milliseconds(500))
                try Task.checkCancellation()
                _ = persist()
            } catch { /* A later edit or navigation cancels the pending save. */ }
        }
    }

    private var retainedDraft: some View {
        DisclosureGroup(T("View Draft", table: "Views")) {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView {
                    Text(verbatim: draft.body)
                        .font(.scaled(size: 14, weight: .regular)).lineSpacing(4)
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 220)
                copyButton
            }.padding(.top, 6)
        }.font(Fonts.hint).foregroundStyle(Theme.ink2)
    }

    private var editableDraft: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "envelope").font(.scaled(size: 12)).foregroundStyle(Theme.ink3)
                Text(T("Draft", table: "Views")).font(.scaled(size: 13, weight: .medium)).foregroundStyle(Theme.paperInk)
            }
            field(T("To", table: "Views"), placeholder: T("Add recipient (optional)", table: "Views"), text: recipientState.projectedValue, focus: .recipient)
            field(T("Subject", table: "Views"), placeholder: T("Add subject (optional)", table: "Views"), text: subjectState.projectedValue, focus: .subject)
            Theme.chatBorder.frame(height: 0.5)
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: bodyState.projectedValue)
                    .font(.scaled(size: 14, weight: .regular))
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(Theme.paperInk)
                    .frame(height: 120)
                    .focused($focusedField, equals: .body)
                    .accessibilityLabel(T("Draft text", table: "Views"))
            }
            if draft.state == .draft, let hint = validationHint {
                Text(hint).font(Fonts.hint).foregroundStyle(Theme.ink2)
            }
            if failureState.wrappedValue {
                Text(T("The draft could not be saved. Keep your text here and try again.", table: "Views"))
                    .font(Fonts.hint).foregroundStyle(Theme.ink2)
            }
            Text(isSimulation ? T("Test draft · does not open Mail", table: "Views") : T("Just a draft · nothing sent", table: "Views"))
                .font(Fonts.hint).foregroundStyle(Theme.ink3)
            if draft.state == .opening {
                PippaActivityIndicator(text: isSimulation ? T("Testing handoff…", table: "Views") : T("Opening in Mail…", table: "Views"))
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { openButton; discardButton }
                    VStack(alignment: .leading, spacing: 8) {
                        openButton
                        discardButton
                    }
                }
            }
        }.disabled(draft.state == .opening || model.isActiveWork)
            .contextMenu {
                if draft.state == .draft {
                    Button(T("Copy Draft", table: "Views")) { copyDraft() }
                }
            }
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>, focus: Field) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.scaled(size: 11)).foregroundStyle(Theme.ink2)
                .frame(width: 52, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain).font(Fonts.body).foregroundStyle(Theme.paperInk)
                .focused($focusedField, equals: focus)
                .accessibilityLabel(label)
                .onSubmit { _ = persist() }
        }.padding(.vertical, 2)
    }

    private var openButton: some View {
        Button(isSimulation ? T("Test Handoff", table: "Views") : T("Open in Mail", table: "Views")) {
            guard editedDraft.canOpen, persist() else { return }
            focusedField = nil
            model.openMailDraft(messageID: messageID)
        }.pippa(.primary).disabled(!editedDraft.canOpen || model.isActiveWork)
    }

    private var discardButton: some View {
        Button(T("Discard Draft", table: "Views")) {
            // Keep the latest text readable after discarding; focus changes cannot reopen it.
            guard persist() else { return }
            model.discardMailDraft(messageID: messageID)
            focusedField = nil
        }.pippa(.quiet).disabled(model.isActiveWork)
    }

    private var copyButton: some View {
        Button(T("Copy", table: "Views")) { copyDraft() }
            .pippa(.quiet).accessibilityLabel(T("Copy Draft", table: "Views"))
    }

    private func copyDraft() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(draft.state == .draft ? bodyState.wrappedValue : draft.body, forType: .string)
    }

    private var editedDraft: ConversationMailDraft {
        var value = draft
        value.to = recipientState.wrappedValue
        value.subject = subjectState.wrappedValue
        value.body = bodyState.wrappedValue
        return value
    }

    private var validationHint: String? {
        if editedDraft.to.rangeOfCharacter(from: .newlines) != nil || editedDraft.subject.rangeOfCharacter(from: .newlines) != nil {
            return T("Recipient and subject must each be one line.", table: "Views")
        }
        var addressCheck = editedDraft
        addressCheck.subject = ""
        addressCheck.body = "Text"
        addressCheck.state = .draft
        if !addressCheck.to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !addressCheck.canOpen {
            return T("Enter one email address, or leave To empty.", table: "Views")
        }
        return nil
    }

    @discardableResult private func persist() -> Bool {
        guard draft.state == .draft,
              let savedDraft = chat.current?.messages.first(where: { $0.id == messageID })?.mailDraft,
              savedDraft.state == .draft else { return false }
        var updated = savedDraft
        updated.to = recipientState.wrappedValue
        updated.subject = subjectState.wrappedValue
        updated.body = bodyState.wrappedValue
        if updated == savedDraft {
            failureState.wrappedValue = false
            return true
        }
        let saved = chat.updateMailDraft(messageID: messageID, draft: updated)
        failureState.wrappedValue = !saved
        return saved
    }
}
