import AppKit
import Carbon
import CryptoKit
import EventKit
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

    public func requestAccess(_ integration: Integration) async -> IntegrationAccess {
        switch integration {
        case .reminders, .calendar: return await eventKit.request(integration)
        case .mail:
            _ = await AppleEvents.launchHidden(integration)
            return await AppleEvents.permission(integration, ask: true)
        }
    }

    public func add(_ entry: CalendarEntry, tag: URL) async throws -> CreatedItem { try eventKit.add(entry, tag: tag) }

    public func remove(_ item: CreatedItem) async throws -> RemoveResult {
        switch item.integration {
        case .reminders, .calendar: return try eventKit.remove(item)
        case .mail: return .gone
        }
    }

    public func selectedMail() async throws -> MailMessage? { try await MailScript.selected() }

    public func insertReply(_ draft: MailDraft) async throws -> MailInsertResult { try await MailReplyScript.insert(draft) }

    public func events(in interval: DateInterval, limit: Int) async throws -> CalendarFetch { try eventKit.read(interval, limit: limit) }
}

// MARK: - EventKit

final class EventKitBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: EKEventStore?

    /// Create fresh after a new permission (otherwise the old store sees nothing).
    var store: EKEventStore {
        lock.withLock {
            if let cached { return cached }
            let s = EKEventStore()
            cached = s
            return s
        }
    }

    private static func type(_ i: Integration) -> EKEntityType { i == .reminders ? .reminder : .event }

    func access(_ i: Integration) -> IntegrationAccess {
        switch EKEventStore.authorizationStatus(for: Self.type(i)) {
        case .fullAccess: .granted
        // "Add only" is not enough for undo: ask again.
        case .notDetermined, .writeOnly: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    func request(_ i: Integration) async -> IntegrationAccess {
        let s = EKEventStore()
        do {
            if i == .reminders { _ = try await s.requestFullAccessToReminders() } else { _ = try await s.requestFullAccessToEvents() }
        } catch {
            return .denied
        }
        lock.withLock { cached = s }
        return access(i)
    }

    func add(_ entry: CalendarEntry, tag: URL) throws -> CreatedItem {
        guard access(entry.integration) == .granted else { throw PippaError.accessDenied(entry.integration.appName) }
        let s = store
        let cal = Calendar(identifier: .gregorian)
        var alert = DateComponents(); alert.year = entry.alertDay.year; alert.month = entry.alertDay.month; alert.day = entry.alertDay.day; alert.hour = 9
        let alarm = cal.date(from: alert).map { EKAlarm(absoluteDate: $0) }
        switch entry.target {
        case .calendar:
            guard let calendar = s.defaultCalendarForNewEvents else { throw PippaError.entryFailed(L("I can’t find a calendar.", table: "Core")) }
            let ev = EKEvent(eventStore: s)
            ev.calendar = calendar
            ev.title = entry.title
            ev.notes = entry.notes
            ev.url = tag
            ev.isAllDay = true
            let interval = entry.eventInterval(in: cal)
            ev.startDate = interval.start
            ev.endDate = interval.end
            if let alarm { ev.addAlarm(alarm) }
            try s.save(ev, span: .thisEvent, commit: true)
            return CreatedItem(integration: .calendar, identifier: ev.calendarItemIdentifier, modified: ev.lastModifiedDate, fingerprint: fingerprint(ev))
        case .reminder:
            guard let list = s.defaultCalendarForNewReminders() else { throw PippaError.entryFailed(L("I can’t find a reminders list.", table: "Core")) }
            let r = EKReminder(eventStore: s)
            r.calendar = list
            r.title = entry.title
            r.notes = entry.notes
            r.url = tag
            r.dueDateComponents = DateComponents(calendar: cal, year: entry.date.year, month: entry.date.month, day: entry.date.day)
            if let alarm { r.addAlarm(alarm) }
            try s.save(r, commit: true)
            return CreatedItem(integration: .reminders, identifier: r.calendarItemIdentifier, modified: r.lastModifiedDate, fingerprint: fingerprint(r))
        }
    }

    func remove(_ item: CreatedItem) throws -> RemoveResult {
        guard access(item.integration) == .granted else { throw PippaError.accessDenied(item.integration.appName) }
        let s = store
        guard let ci = s.calendarItem(withIdentifier: item.identifier) else { return .gone }
        if let expected = item.fingerprint, fingerprint(ci) != expected { return .changed }
        if let then = item.modified, let now = ci.lastModifiedDate, now != then { return .changed }
        if let ev = ci as? EKEvent { try s.remove(ev, span: .thisEvent, commit: true) }
        else if let r = ci as? EKReminder { try s.remove(r, commit: true) }
        else { return .gone }
        return .removed
    }

    /// Read only. All calendars for events, occurrences of recurring series as EventKit expands them; no notes,
    /// attendees or links, only what an answer needs. Never asks for permissions.
    func read(_ interval: DateInterval, limit: Int) throws -> CalendarFetch {
        guard access(.calendar) == .granted else { throw PippaError.accessDenied(Integration.calendar.appName) }
        let s = store
        s.refreshSourcesIfNecessary()
        let calendars = s.calendars(for: .event)
        guard !calendars.isEmpty else { return CalendarFetch(events: [], total: 0, calendars: []) }
        let predicate = s.predicateForEvents(withStart: interval.start, end: interval.end, calendars: calendars)
        let found = s.events(matching: predicate).sorted { $0.compareStartDate(with: $1) == .orderedAscending }
        let events = found.prefix(limit).map { ev in
            let status: CalendarEvent.Status = switch ev.status {
            case .canceled: .cancelled
            case .tentative: .tentative
            case .confirmed: .confirmed
            default: .none
            }
            let declined = ev.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
            return CalendarEvent(id: ev.eventIdentifier ?? ev.calendarItemIdentifier, title: ev.title ?? "", start: ev.startDate, end: ev.endDate,
                                 allDay: ev.isAllDay, calendar: ev.calendar?.title ?? "", timeZone: ev.isAllDay ? nil : ev.timeZone?.identifier,
                                 status: status, declined: declined, recurring: ev.hasRecurrenceRules || ev.isDetached, location: ev.location)
        }
        return CalendarFetch(events: Array(events), total: found.count, calendars: calendars.map(\.title).sorted())
    }

    /// Content only as a hash in the journal: also detect changes within one timestamp second.
    func fingerprint(_ item: EKCalendarItem) -> String {
        var parts = [item.title ?? "", item.notes ?? "", item.url?.absoluteString ?? "", item.calendar?.calendarIdentifier ?? ""]
        if let event = item as? EKEvent {
            parts += [String(event.startDate.timeIntervalSinceReferenceDate), String(event.endDate.timeIntervalSinceReferenceDate),
                      String(event.isAllDay), event.location ?? "", event.timeZone?.identifier ?? ""]
        }
        if let reminder = item as? EKReminder {
            parts += [String(describing: reminder.dueDateComponents), String(reminder.isCompleted), String(reminder.priority)]
        }
        for alarm in item.alarms ?? [] { parts += [String(describing: alarm.absoluteDate), String(alarm.relativeOffset)] }
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Apple Events

enum AppleEvents {
    static func isRunning(_ i: Integration) -> Bool { isRunning(bundle: i.bundleIdentifier) }

    static func isRunning(bundle: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty
    }

    /// Is the app installed on this Mac? (Only asks LaunchServices, starts nothing.)
    static func isInstalled(bundle: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil
    }

    /// Starts the app invisibly in the background if it is not running.
    static func launchHidden(_ i: Integration) async -> Bool {
        if isRunning(i) { return true }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: i.bundleIdentifier) else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        config.addsToRecentItems = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: config)
        for _ in 0..<25 where !isRunning(i) { try? await Task.sleep(for: .milliseconds(200)) }
        return isRunning(i)
    }

    /// May Pippa ask the app via Apple Events? `ask: true` shows the system prompt and waits for the answer,
    /// so not on the main thread.
    static func permission(_ i: Integration, ask: Bool) async -> IntegrationAccess {
        await permission(bundle: i.bundleIdentifier, appName: i.appName, ask: ask)
    }

    /// As above, for apps without their own case in `Integration` (Excel).
    static func permission(bundle: String, appName: String, ask: Bool) async -> IntegrationAccess {
        let status: OSStatus = await Task.detached(priority: .userInitiated) {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundle)
            guard let desc = target.aeDesc else { return OSStatus(procNotFound) }
            // With a prompt, wildcards are not allowed: a concrete read event (core/getd).
            return AEDeterminePermissionToAutomateTarget(desc, AEEventClass(kCoreEventClass), AEEventID(kAEGetData), ask)
        }.value
        switch Int(status) {
        case Int(noErr): return .granted
        case -1744: return .notDetermined           // errAEEventWouldRequireUserConsent
        case -1743: return .denied                  // errAEEventNotPermitted
        case Int(procNotFound): return .unavailable(L("%@ isn’t open right now.", table: "Core", appName))
        default: return .unavailable(L("%@ isn’t responding right now.", table: "Core", appName))
        }
    }

    /// Calls a handler of an AppleScript with parameters. Texts go in as parameters,
    /// never into the script text, so nothing can be injected.
    /// Only inside `perform`.
    static func call(_ source: String, handler: String, _ args: [NSAppleEventDescriptor] = [], app: Integration) throws -> NSAppleEventDescriptor {
        try call(source, handler: handler, args, appName: app.appName)
    }

    /// AppleScript runs on its own serial queue, not the main thread: a slow Mail or Excel (up to 20 s) never freezes
    /// the pill. NSAppleScript is not thread-safe, so every script and the compiled cache stay on this one queue.
    private static let queue = DispatchQueue(label: "app.pippa.applescript", qos: .userInitiated)

    static func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }

    /// Compiled once per source text (the Mail reply search calls the same script once per mailbox).
    /// Handlers keep no state between calls: every value they use comes in as a parameter. Only touched on `queue`.
    nonisolated(unsafe) private static var compiled: [String: NSAppleScript] = [:]

    /// As above; `appName` only for the error message (no permission, app not open). Only inside `perform`.
    static func call(_ source: String, handler: String, _ args: [NSAppleEventDescriptor] = [], appName: String) throws -> NSAppleEventDescriptor {
        var error: NSDictionary?
        let script: NSAppleScript
        if let known = compiled[source] {
            script = known
        } else {
            guard let fresh = NSAppleScript(source: source), fresh.compileAndReturnError(&error) else { throw PippaError.notAvailable }
            compiled[source] = fresh
            script = fresh
        }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kASAppleScriptSuite), eventID: AEEventID(kASSubroutineEvent),
                                           targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string: handler.lowercased()), forKeyword: AEKeyword(keyASSubroutineName))
        let list = NSAppleEventDescriptor.list()
        for (i, a) in args.enumerated() { list.insert(a, at: i + 1) }
        event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        let result = script.executeAppleEvent(event, error: &error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            switch code {
            case -1743, -1744: throw PippaError.accessDenied(appName)
            case -600, -609: throw PippaError.appNotOpen(appName)
            default: throw PippaError.notAvailable
            }
        }
        return result
    }

    static func items(_ d: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard d.descriptorType == typeAEList, d.numberOfItems > 0 else { return [] }
        return (1...d.numberOfItems).compactMap { d.atIndex($0) }
    }

    static func strings(_ d: NSAppleEventDescriptor?) -> [String] {
        guard let d else { return [] }
        return items(d).map { $0.stringValue ?? "" }
    }
}

