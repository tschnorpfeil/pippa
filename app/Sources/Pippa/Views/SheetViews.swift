import AppKit
import PippaCore
import SwiftUI

// The table in the one line (built like LetterViews.swift).
//
// Top: figure and field as in the shelf row, below "Looking at your table: Kosten 2026, column Betrag", the first
// row from "Check the total" and three equal-width slots for actions. *Check the total* shows the findings as one
// short sentence each. No glow over cells (no accessibility APIs in this version): the sentences name
// heading and label; the addresses appear only in the help text. No counters, no paths, no model names.

/// Content of the row while a table is open. `measuring` = measuring pass (no focus, no animation, no announcement).
struct SheetTableLine: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sheet: SheetController
    var measuring: Bool

    @FocusState private var fieldFocused: Bool

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
        .animation(animation, value: sheet.phase)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "Pippa"))
        .onAppear { if !measuring { fieldFocused = true } }
        .onChange(of: sheet.phase) { _, phase in
            if !measuring { announce(phase) }
        }
    }

    // MARK: Eingabe

    private var fieldRow: some View {
        HStack(spacing: 10) {
            MarkSlot(size: 28)
            TextField(T("Ask about this table", table: "SheetUI"), text: $sheet.question)
                .textFieldStyle(.plain)
                .font(Fonts.lead)
                .focused($fieldFocused)
                .onSubmit { submit() }
                .accessibilityLabel(T("Ask about this table", table: "SheetUI"))
        }
        .padding(.leading, 10)
        .padding(.trailing, 20)
        .frame(height: ShellTokens.pillHeight)
    }

    /// Return: with text into the conversation; empty runs the first action.
    private func submit() {
        let text = sheet.question.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return sheet.ask(text) }
        sheet.chooseFirst()
    }

    // MARK: States

    @ViewBuilder private var phaseContent: some View {
        switch sheet.phase {
        case .idle:
            EmptyView()
        case .calling:
            callingRow
        case .permission(let denied):
            permission(denied: denied)
        case .ready:
            headline
            actionSlots
        case .checked:
            headline
            findingsList
            actionSlots
        case .compared(let line):
            headline
            resultSentence(line, symbol: "arrow.left.arrow.right")
            actionSlots
        case .failure(let message):
            if sheet.hasSession { headline }
            sentence(message)
            if sheet.hasSession { actionSlots }
        }
    }

    private var callingRow: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(sheet.lookingText)
                .font(Fonts.body)
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    /// "Looking at your table: ..." and below it the first row from the code.
    @ViewBuilder private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(sheet.lookingText)
                .font(Fonts.hint)
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .truncationMode(.tail)
            if let line = sheet.firstLine {
                Text(line.text)
                    .font(Fonts.head)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                    .id(line.text)
            }
        }
        if let note = sheet.note {
            Text(note)
                .font(Fonts.hint)
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Check the total

    /// One sentence per finding. Without findings, a calm sentence about what Pippa did.
    @ViewBuilder private var findingsList: some View {
        if sheet.findings.isEmpty {
            if sheet.foundTotals {
                resultSentence(T("I added the numbers up again myself. Nothing is missing.", table: "SheetUI"), symbol: "checkmark.circle.fill",
                               tint: Theme.ok)
            } else {
                sentence(T("Select the total, or the numbers it adds up, and call me again.", table: "SheetUI"))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(sheet.findings.prefix(SheetController.findingLimit).enumerated()), id: \.offset) { _, finding in
                    findingRow(finding)
                }
                if sheet.findings.count > SheetController.findingLimit {
                    Text(T("There is more. Ask me, and we’ll go through it together.", table: "SheetUI"))
                        .font(Fonts.hint)
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(T("Nothing in your table was changed.", table: "SheetUI"))
                    .font(Fonts.hint)
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func findingRow(_ finding: SheetFinding) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Self.symbol(for: finding.kind))
                .font(.scaled(size: 12, weight: .semibold))
                .foregroundStyle(Theme.need)
                .accessibilityHidden(true)
            Text(finding.sentence)
                .font(Fonts.body)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        // "Details": cells only in the help text, never in the sentence.
        .help(finding.addresses.joined(separator: ", "))
        .accessibilityElement(children: .combine)
    }

    private static func symbol(for kind: SheetFinding.Kind) -> String {
        switch kind {
        case .missingRows: "plus.circle"
        case .mismatch: "exclamationmark.circle"
        case .textNumber: "textformat"
        case .unverified: "questionmark.circle"
        }
    }

    private func resultSentence(_ text: String, symbol: String, tint: Color = Theme.ink3) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.scaled(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(Fonts.body)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: Aktionen

    /// Exactly three equal-width slots, as on the letter.
    private var actionSlots: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { index in
                slot(index)
            }
        }
    }

    @ViewBuilder private func slot(_ index: Int) -> some View {
        if index < sheet.actions.count {
            let action = sheet.actions[index]
            Button { sheet.choose(action) } label: {
                Text(action.title).frame(maxWidth: .infinity)
            }
            .pippa(index == 0 ? .primary : .secondary)
            .disabled(!sheet.canChoose)
            .help(action.help)
            .id(action.id)
        } else {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .accessibilityHidden(true)
        }
    }

    // MARK: Permission and sentences

    @ViewBuilder private func permission(denied: Bool) -> some View {
        if denied {
            sentence(Self.deniedText)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(T("Give me the file instead", table: "SheetUI")) { sheet.giveFile() }
                    .pippa(.secondary)
                    .help(T("Choose the table as a file. I only read it.", table: "SheetUI"))
                Button(T("Open Settings", table: "SheetUI")) { sheet.openSettings() }
                    .pippa(.primary)
                    .help(T("Privacy & Security › Automation", table: "SheetUI"))
            }
        } else {
            sentence(Self.askText)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(T("Give me the file instead", table: "SheetUI")) { sheet.giveFile() }
                    .pippa(.quiet)
                Button(T("Continue", table: "SheetUI")) { sheet.continueAfterPermission() }
                    .pippa(.primary)
            }
        }
    }

    private static var deniedText: String {
        T("I’m not allowed to read Excel. You can change that in System Settings.", table: "SheetUI")
    }

    private static var askText: String {
        T("To read the table you selected, your Mac will ask whether I may. When checking, I only read and change nothing.", table: "SheetUI")
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
    private func announce(_ phase: SheetPhase) {
        let text: String
        switch phase {
        case .ready:
            guard let line = sheet.firstLine else { return }
            text = line.text
        case .checked:
            let sentences = sheet.findings.prefix(SheetController.findingLimit).map(\.sentence)
            text = sentences.isEmpty ? (sheet.firstLine?.text ?? "") : sentences.joined(separator: " ")
        case .compared(let line):
            text = line
        case .permission(let denied):
            text = denied ? Self.deniedText : Self.askText
        case .failure(let message):
            text = message
        case .idle, .calling:
            return
        }
        guard !text.isEmpty else { return }
        NSAccessibility.post(element: NSApp.keyWindow ?? NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "Pippa: " + text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}
