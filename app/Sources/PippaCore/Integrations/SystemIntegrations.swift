import Foundation

/// The real integrations: EventKit for reminders and calendar, Apple Events (NSAppleScript in
/// our own process, no `osascript`) for reading the selected mail and the Excel selection (ExcelScript.swift). Never asks for permissions on its own:
/// `requestAccess` is only called when the person is using the feature right now.
public final class SystemIntegrations: AppIntegrations, @unchecked Sendable {
    let eventKit = EventKitBridge()

    public init() {}

    public func access(_ integration: Integration) async -> IntegrationAccess {
        switch integration {
        case .reminders, .calendar: return eventKit.access(integration)
        case .mail:
            guard AppleEvents.isRunning(integration) else {
                return .unavailable(L("First open Mail and select an email there. Then try again.", table: "Core"))
            }
            return await AppleEvents.permission(integration, ask: false)
        }
    }

    public func prepareMailAccess() async -> IntegrationAccess {
        guard !Task.isCancelled, await AppleEvents.launchHidden(.mail), !Task.isCancelled else {
            return .unavailable(L("%@ isn’t open right now.", table: "Core", Integration.mail.appName))
        }
        return await AppleEvents.permission(.mail, ask: false)
    }

    public func requestAccess(_ integration: Integration) async -> IntegrationAccess {
        switch integration {
        case .reminders, .calendar: return await eventKit.request(integration)
        case .mail:
            guard await AppleEvents.launchHidden(integration) else {
                return .unavailable(L("%@ isn’t open right now.", table: "Core", integration.appName))
            }
            return await AppleEvents.permission(integration, ask: true)
        }
    }

    public func remove(_ item: CreatedItem) async throws -> RemoveResult {
        switch item.integration {
        case .reminders, .calendar: return try eventKit.remove(item)
        case .mail: return .gone
        }
    }

    public func selectedMail() async throws -> MailMessage? { try await MailScript.selected() }
    public func findMail(subject: String, sender: String) async throws -> MailMessage? {
        guard AppleEvents.isRunning(.mail) else { throw PippaError.appNotOpen(Integration.mail.appName) }
        return try await MailScript.find(subject: subject, sender: sender)
    }

    public func findMail(messageID: String) async throws -> MailMessage? {
        guard let wanted = MailReplySource.canonicalMessageID(messageID) else { return nil }
        guard AppleEvents.isRunning(.mail) else { throw PippaError.appNotOpen(Integration.mail.appName) }
        // Mail's `whose` match ignores case; only the exact id counts.
        guard let mail = try await MailScript.find(messageID: wanted), mail.messageID.flatMap(MailReplySource.canonicalMessageID) == wanted else { return nil }
        return mail
    }

    public func insertReply(_ draft: MailDraft) async throws -> MailInsertResult { try await MailReplyScript.insert(draft) }

    public func events(in interval: DateInterval, limit: Int) async throws -> CalendarFetch { try eventKit.read(interval, limit: limit) }
}