// MARK: Mail (read only)

enum MailScript {
    static let source = """
    on selectedMessage()
        tell application id "com.apple.mail"
            set sel to selection
            if (count of sel) is 0 then return {}
            set m to item 1 of sel
            set attachmentNames to {}
            repeat with a in (mail attachments of m)
                set end of attachmentNames to (name of a)
            end repeat
            set theID to ""
            try
                set theID to (message id of m) as text
            end try
            set theLocation to {}
            try
                set box to mailbox of m
                set boxPath to {(name of box) as text}
                set acctName to ""
                try
                    set acctName to (name of account of box) as text
                end try
                set cur to box
                repeat 31 times
                    try
                        set parentBox to container of cur
                        if class of parentBox is not mailbox then exit repeat
                        set beginning of boxPath to (name of parentBox) as text
                        set cur to parentBox
                    on error
                        exit repeat
                    end try
                end repeat
                set theLocation to {acctName, boxPath, (id of m)}
            end try
            return {subject of m, sender of m, date received of m, content of m, attachmentNames, theID, (reply to of m) as text, theLocation}
        end tell
    end selectedMessage
    """

    static func selected() async throws -> MailMessage? {
        try await AppleEvents.perform { () throws -> MailMessage? in
            let r = try AppleEvents.call(source, handler: "selectedMessage", app: .mail)
            let parts = AppleEvents.items(r)
            guard parts.count >= 5 else { return nil }
            let rawID = parts.count >= 6 ? (parts[5].stringValue ?? "") : ""
            let messageID: String? = rawID.isEmpty ? nil : rawID
            let locator = parts.count >= 8 ? MailReplyScript.locator(ScriptValue(parts[7])) : nil
            return MailMessage(subject: parts[0].stringValue ?? "", sender: parts[1].stringValue ?? "", date: parts[2].dateValue,
                               body: parts[3].stringValue ?? "", attachmentNames: AppleEvents.strings(parts[4]), messageID: messageID,
                               replyTo: parts.count >= 7 ? parts[6].stringValue : nil, locator: locator)
        }
    }
}

