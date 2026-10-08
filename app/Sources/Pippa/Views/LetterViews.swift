import AppKit
import PippaCore
import SwiftUI

// The letter in the one line.
//
// Top: figure and field as in the shelf row, below: "Looking at the mail ...", then the first row
// (sender · what they want · by when), deadlines with "Check online", three equal-width slots for actions
// (suggestions swap without a jump), the growing draft on paper with Paste · Copy · Edit.
// No counters, no paths, no model names. The shell measures the ideal size: no open ScrollView.

/// Content of the row while a letter is open. `measuring` = measuring pass (no focus, no animation, no announcement).
struct LetterLine: View {
    @ObservedObject var model: AppModel
    @ObservedObject var letter: LetterController
    @ObservedObject var tray: TrayController
    var measuring: Bool

    @FocusState private var fieldFocused: Bool

    /// At most this many deadlines under the first row.
    private static let statementLimit = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            fieldRow
            VStack(alignment: .leading, spacing: 12) {
                phaseContent
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .workflowWidth(Theme.inputWidth)
        .animation(animation, value: letter.phase)
        .animation(animation, value: letter.actions)
        .animation(animation, value: letter.web)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "Pippa"))
        .onAppear { if !measuring { fieldFocused = true } }
        .onChange(of: letter.phase) { _, phase in
            if !measuring { announce(phase) }
        }
    }

    // MARK: Eingabe

    private var fieldRow: some View {
        HStack(spacing: 10) {
            MarkSlot(size: 28)
            TextField(T("Ask about this mail", table: "Call"), text: $letter.question)
                .textFieldStyle(.plain)
                .font(Fonts.lead)
                .focused($fieldFocused)
                .onSubmit { submit() }
                .accessibilityLabel(T("Ask about this mail", table: "Call"))
        }
        .padding(.leading, 10)
        .padding(.trailing, 20)
        .frame(height: ShellTokens.pillHeight)
    }

    /// Return: with text into the conversation; empty runs the first action.
    private func submit() {
        let text = letter.question.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return letter.ask(text) }
        letter.chooseFirst()
    }

    // MARK: States

    @ViewBuilder private var phaseContent: some View {
        switch letter.phase {
        case .idle:
            EmptyView()
        case .calling:
            callingRow
        case .permission(let denied):
            permission(denied: denied)
        case .ready:
            headline
            statements
            actionSlots
        case .working(let title):
            headline
            workingRow(title)
            if !letter.draft.isEmpty { draftCard }
        case .draft:
            headline
            draftCard
            draftButtons
        case .inserted(let viaReply):
            headline
            insertedRow(viaReply: viaReply)
        case .pasteReady:
            headline
            pasteRow
        case .failure(let message):
            if letter.hasSession { headline }
            sentence(message)
            if letter.hasSession { actionSlots }
        }
    }

    private var callingRow: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(letter.callingText)
                .font(Fonts.body)
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    /// First row, "please check" for a calculated date, and the sentence about the attachment.
    @ViewBuilder private var headline: some View {
        if let line = letter.firstLine {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(line.text)
                    .font(Fonts.head)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                    .id(line.text)
                if line.pleaseCheck {
                    Text(T("please check", table: "Call"))
                        .font(Fonts.hint)
                        .foregroundStyle(Theme.need)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.needTint))
                        .fixedSize()
                        .help(T("I worked this date out myself. Please check it in the mail.", table: "Call"))
                }
                Spacer(minLength: 0)
            }
        }
        if let note = letter.note {
            Text(note)
                .font(Fonts.hint)
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Deadlines and checking online

    @ViewBuilder private var statements: some View {
        if let deadlines = letter.facts?.deadlines, !deadlines.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(deadlines.prefix(Self.statementLimit))) { deadline in
                    statementRow(deadline)
                }
            }
        }
    }

    private func statementRow(_ deadline: Deadline) -> some View {
        let checking = letter.checkingDeadline == deadline.id
        let showsWeb = letter.webDeadline == deadline.id && !checking
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink3)
                    .accessibilityHidden(true)
                Text(FirstLineBuilder.statement(for: deadline))
                    .font(Fonts.body)
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if letter.canCheckOnline && !checking {
                    Button(T("Check online", table: "Call")) { letter.checkOnline(deadline) }
                        .pippa(.quiet)
                        .disabled(letter.isWorking && !letter.proposing)
                        .help(T("I check the search question for personal details before looking it up.", table: "Call"))
                }
            }
            if checking {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(T("Checking sources online …", table: "Call"))
                        .font(Fonts.hint)
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button(T("Stop", table: "Call")) { letter.stop() }
                        .pippa(.quiet)
                }
                .padding(.leading, 20)
            }
            if showsWeb, let web = letter.web {
                webAnswer(web)
                    .padding(.leading, 20)
                    .transition(.opacity)
            }
        }
    }

    /// Sourced web facts with a source tile; otherwise a calm sentence or the follow-up question about the request.
    @ViewBuilder private func webAnswer(_ web: WebAnswer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(web.facts) { fact in
                VStack(alignment: .leading, spacing: 4) {
                    Text(fact.statement)
                        .font(Fonts.body)
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    SourceTileView(fact: fact, measuring: measuring)
                }
            }
            if let query = letter.lookupConfirm {
                Text(T("To look this up, I would search for this. Nothing else goes along.", table: "Call"))
                    .font(Fonts.hint)
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Button(T("Search online for: %@?", table: "Call", query)) { letter.confirmLookup() }
                    .pippa(.tinted)
                    .help(query)
            } else if let note = web.note {
                Text(note)
                    .font(Fonts.hint)
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Aktionen

    /// Exactly three equal-width slots; empty ones keep their place so suggestions swap without a jump.
    private var actionSlots: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                slot(index)
            }
        }
    }

    @ViewBuilder private func slot(_ index: Int) -> some View {
        if index < letter.actions.count {
            let action = letter.actions[index]
            Button { letter.choose(action) } label: {
                Text(action.title).frame(maxWidth: .infinity)
            }
            .pippa(index == 0 ? .primary : .secondary)
            .disabled(!letter.canChoose)
            .help(action.reason ?? action.title)
            .id(action.id)
            .transition(.opacity)
        } else {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .accessibilityHidden(true)
        }
    }

    // MARK: Entwurf

    private func workingRow(_ title: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(title)
                .font(Fonts.body)
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(T("Stop", table: "Call")) { letter.stop() }
                .pippa(.quiet)
        }
    }

    /// Paper card with a fixed height computed from the text (60...320), same in the measuring pass.
    private var draftCard: some View {
        let height = DraftMetrics.height(for: letter.draft)
        return Group {
            if letter.editing && !measuring {
                TextEditor(text: $letter.draft)
                    .font(Fonts.body)
                    .foregroundStyle(Theme.paperInk)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel(T("Draft", table: "Call"))
            } else {
                ScrollView(.vertical) {
                    Text(letter.draft)
                        .font(Fonts.body)
                        .foregroundStyle(Theme.paperInk)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .defaultScrollAnchor(letter.isDrafting ? .bottom : .top)
                .scrollIndicators(.automatic)
                .accessibilityLabel(T("Draft", table: "Call"))
            }
        }
        .frame(height: height)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper()
    }

    private var draftButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem = letter.insertProblem {
                sentence(problem)
            }
            if letter.insertUncertain {
                HStack {
                    Spacer(minLength: 0)
                    Button(T("Insert Again", table: "Call")) { letter.insertAgain() }
                        .pippa(.secondary)
                        .disabled(letter.isInserting)
                }
            }
            if let search = letter.insertSearch {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(T("Looking for the original in Mail (%lld of %lld) …", table: "Call", search.done, search.total))
                        .font(Fonts.body)
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Button(T("Stop", table: "Call")) { letter.stopInsert() }
                        .pippa(.quiet)
                }
            }
            HStack(spacing: 8) {
                Text(T("Nothing is sent. You send it yourself in Mail.", table: "Call"))
                    .font(Fonts.hint)
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(letter.editing ? T("Done", table: "Call") : T("Edit", table: "Call")) { letter.toggleEdit() }
                    .pippa(.quiet)
                Button(T("Copy", table: "Call")) { letter.copyDraft() }
                    .pippa(.secondary)
                Button(T("Insert", table: "Call")) { letter.insert() }
                    .pippa(.primary)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(letter.isInserting || letter.insertUncertain)
                    .help(T("Puts the draft into a reply in Mail (⌘Return)", table: "Call"))
            }
        }
    }

    private func insertedRow(viaReply: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ok)
                .accessibilityHidden(true)
            Text(Self.insertedText(viaReply: viaReply))
                .font(Fonts.body)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(T("Copy", table: "Call")) { letter.copyDraft() }
                .pippa(.quiet)
        }
    }

    /// Reply open, text not confirmed by Mail: the draft is on the clipboard. Never a check mark.
    private var pasteRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.ink2)
                .accessibilityHidden(true)
            Text(Self.pasteText)
                .font(Fonts.body)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(T("Copy Again", table: "Call")) { letter.copyDraft() }
                .pippa(.quiet)
        }
    }

    private static var pasteText: String {
        T("Your reply is open in Mail. If your text is missing there, it’s on the clipboard: click into the reply and press ⌘V.", table: "Call")
    }

    private static func insertedText(viaReply: Bool) -> String {
        viaReply ? T("In your reply in Mail", table: "Call") : T("In a new mail to the sender", table: "Call")
    }

    // MARK: Permission and sentences

    @ViewBuilder private func permission(denied: Bool) -> some View {
        if denied {
            sentence(T("I’m not allowed to read Mail. You can change that in System Settings.", table: "Call"))
            HStack {
                Spacer(minLength: 0)
                Button(T("Open Settings", table: "Call")) { letter.openMailSettings() }
                    .pippa(.secondary)
            }
        } else {
            sentence(T("To read the mail you selected, your Mac will ask whether I may.", table: "Call"))
            HStack {
                Spacer(minLength: 0)
                Button(T("Continue", table: "Call")) { letter.continueAfterPermission() }
                    .pippa(.primary)
            }
        }
    }

    private func sentence(_ text: String) -> some View {
        Text(text)
            .font(Fonts.body)
            .foregroundStyle(Theme.ink)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Motion and announcement

    private var animation: Animation? {
        guard !measuring, !MarkHub.shared.reduced else { return nil }
        return .easeInOut(duration: 0.2)
    }

    /// VoiceOver: jeden Zustand einmal ansagen.
    private func announce(_ phase: LetterPhase) {
        let text: String
        switch phase {
        case .ready:
            guard let line = letter.firstLine else { return }
            text = line.text
        case .draft:
            text = T("The draft is ready.", table: "Call")
        case .inserted(let viaReply):
            text = Self.insertedText(viaReply: viaReply)
        case .pasteReady:
            text = Self.pasteText
        case .permission(let denied):
            text = denied
                ? T("I’m not allowed to read Mail. You can change that in System Settings.", table: "Call")
                : T("To read the mail you selected, your Mac will ask whether I may.", table: "Call")
        case .failure(let message):
            text = message
        case .idle, .calling, .working:
            return
        }
        NSAccessibility.post(element: NSApp.keyWindow ?? NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Pippa: " + text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

/// Source tile of a web fact: website · page · date. Opens the page at the cited spot.
private struct SourceTileView: View {
    var fact: VerifiedWebFact
    var measuring: Bool

    var body: some View {
        let caption = SourceTile.caption(fact.source)
        Button {
            if !measuring { NSWorkspace.shared.open(fact.link) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "globe")
                    .font(.system(size: 11, weight: .semibold))
                Text(caption)
                    .font(Fonts.hint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Theme.ink2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.fill2))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(fact.quote)
        .accessibilityLabel(T("Open the source: %@", table: "Call", caption))
    }
}

/// Height of the draft card from the text: same font as `Fonts.body`, row width minus margins.
enum DraftMetrics {
    static let minHeight: CGFloat = 60
    static let maxHeight: CGFloat = 320
    /// Zeilenbreite − 2 × 16 Rand − 2 × 12 Kartenrand.
    static let textWidth: CGFloat = Theme.inputWidth - 32 - 24

    static func height(for text: String) -> CGFloat {
        guard !text.isEmpty else { return minHeight }
        let font = NSFont.systemFont(ofSize: 13.5)
        let bounds = CGSize(width: textWidth, height: .greatestFiniteMagnitude)
        let rect = (text as NSString).boundingRect(with: bounds, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                                   attributes: [.font: font])
        let needed = ceil(rect.height) + 4
        return min(maxHeight, max(minHeight, needed))
    }
}
