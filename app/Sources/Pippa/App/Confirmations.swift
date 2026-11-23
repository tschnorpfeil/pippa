import AppKit
import PiRPC
import SwiftUI

/// Parsed display parts of a Pi UI request, shared by `QuestionCard`, `IslandQuestionText` and the fallback alert.
struct ApprovalPresentation: Equatable {
    var title: String
    var summary: String?
    var detail: String?

    /// Pi's `select` has no message, only a title and answers; "question\n\nsentence" may come in the title.
    static func parse(_ request: PiUIRequest) -> Self {
        var title = request.title, message = request.message
        if request.method == "select", message.isEmpty, let cut = title.range(of: "\n\n") {
            message = String(title[cut.upperBound...])
            title = String(title[..<cut.lowerBound])
        }
        let paragraphs = message.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let fallback = title.isEmpty ? T("May Pippa do this?", table: "App") : title
        let detail = paragraphs.count > 1 ? paragraphs.dropFirst().joined(separator: "\n\n") : nil
        return Self(title: fallback, summary: paragraphs.first, detail: detail)
    }

    /// Splits a structured metadata line ("To: anna@example.org", "Betreff: Vertrag") into its label and value.
    /// Rejects URLs and prose sentences so only real header fields are highlighted.
    static func keyValueLine(_ line: String) -> (label: String, value: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let after = line.index(after: colon)
        guard after < line.endIndex, line[after] == " " else { return nil }
        let label = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: after)...]).trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, label.count <= 24, !value.isEmpty,
              let first = label.first, first.isLetter,
              label.allSatisfy({ $0.isLetter || $0 == " " || $0 == "-" }) else { return nil }
        let lower = label.lowercased()
        guard lower != "http" && lower != "https" && lower != "mailto" else { return nil }
        return (label, value)
    }

    /// Highlights structured key-value paragraphs (recipients, subject, sender, attachments) while leaving free text plain.
    static func formatted(_ text: String, baseFont: Font, valueFont: Font, labelColor: Color, valueColor: Color) -> AttributedString {
        let paragraphs = text.components(separatedBy: "\n\n")
        var result = AttributedString()
        for (pIndex, paragraph) in paragraphs.enumerated() {
            if pIndex > 0 { result.append(AttributedString("\n\n")) }
            let lines = paragraph.components(separatedBy: "\n")
            let parsed = lines.map(keyValueLine)
            let isMetadata = !lines.isEmpty && parsed.allSatisfy { $0 != nil }
            if isMetadata {
                for (lIndex, pair) in parsed.enumerated() {
                    guard let pair else { continue }
                    if lIndex > 0 { result.append(AttributedString("\n")) }
                    var label = AttributedString(pair.label + ": ")
                    label.font = baseFont
                    label.foregroundColor = labelColor
                    var value = AttributedString(pair.value)
                    value.font = valueFont
                    value.foregroundColor = valueColor
                    result.append(label)
                    result.append(value)
                }
            } else {
                var plain = AttributedString(paragraph)
                plain.font = baseFont
                plain.foregroundColor = valueColor
                result.append(plain)
            }
        }
        return result
    }
}

/// Questions Pi's extensions ask before a risky step (a shell command that changes things, a web search). They are
/// answered inside Pippa (`Approvals`); this alert is the fallback while no view that can show them is on screen.
@MainActor
enum Confirmations {
    static func ask(_ request: PiUIRequest) async -> PiUIResponse {
        await Approvals.shared.ask(request)
    }

    /// The buttons of a `confirm`, no then yes: the request's own words when it names them ("Don’t Send", "Send"),
    /// otherwise Don’t Allow and Allow. The chat's card, the island and the alert all show these.
    static func confirmLabels(_ request: PiUIRequest) -> (no: String, yes: String) {
        request.options.count == 2 ? (request.options[0], request.options[1]) : (T("Don’t Allow", table: "App"), T("Allow", table: "App"))
    }

    /// No, then yes. No is the default button (Return) and has the focus (Space with keyboard navigation): a confirm
    /// may send a mail or change things for good, so only a click on yes says yes. Returns yes's response.
    static func addConfirmButtons(_ alert: NSAlert, _ request: PiUIRequest) -> NSApplication.ModalResponse {
        let labels = confirmLabels(request)
        let no = alert.addButton(withTitle: labels.no)
        let yes = alert.addButton(withTitle: labels.yes)
        no.keyEquivalent = "\r"
        yes.keyEquivalent = ""
        alert.window.initialFirstResponder = no
        return .alertSecondButtonReturn
    }

    static func alert(_ request: PiUIRequest) -> PiUIResponse {
        let alert = NSAlert()
        let parsed = ApprovalPresentation.parse(request)
        alert.messageText = parsed.title
        alert.informativeText = parsed.summary ?? ""
        if let text = parsed.detail {
            if text.count > QuestionCard.scrollsAfter {
                // A long text (a whole mail) scrolls, so the buttons stay on screen; nothing is cut.
                let scroll = NSTextView.scrollableTextView()
                scroll.frame = NSRect(x: 0, y: 0, width: 340, height: QuestionCard.detailHeight)
                scroll.drawsBackground = false
                if let view = scroll.documentView as? NSTextView {
                    view.string = text
                    view.isEditable = false
                    view.drawsBackground = false
                    view.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                    view.textColor = .secondaryLabelColor
                }
                alert.accessoryView = scroll
            } else {
                let detail = NSTextField(wrappingLabelWithString: text)
                detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                detail.textColor = .secondaryLabelColor
                detail.frame.size.width = 320
                detail.sizeToFit()
                alert.accessoryView = detail
            }
        }
        NSApp.activate()
        switch request.method {
        case "confirm":
            let yes = addConfirmButtons(alert, request)
            return .confirmed(alert.runModal() == yes)
        case "select" where !request.options.isEmpty && request.options.count <= 3:
            for option in request.options { alert.addButton(withTitle: option) }
            let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            return request.options.indices.contains(index) ? .value(request.options[index]) : .cancelled
        case "select":
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
            popup.addItems(withTitles: request.options)
            alert.accessoryView = popup
            alert.addButton(withTitle: T("OK", table: "App")); alert.addButton(withTitle: T("Cancel", table: "App"))
            guard alert.runModal() == .alertFirstButtonReturn, let title = popup.titleOfSelectedItem else { return .cancelled }
            return .value(title)
        default:
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            field.stringValue = request.prefill ?? ""
            field.placeholderString = request.placeholder
            alert.accessoryView = field
            alert.addButton(withTitle: T("OK", table: "App")); alert.addButton(withTitle: T("Cancel", table: "App"))
            return alert.runModal() == .alertFirstButtonReturn ? .value(field.stringValue) : .cancelled
        }
    }
}