// MARK: Mail (insert unsent reply)

/// Native replies to the captured original. No fallback compose is created, nothing is ever sent.
///
/// Mail 16 (macOS 27): `set content` has no effect on a
/// reply and its content reads back empty. `make new paragraph at end of content` does work and reads back;
/// `save` makes the open window show it (the editor otherwise keeps what it loaded first); threading headers stay.
/// Mail's own quote is replaced that way, so the script appends a plain quote built from the original.
/// Order: find the original (captured mailbox first, then a bounded search in steps), reply, fill, read back,
/// save as an unsent draft. Only failures before `reply` leave nothing in Mail.
enum MailReplyScript {
    static let source = """
    on replyAt(theID, mailID, acctName, boxPath, theAddress, theSubject, theBody, quoteHeader)
        if theID is "" then return {"missing"}
        tell application id "com.apple.mail"
            try
                with timeout of 20 seconds
                    set box to my mailboxAt(acctName, boxPath)
                    set found to (messages of box whose id is mailID)
                end timeout
            on error number errNum
                -- Read-only so far: nothing is in Mail.
                if errNum is -1712 then return {"busy"}
                return {"notHere"}
            end try
            if (count of found) is not 1 then return {"notHere"}
            set m to item 1 of found
            set exactIdentity to false
            try
                set candidateID to (message id of m) as text
                considering case
                    if candidateID is theID or candidateID is ("<" & theID & ">") then set exactIdentity to true
                end considering
            end try
            if not exactIdentity then return {"notHere"}
        end tell
        return my openReply(m, theAddress, theSubject, theBody, quoteHeader)
    end replyAt

    on openReply(m, theAddress, theSubject, theBody, quoteHeader)
        set quoteText to ""
        try
            set quoteText to my quoteOf(m, quoteHeader)
        on error number errNum
            -- Mail stalls while reading the original: stop before anything is created.
            if errNum is -1712 then return {"busy"}
        end try
        tell application id "com.apple.mail"
            try
                -- Mail 16 opens the reply window right away, whatever "opening window" says.
                with timeout of 30 seconds
                    set r to reply m
                end timeout
            on error number errNum
                -- A stalled Mail may still open the reply later.
                if errNum is -1712 then return {"uncertain"}
                return {"failed"}
            end try
            try
                with timeout of 30 seconds
                    set subject of r to theSubject
                    delete every to recipient of r
                    if theAddress is not "" then
                        tell r to make new to recipient at end of to recipients with properties {address:theAddress}
                    end if
                    tell r to make new paragraph at end of content with data (theBody & linefeed)
                    if quoteText is not "" then tell r to make new paragraph at end of content with data (linefeed & quoteText & linefeed)
                    set readBody to (content of r) as text
                    set readSubject to (subject of r) as text
                    set addresses to {}
                    repeat with targetRecipient in to recipients of r
                        set end of addresses to (address of targetRecipient) as text
                    end repeat
                end timeout
            on error
                -- The window is open but its fields are unknown: leave it to the person, never close it.
                try
                    activate
                end try
                return {"shown"}
            end try
            -- Saving makes the window show the filled content even if its editor loaded first; the reply
            -- becomes an unsent draft in Mail's Drafts, as a reply draft should.
            set saved to false
            try
                with timeout of 30 seconds
                    save r
                end timeout
                set saved to true
            end try
            try
                activate
            end try
            return {"reply", readSubject, readBody, addresses, saved}
        end tell
    end openReply

    on quoteOf(m, quoteHeader)
        tell application id "com.apple.mail"
            with timeout of 20 seconds
                set original to (content of m) as text
                set d to date received of m
                set who to (sender of m) as text
            end timeout
        end tell
        if (length of original) > 20000 then set original to (text 1 thru 20000 of original) & linefeed & "[…]"
        repeat while original is not "" and {linefeed, return, space, tab} contains (last character of original)
            if (length of original) is 1 then
                set original to ""
            else
                set original to text 1 thru -2 of original
            end if
        end repeat
        set hh to text -2 thru -1 of ("0" & ((hours of d) as text))
        set mm to text -2 thru -1 of ("0" & ((minutes of d) as text))
        set header to my replaced(my replaced(quoteHeader, "{date}", (short date string of d) & " " & hh & ":" & mm), "{sender}", who)
        set out to {header}
        repeat with p in paragraphs of original
            set lineText to contents of p
            if lineText is "" then
                set end of out to ">"
            else
                set end of out to "> " & lineText
            end if
        end repeat
        set AppleScript's text item delimiters to linefeed
        set q to out as text
        set AppleScript's text item delimiters to ""
        return q
    end quoteOf

    on replaced(theText, token, value)
        set AppleScript's text item delimiters to token
        set parts to text items of theText
        set AppleScript's text item delimiters to value
        set joined to parts as text
        set AppleScript's text item delimiters to ""
        return joined
    end replaced

    on mailboxAt(acctName, boxPath)
        tell application id "com.apple.mail"
            if acctName is "" then
                set box to mailbox (item 1 of boxPath)
            else
                set box to mailbox (item 1 of boxPath) of account acctName
            end if
            repeat with i from 2 to count of boxPath
                set box to mailbox (item i of boxPath) of box
            end repeat
            return box
        end tell
    end mailboxAt

    on mailboxList()
        set out to {}
        tell application id "com.apple.mail"
            try
                with timeout of 20 seconds
                    repeat with acct in accounts
                        set acctName to (name of acct) as text
                        repeat with box in mailboxes of acct
                            my collectBoxes(box, acctName, {}, out)
                        end repeat
                    end repeat
                    -- On My Mac: the app-level list also holds nested mailboxes; walk only from those without a parent.
                    repeat with box in mailboxes
                        set isTop to true
                        try
                            if class of (container of box) is mailbox then set isTop to false
                        end try
                        if isTop then my collectBoxes(box, "", {}, out)
                    end repeat
                end timeout
            on error number errNum
                if errNum is -1712 then return {"timeout"}
                return {"failed"}
            end try
        end tell
        return {"ok", out}
    end mailboxList

    on collectBoxes(box, acctName, parentPath, out)
        tell application id "com.apple.mail"
            set boxPath to parentPath & {(name of box) as text}
            set end of out to {acctName, boxPath, ""}
            repeat with childBox in mailboxes of box
                my collectBoxes(childBox, acctName, boxPath, out)
            end repeat
        end tell
    end collectBoxes

    on findIn(theID, acctName, boxPath)
        tell application id "com.apple.mail"
            try
                with timeout of 15 seconds
                    set box to my mailboxAt(acctName, boxPath)
                    set found to (every message of box whose message id is theID or message id is ("<" & theID & ">"))
                    set ids to {}
                    repeat with candidate in found
                        set candidateID to (message id of candidate) as text
                        set exactIdentity to false
                        considering case
                            if candidateID is theID or candidateID is ("<" & theID & ">") then set exactIdentity to true
                        end considering
                        if exactIdentity then set end of ids to (id of candidate)
                    end repeat
                end timeout
                return {"ok", ids}
            on error number errNum
                if errNum is -1712 then return {"timeout"}
                return {"skip"}
            end try
        end tell
    end findIn

    on newMessage(theAddress, theName, theSubject, theBody)
        tell application id "com.apple.mail"
            set nm to make new outgoing message with properties {subject:theSubject, content:theBody, visible:true}
            if theAddress is not "" then
                if theName is "" then
                    tell nm to make new to recipient at end of to recipients with properties {address:theAddress}
                else
                    tell nm to make new to recipient at end of to recipients with properties {address:theAddress, name:theName}
                end if
            end if
            activate
            set recipientAddresses to {}
            repeat with targetRecipient in to recipients of nm
                set end of recipientAddresses to (address of targetRecipient) as text
            end repeat
            return {(subject of nm) as text, (content of nm) as text, recipientAddresses}
        end tell
    end newMessage
    """

