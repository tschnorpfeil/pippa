import Foundation

/// What the server needs for reading. The app supplies the real connections; tests and the end-to-end run supply stand-in readers.
public struct PippaMCPHost: Sendable {
    public var integrations: any AppIntegrations
    public var sheets: any SheetReading
    public var hostData: any HostDataReading
    /// `true`: show the system prompt on first use (it names Pippa, because Pippa reads itself). The person just
    /// asked for it; this corresponds to "asks the first time" in Pippa's settings.
    public var askForAccess: Bool
    public var now: @Sendable () -> Date
    public var calendar: Calendar
    /// Before the **first** system prompt when reading, the
    /// app shows Pippa's own sentence (`PippaMCPTools.accessExplanation`). `true`: continue to the system prompt; `false` ("Later"):
    /// ask nothing, read nothing. `nil`: straight to the system prompt (tests, end-to-end).
    public var explainAccess: (@Sendable (PippaMCPAccessSubject, String) async -> Bool)?
    /// After each tool call, what was read (or not), for Pippa's read receipt.
    public var onRead: (@Sendable (PippaMCPReadNote) -> Void)?
    /// After each write call (event, reminder, mail draft), what happened, for Pippa's receipt.
    public var onWrite: (@Sendable (PippaMCPWriteReceipt) -> Void)?
    /// The running answer on the Pi RPC path (`read_document`; PippaMCPTurn.swift).
    public var turns: PippaMCPTurns = .shared
    /// The app requires an active answer for MCP writes. Standalone hosts/checks may use independent actions.
    public var requireActiveWriteTurn = false
    /// Create events and reminders (PippaMCPWrite.swift). `nil`: the three tools say "not available right now".
    public var writer: (any HostWriting)?
    /// Uses the existing execution journal; a system host fails closed if it cannot open the journal.
    public var reminderJournal: Executor?
    public var requiresReminderJournal = false
    /// The same durable file jobs used by the native tray; unavailable storage blocks preparation.
    public var filePreparationStore: DurableJobStore?
    /// The app in front at the call, as the chip shows it for the running answer (`front_read`). `nil`: no chip.
    public var shownFront: @Sendable () -> FrontApp? = { FrontAppStage.shared.current }
    /// Where read mails and their attachments are saved as files (`MailFiling`); checks use their own folder.
    public var mailFiles: URL = MailFiling.inbox
    /// Reads that app (Safari, Chrome, the front document); Mail and Excel go through their own readers.
    public var front: any FrontAppReading = SystemFrontApp()

    public init(integrations: any AppIntegrations, sheets: any SheetReading, hostData: any HostDataReading, askForAccess: Bool = true,
                now: @escaping @Sendable () -> Date = { Date() }, calendar: Calendar = .autoupdatingCurrent,
                explainAccess: (@Sendable (PippaMCPAccessSubject, String) async -> Bool)? = nil,
                onRead: (@Sendable (PippaMCPReadNote) -> Void)? = nil) {
        self.integrations = integrations; self.sheets = sheets; self.hostData = hostData; self.askForAccess = askForAccess
        self.now = now; self.calendar = calendar; self.explainAccess = explainAccess; self.onRead = onRead
    }

    /// Real connections (EventKit, Apple Events in the Pippa process).
    public static func system() -> PippaMCPHost {
        let system = SystemIntegrations()
        var host = PippaMCPHost(integrations: system, sheets: system, hostData: system)
        host.writer = system
        host.requiresReminderJournal = true
        host.reminderJournal = try? Executor()
        host.filePreparationStore = try? DurableJobStore()
        return host
    }

    /// Invented data only, all permissions granted: PIPPA_DEMO=1 and end-to-end. Never touches real apps.
    public static func demo(now: Date = Date()) -> PippaMCPHost {
        let demo = DemoIntegrations(granted: true)
        var host = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(granted: true), hostData: DemoHostData(integrations: demo, now: now),
                                now: { Date() })
        host.writer = demo
        host.front = DemoFrontApp()
        return host
    }
}

/// What Pippa shows its own sentence for before the first system prompt.
public enum PippaMCPAccessSubject: Sendable, Equatable {
    case integration(Integration)
    case excel
    case photos
    /// The app in front (`front_read`), by its name.
    case front(String)

    public var appName: String {
        switch self {
        case .integration(let i): i.appName
        case .excel: ExcelScript.appName
        case .photos: PhotosLibrary.appName
        case .front(let name): name
        }
    }
}

/// A read receipt ("Kalender gelesen: heute", "Mail gelesen: „Betreff“"), built by Pippa's own
/// server from the call and its own result, never from model text. Reading changes nothing, so no undo.
public struct PippaMCPReadNote: Sendable, Equatable {
    /// Tool name without prefix, e.g. `calendar_read` (Pi calls it `mcp__pippa__calendar_read`).
    public var tool: String
    /// `false`: nothing read (no permission, app not open, wrong arguments).
    public var read: Bool
    /// The finished line in the app language.
    public var line: String
    /// For `mail_selected`: identity of the mail read (Message-ID, reply address, subject), so
    /// "Als Entwurf in Mail" replies to exactly this mail and not to whatever is selected at click time.
    public var mail: MailReplySource?
    /// What was read, as a card under the answer (calendar, mail search, photos search).
    public var card: ResultCard?
    /// Captured request origin, so late reads cannot appear under a newer answer.
    public var turnID: UUID?
    public var permissionRepair: PermissionRepairTarget?
    public init(tool: String, read: Bool, line: String, mail: MailReplySource? = nil, card: ResultCard? = nil,
                permissionRepair: PermissionRepairTarget? = nil) {
        self.tool = tool; self.read = read; self.line = line; self.mail = mail; self.card = card
        self.permissionRepair = permissionRepair
    }
}

/// Result of a tool: text (JSON) for the model, `isError` for Pi and Pippa's receipt.
public struct PippaMCPToolResult: Sendable, Equatable {
    public var text: String
    public var isError: Bool
    /// What a writing tool did, for Pippa's receipt (`PippaMCPHost.onWrite`; the model does not see it).
    public var receipt: PippaMCPWriteReceipt? = nil
    /// What a reading tool returned, as a card for the conversation (`PippaMCPReadNote.card`; the model does not see it).
    public var card: ResultCard? = nil
    /// Kept outside model-visible text; only native access checks can supply a repair destination.
    public var permissionRepair: PermissionRepairTarget? = nil
}
