import AppKit
import PiRPC

/// Questions Pi's extensions ask before a risky step (a shell command that changes things, a web search). They are
/// answered inside Pippa (`Approvals`); this alert is the fallback while no view that can show them is on screen.
@MainActor
enum Confirmations {
    static func ask(_ request: PiUIRequest) async -> PiUIResponse {
        await Approvals.shared.ask(request)
    }

    static func alert(_ request: PiUIRequest) -> PiUIResponse {
        let alert = NSAlert()
        // Pi's `select` has no message, only a title and answers; "question\n\nsentence" may come in the title.
        var title = request.title, message = request.message
        if request.method == "select", message.isEmpty, let cut = title.range(of: "\n\n") {
            message = String(title[cut.upperBound...]); title = String(title[..<cut.lowerBound])
        }
        alert.messageText = title.isEmpty ? T("May Pippa do this?", table: "App") : title
        let parts = message.components(separatedBy: "\n\n")
        alert.informativeText = parts.first ?? message
        if parts.count > 1 {
            let detail = NSTextField(wrappingLabelWithString: parts.dropFirst().joined(separator: "\n\n"))
            detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            detail.textColor = .secondaryLabelColor
            detail.frame.size.width = 320
            detail.sizeToFit()
            alert.accessoryView = detail
        }
        NSApp.activate()
        switch request.method {
        case "confirm":
            alert.addButton(withTitle: T("Allow", table: "App"))
            alert.addButton(withTitle: T("Don’t Allow", table: "App"))
            return .confirmed(alert.runModal() == .alertFirstButtonReturn)
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