    static func insert(_ draft: MailDraft) async throws -> MailInsertResult {
        guard draft.isReply else { return try await newMessage(draft) }
        guard let id = draft.messageID.flatMap(MailReplySource.canonicalMessageID) else { throw MailReplyFailure.missingOriginal }
        // Fast path: the mailbox and Mail id captured at Call, re-checked by Message-ID in the script.
        if let hint = draft.locator, hint.mailID != nil {
            let response = try await replyAt(hint, id: id, draft: draft)
            if response.first?.text != "notHere" { return try outcome(response, draft: draft) }
        }
        let match = try await search(id, hint: draft.locator)
        let response = try await replyAt(match, id: id, draft: draft)
        // Moved again between search and reply: nothing was created.
        if response.first?.text == "notHere" { throw MailReplyFailure.notCreated }
        return try outcome(response, draft: draft)
    }

    /// Bounded search in steps: one Apple Event per mailbox, so Stop (task cancellation) and progress work
    /// between mailboxes and no single event waits for Mail's whole store.
    private static func search(_ id: String, hint: MailLocator?) async throws -> MailLocator {
        try Task.checkCancellation()
        let listed = try await run("mailboxList", [])
        guard listed.first?.text == "ok", listed.count == 2 else { throw MailReplyFailure.notCreated }
        let boxes = MailOriginalSearch.ordered(listed[1].items.compactMap(locator), preferring: hint)
        let clock = ContinuousClock(), deadline = clock.now + MailOriginalSearch.budget
        var matches: [MailLocator] = [], incomplete = false
        for (index, box) in boxes.enumerated() {
            try Task.checkCancellation()
            MailOriginalSearch.progress?(index, boxes.count)
            if clock.now > deadline { incomplete = true; break }
            let found = try await run("findIn", [.text(id), .text(box.account), .texts(box.path)])
            switch found.first?.text {
            case "ok" where found.count == 2:
                matches += found[1].items.compactMap { MailLocator(account: box.account, path: box.path, mailID: $0.number) }
            case "timeout": incomplete = true
            default: continue
            }
        }
        MailOriginalSearch.progress?(boxes.count, boxes.count)
        try Task.checkCancellation()
        return try MailOriginalSearch.decide(matches, incomplete: incomplete)
    }

