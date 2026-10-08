import AppKit
import PippaCore
import SwiftUI

// The one line at the pill.
//
// Things lie on Pippa: documents on top, below them the figure and the input field,
// then, depending on state, up to three actions, the progress, the result or a sentence.
// No window, no conversation. Removing takes a thing off Pippa only; the file stays where it is.

/// Content of the `.line` form. `measuring` = measuring pass (no focus, no animation, no announcement).
struct LineContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var tray: TrayController
    var measuring: Bool

    @FocusState private var fieldFocused: Bool
    @FocusState private var suggestionFocused: String?
    // SwiftUI state without the macro, as in the other views.
    private let passwordState = State<String>(initialValue: "")
    private var password: String { get { passwordState.wrappedValue } nonmutating set { passwordState.wrappedValue = newValue } }

    private static let resultSize = CGSize(width: 44, height: 56)

    var body: some View {
        // A table from Excel and a letter from Mail have their own row (SheetViews.swift,
        // LetterViews.swift); otherwise the shelf as before.
        if model.sheet.isActive {
            SheetTableLine(model: model, sheet: model.sheet, measuring: measuring)
        } else if model.letter.isActive {
            LetterLine(model: model, letter: model.letter, tray: tray, measuring: measuring)
        } else {
            trayLine
        }
    }

    private var trayLine: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !attachmentItems.isEmpty {
                DocumentAttachmentStrip(files: attachmentItems.map(\.url), disabled: model.isActiveWork || isWorking) { url in
                    if let item = attachmentItems.first(where: { $0.url == url }) {
                        tray.remove(item.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }
            if !previousResults.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(previousResults.prefix(3))) { item in
                        previousResult(item)
                    }
                    if previousResults.count > 3 {
                        Menu {
                            ForEach(Array(previousResults.dropFirst(3))) { item in
                                Button(item.name) { tray.showResult(item.id) }
                            }
                        } label: {
                            Text(verbatim: "+\(previousResults.count - 3)")
                                .font(Fonts.hint)
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                        .fixedSize()
                        .disabled(model.isActiveWork || isWorking)
                        .accessibilityLabel(T("More", table: "Line"))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }
            fieldRow
            phaseContent
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        .workflowWidth(model.compactInputWidth)
        .animation(animation, value: tray.phase)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "Pippa"))
        .onAppear { if !measuring { fieldFocused = true } }
        .onChange(of: tray.phase) { _, phase in
            if !measuring { announce(phase) }
        }
    }

    // MARK: Eingabe

    private var fieldRow: some View {
        HStack(spacing: 10) {
            MarkSlot(size: 28)
            TextField(T("What should I do with these?", table: "Line"), text: $tray.draft)
                .textFieldStyle(.plain)
                .font(Fonts.lead)
                .focused($fieldFocused)
                .onSubmit { submit() }
                .accessibilityLabel(T("What should I do with these?", table: "Line"))
            Button { submit() } label: {
                Image(systemName: "arrow.up")
                    .font(.scaled(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .disabled(tray.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || model.isActiveWork || isWorking)
            .help(T("Send Message", table: "Views"))
            .accessibilityLabel(T("Send Message", table: "Views"))
        }
        .padding(.leading, 10)
        .padding(.trailing, 20)
        .frame(height: ShellTokens.pillHeight)
    }

    /// Return submits explicit text. Suggestions require deliberate selection.
    private func submit() {
        guard !model.isActiveWork, !isWorking else { return }
        let text = tray.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            tray.ask(text)
            return
        }
        // An inferred suggestion requires an explicit click; empty Return has no intent.
    }

    private var isWorking: Bool {
        if case .working = tray.phase { return true }
        return false
    }

    // MARK: Dokumente

    /// Given documents stay as compact chips above the input.
    private var attachmentItems: [TrayItem] {
        tray.givenItems
    }

    /// Older results can be pulled out at the top; the fresh result has its own card.
    private var previousResults: [TrayItem] {
        var shown: UUID?
        if case .result(let id) = tray.phase { shown = id }
        return tray.items.filter { $0.role == .result && $0.id != shown }
    }

    private func previousResult(_ item: TrayItem) -> some View {
        HStack(spacing: 8) {
            if measuring {
                Color.clear.frame(width: 24, height: 30)
            } else {
                TakeHandle(item: item, tray: tray, size: CGSize(width: 24, height: 30))
                    .frame(width: 24, height: 30)
                    .help(T("Drag it where you need it", table: "Line"))
                    .accessibilityLabel(item.name)
            }
            Button { tray.showResult(item.id) } label: {
                Text(item.name)
                    .font(Fonts.hint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.ink2)
            .disabled(model.isActiveWork || isWorking)
            .help(item.name)
            Spacer(minLength: 0)
            Button { tray.remove(item.id) } label: {
                Image(systemName: "xmark")
                    .font(.scaled(size: 9, weight: .semibold))
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.ink2)
            .disabled(model.isActiveWork || isWorking)
            .help(T("Take it off Pippa. The file stays where it is.", table: "Line"))
            .accessibilityLabel(T("Take %@ off Pippa", table: "Line", item.name))
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: States

    @ViewBuilder private var phaseContent: some View {
        switch tray.phase {
        case .idle, .given:
            actions
        case .working(let title, let progress):
            working(title: title, progress: progress)
        case .result(let id):
            if let item = tray.items.first(where: { $0.id == id }) {
                resultCard(item)
                    .transition(resultTransition)
            } else {
                actions
            }
        case .failure(let message, let passwordFor):
            failure(message: message, passwordFor: passwordFor)
        }
    }

    @ViewBuilder private var actions: some View {
        let offered = tray.offered
        if !offered.isEmpty {
            AdaptiveActions {
                ForEach(Array(offered.prefix(2))) { action in
                    Button(action.title) { tray.choose(action) }
                        .pippa(.quiet)
                        .controlSize(.small)
                        .disabled(!tray.canChoose(action))
                        .focused($suggestionFocused, equals: action.id)
                }
                if offered.count > 2 {
                    Menu {
                        ForEach(Array(offered.dropFirst(2))) { action in
                            Button(action.title) { tray.choose(action) }
                                .disabled(!tray.canChoose(action))
                        }
                    } label: { Image(systemName: "ellipsis") }
                    .focused($suggestionFocused, equals: "__more")
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel(T("More", table: "Line"))
                }
            }
            .onHover { inside in if inside && !measuring { tray.freezeSuggestions() } }
            .onChange(of: suggestionFocused) { _, focused in
                if focused != nil && !measuring { tray.freezeSuggestions() }
            }
        }
    }

    /// Visible only after a second; before that the row already holds its place so nothing jumps.
    private func working(title: String, progress: ToolProgress?) -> some View {
        let visible = tray.progressVisible
        return HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(progressLine(title: title, progress: progress))
                .font(Fonts.body)
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button(T("Stop", table: "Line")) { tray.stop() }
                .pippa(.quiet)
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .accessibilityHidden(!visible)
    }

    private func progressLine(title: String, progress: ToolProgress?) -> String {
        guard let progress, progress.total > 1 else { return title }
        return T("%@ · %lld of %lld pages", table: "Line", title, progress.done, progress.total)
    }

    private func resultCard(_ item: TrayItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if measuring {
                    Color.clear.frame(width: Self.resultSize.width, height: Self.resultSize.height)
                } else {
                    TakeHandle(item: item, tray: tray, size: Self.resultSize)
                        .frame(width: Self.resultSize.width, height: Self.resultSize.height)
                        .help(T("Drag it where you need it", table: "Line"))
                        .accessibilityLabel(item.name)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(Fonts.head)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(T("Drag it where you need it, or save it.", table: "Line"))
                        .font(Fonts.hint)
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paper()
            HStack(spacing: 8) {
                if let note = skippedNote(for: item) {
                    Text(note)
                        .font(Fonts.hint)
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(T("Undo", table: "Line")) { tray.undoResult(item.id) }
                    .pippa(.tinted)
                Button(T("Save…", table: "Line")) { tray.save(item.id) }
                    .pippa(.secondary)
            }
        }
    }

    /// What the tool left behind: things it cannot take stay on Pippa as given.
    private func skippedNote(for result: TrayItem) -> String? {
        // The tool's own sentence (with the reason) as long as the result is fresh.
        if let note = tray.resultNote { return note }
        guard let tool = result.tool else { return nil }
        let names = tray.givenItems.filter { !OneAnswerTools.accepts(tool, $0.url) }.map(\.name)
        guard !names.isEmpty else { return nil }
        return T("I skipped %@.", table: "Line", ListFormatter.localizedString(byJoining: names))
    }

    private func failure(message: String, passwordFor: URL?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(Fonts.body)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if passwordFor != nil {
                HStack(spacing: 8) {
                    SecureField(T("Password", table: "Line"), text: passwordState.projectedValue)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submitPassword() }
                        .accessibilityLabel(T("Password", table: "Line"))
                    Button(T("Continue", table: "Line")) { submitPassword() }
                        .pippa(.primary)
                        .disabled(password.isEmpty)
                }
            }
        }
    }

    /// The password stays in the view only until it is handed over.
    private func submitPassword() {
        let entered = password
        guard !entered.isEmpty else { return }
        password = ""
        tray.submitPassword(entered)
    }

    // MARK: Motion and announcement

    private var animation: Animation? {
        guard !measuring, !MarkHub.shared.reduced else { return nil }
        return .spring(response: 0.38, dampingFraction: 0.78)
    }

    private var resultTransition: AnyTransition {
        if MarkHub.shared.reduced { return .opacity }
        return AnyTransition.scale(scale: 0.6).combined(with: .opacity)
    }

    /// VoiceOver: announce result and error once.
    private func announce(_ phase: TrayPhase) {
        let text: String
        switch phase {
        case .result(let id):
            guard let item = tray.items.first(where: { $0.id == id }) else { return }
            text = T("Ready: %@. Drag it where you need it, or save it.", table: "Line", item.name)
        case .failure(let message, _):
            text = message
        case .idle, .given, .working:
            return
        }
        NSAccessibility.post(element: NSApp.keyWindow ?? NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Pippa: " + text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
