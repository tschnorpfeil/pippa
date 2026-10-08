import AppKit
import PippaCore
import SwiftUI

// Integrations: Reminders, Calendar, Mail (read-only). Every write step goes through preview,
// confirm and journal; macOS asks for access only on first use.
extension AppModel {

    /// First check whether Pippa may. Never asked yet: one friendly sentence, then the system prompt.
    /// Denied: a calm note with a way to Settings. Never at launch, only on use.
    func withAccess(_ integration: Integration, then action: @escaping @MainActor () -> Void) {
        let engine = self.engine
        busy = true
        Task { [weak self] in
            let access = await engine.integrationAccess(integration)
            guard let self else { return }
            self.busy = false
            switch access {
            case .granted:
                action()
            case .notDetermined:
                self.afterAccess = action
                self.show(.permission(integration, denied: false))
            case .denied:
                self.afterAccess = nil
                self.show(.permission(integration, denied: true))
            case .unavailable(let why):
                self.show(.message(title: T("Not possible right now", table: "App"), body: why, isError: false))
            }
        }
    }

    /// "Continue" in the sentence before the system prompt.
    func requestAccess(_ integration: Integration) {
        let action = afterAccess
        afterAccess = nil
        perform(title: T("One moment…", table: "App"), subtitle: T("Your Mac will ask you in a moment.", table: "App"), retry: nil) { engine in
            await engine.requestIntegrationAccess(integration)
        } done: { [weak self] access in
            if access == .granted { action?() } else { self?.show(.permission(integration, denied: true)) }
        }
    }

    func openSettings(for integration: Integration) {
        NSWorkspace.shared.open(integration.settingsURL)
        collapse()
    }

    static func openApp(_ integration: Integration?) {
        guard let integration, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: integration.bundleIdentifier) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Show deadlines that are already known (letter from Mail: found by code) in the usual deadlines sheet, without a model.
    func showDeadlines(_ found: [Deadline], sender: String?) {
        deadlines = found
        deadlineSender = sender
        show(.deadlines)
    }

    /// Deadlines the code already found go straight to the cards ("Add…" to the calendar). Otherwise Pi reads the
    /// documents with skill `fristen-erkennen` and adds what the person wants with `calendar_add` (the guard asks).
    func startDeadlines() {
        if let o = lastOverview, !o.deadlines.isEmpty {
            deadlines = o.deadlines
            deadlineSender = o.sender
            return show(.deadlines)
        }
        guard let ctx = context, !ctx.items.isEmpty else { return askForContext() }
        guard let skill = PippaSkill.bundled.first(where: { $0.name == "fristen-erkennen" }) else { return }
        runSkill(skill)
    }

    func prepareEntry(_ deadline: Deadline, target: CalendarEntry.Target) {
        let today = DayDate(Date())
        entryDeadline = deadline
        entryDraft = CalendarEntryBuilder.entry(for: deadline, target: target, sender: deadlineSender, fallback: today, today: today)
        show(.entryPreview)
    }

    func setEntryDate(_ date: Date) {
        guard let e = entryDraft else { return }
        entryDraft = CalendarEntryBuilder.with(e, date: DayDate(date))
    }

    func applyEntry() {
        guard var draft = entryDraft else { return }
        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.title.isEmpty else { return }
        let entry = draft
        withAccess(entry.integration) { [weak self] in
            let title = entry.target == .reminder ? T("Adding it to Reminders…", table: "App") : T("Adding it to Calendar…", table: "App")
            self?.perform(title: title,
                          subtitle: "", writes: T("I’m creating a new entry", table: "App"), retry: { [weak self] in self?.applyEntry() }) { engine in
                try await engine.addEntry(entry)
            } done: { [weak self] receipt in
                guard let self else { return }
                self.entryDraft = nil
                self.finish(receipt)
                self.showResultToast(receipt, open: T("Open %@", table: "App", entry.integration.appName)) { Self.openApp(receipt.integration) }
            }
        }
    }

    /// "View selected mail" (menus): a call in Mail as with shortcut or pill, even if Mail is not in front.
    func readSelectedMail() {
        call(.menu, front: nil)
    }
}