    private static func replyAt(_ box: MailLocator, id: String, draft: MailDraft) async throws -> [ScriptValue] {
        guard let mailID = box.mailID else { return [.text("notHere")] }
        try Task.checkCancellation()
        let header = L("On {date}, {sender} wrote:", table: "Core")
        return try await run("replyAt", [.text(id), .number(Int32(mailID)), .text(box.account), .texts(box.path),
                                         .text(draft.to ?? ""), .text(draft.replySubject), .text(draft.body), .text(header)])
    }

    private static func outcome(_ response: [ScriptValue], draft: MailDraft) throws -> MailInsertResult {
        let status = response.first?.text ?? ""
        let filled = response.count == 5
        if status == "reply", !filled { throw MailReplyFailure.unconfirmed }
        return try draft.replyOutcome(status: status, subject: filled ? (response[1].text ?? "") : "",
                                      body: filled ? (response[2].text ?? "") : "",
                                      recipients: filled ? response[3].items.map { $0.text ?? "" } : [],
                                      saved: filled && response[4].flag == true)
    }

    private static func newMessage(_ draft: MailDraft) async throws -> MailInsertResult {
        let created = try await run("newMessage", [.text(draft.to ?? ""), .text(draft.toName ?? ""), .text(draft.replySubject), .text(draft.body)])
        guard created.count == 3,
              draft.isConfirmed(subject: created[0].text ?? "", body: created[1].text ?? "",
                                recipients: created[2].items.map { $0.text ?? "" }) else { throw PippaError.notAvailable }
        return .newMessage
    }

    /// One short step on the AppleScript queue.
    private static func run(_ handler: String, _ args: [ScriptArgument]) async throws -> [ScriptValue] {
        let result = try await AppleEvents.perform {
            ScriptValue(try AppleEvents.call(source, handler: handler, args.map(\.descriptor), app: .mail))
        }.items
        await Task.yield()
        return result
    }

    /// `{account, {mailbox names…}, id}` from `selectedMessage`, or `{account, {names…}, key}` from `mailboxList`.
    static func locator(_ value: ScriptValue) -> MailLocator? {
        let parts = value.items
        guard parts.count == 3, let account = parts[0].text else { return nil }
        return MailLocator(account: account, path: parts[1].items.compactMap(\.text), mailID: parts[2].number)
    }
}

/// Handler parameters as plain values, so they can cross to the AppleScript queue.
enum ScriptArgument: Sendable {
    case text(String), number(Int32), texts([String])

    var descriptor: NSAppleEventDescriptor {
        switch self {
        case .text(let s): return NSAppleEventDescriptor(string: s)
        case .number(let n): return NSAppleEventDescriptor(int32: n)
        case .texts(let strings):
            let list = NSAppleEventDescriptor.list()
            for (i, s) in strings.enumerated() { list.insert(NSAppleEventDescriptor(string: s), at: i + 1) }
            return list
        }
    }
}

/// A script result as plain values (lists, texts, integers), read on the AppleScript queue.
indirect enum ScriptValue: Sendable {
    case text(String), number(Int), flag(Bool), list([ScriptValue]), other

    init(_ d: NSAppleEventDescriptor) {
        switch d.descriptorType {
        case typeAEList: self = .list(AppleEvents.items(d).map(ScriptValue.init))
        case typeSInt32: self = .number(Int(d.int32Value))
        case typeTrue, typeFalse, typeBoolean: self = .flag(d.booleanValue)
        default: self = d.stringValue.map(ScriptValue.text) ?? .other
        }
    }

    var text: String? { if case .text(let s) = self { return s }; return nil }
    var flag: Bool? { if case .flag(let b) = self { return b }; return nil }
    var number: Int? { if case .number(let n) = self { return n }; return nil }
    var items: [ScriptValue] { if case .list(let l) = self { return l }; return [] }
}

/// For checks only: can the scripts be compiled? (Only reads the apps' dictionaries, sends nothing.)
public enum IntegrationScripts {
    /// Name and text of all scripts, for `compileAll` and the check that none calls `send`.
    public static var sources: [(name: String, source: String)] {
        [("Mail", MailScript.source), ("MailReply", MailReplyScript.source), ("MailSearch", MailSearchScript.source), ("Excel", ExcelScript.source)]
    }

    /// Scripts for apps that are not part of macOS. Their terms (`active workbook`, `used range` ...) exist only in the
    /// app's dictionary; without the app the script cannot be compiled (AppleScript then asks for the app).
    /// CI has no Excel: there "Excel" is missing from the result of `compileAll` instead of being `false`.
    public static let thirdPartyApps: [String: String] = ["Excel": ExcelScript.bundleIdentifier]

    @MainActor
    public static func compileAll() -> [String: Bool] {
        var out: [String: Bool] = [:]
        for (name, source) in sources {
            if let bundle = thirdPartyApps[name], !AppleEvents.isInstalled(bundle: bundle) { continue }
            var error: NSDictionary?
            out[name] = NSAppleScript(source: source)?.compileAndReturnError(&error) ?? false
        }
        return out
    }
}
