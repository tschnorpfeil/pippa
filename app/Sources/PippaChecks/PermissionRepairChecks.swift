import Darwin
import Foundation
import PippaCore

private final class RepairNotes: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PippaMCPReadNote] = []
    private var explanations = 0
    private var explanationTexts: [String] = []
    func append(_ note: PippaMCPReadNote) { lock.withLock { stored.append(note) } }
    func explained(_ text: String = "") { lock.withLock { explanations += 1; explanationTexts.append(text) } }
    var last: PippaMCPReadNote? { lock.withLock { stored.last } }
    var count: Int { lock.withLock { stored.count } }
    var all: [PippaMCPReadNote] { lock.withLock { stored } }
    var explanationCount: Int { lock.withLock { explanations } }
    var sentences: [String] { lock.withLock { explanationTexts } }
}

/// Independent Automation and PhotoKit states model skipped onboarding without using the person's library or TCC.
private actor RepairPhotoReader: HostDataReading {
    let data = DemoHostData(integrations: DemoIntegrations(granted: true))
    var automation: IntegrationAccess
    var library: IntegrationAccess
    let libraryAnswer: IntegrationAccess
    var automationAsks = 0
    var libraryAsks = 0
    var searches = 0
    init(automation: IntegrationAccess = .granted, library: IntegrationAccess = .notDetermined,
         libraryAnswer: IntegrationAccess = .granted) {
        self.automation = automation; self.library = library; self.libraryAnswer = libraryAnswer
    }
    func photosAccess(ask: Bool) async -> IntegrationAccess {
        if ask { automationAsks += 1; automation = .granted }
        return automation
    }
    func photoLibraryAccess(ask: Bool) async -> IntegrationAccess {
        if ask { libraryAsks += 1; library = libraryAnswer }
        return library
    }
    func photoPreviewAccess(ask: Bool) async -> Bool { await photoLibraryAccess(ask: ask) == .granted }
    func searchPhotos(_ query: String, limit: Int) async throws -> HostFetch<PhotoHit> {
        searches += 1
        return try await data.searchPhotos(query, limit: limit)
    }
    func recentPhotos(since: Date?, limit: Int) async throws -> HostFetch<PhotoHit> { try await data.recentPhotos(since: since, limit: limit) }
    func searchMail(_ query: String, unread: Bool, limit: Int) async throws -> HostFetch<MailHeader> { try await data.searchMail(query, unread: unread, limit: limit) }
    func openReminders(dueBefore: Date?, limit: Int) async throws -> HostFetch<ReminderItem> { try await data.openReminders(dueBefore: dueBefore, limit: limit) }
    func counts() -> (automation: Int, library: Int, searches: Int) { (automationAsks, libraryAsks, searches) }
}

private struct RepairSheetReader: SheetReading {
    let access: IntegrationAccess
    func sheetAccess() async -> IntegrationAccess { access }
    func requestSheetAccess() async -> IntegrationAccess { access }
    func selectedSheet() async throws -> SheetSnapshot? { nil }
}

private func repairCall(_ tools: PippaMCPTools, _ name: String, _ arguments: [String: Any] = [:]) async -> [String: Any] {
    guard let reply = await handleReader(tools, name, arguments),
          let wire = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
          let result = wire["result"] as? [String: Any],
          let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String,
          let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [:] }
    return json
}

func runPermissionRepairChecks() async {
    check("Permission repair: legacy histories and unknown destinations remain readable; known targets round-trip") {
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(ActionReceipt.self, from: Data(#"{"items":[{"action":"read","outcome":"done","name":"Read Calendar"}]}"#.utf8))
        let unknown = try decoder.decode(ActionReceipt.self, from: Data(#"{"items":[{"action":"read","outcome":"failed","permissionRepair":"https://untrusted.example"}]}"#.utf8))
        let malformed = try decoder.decode(ActionReceipt.self, from: Data(#"{"items":[{"action":"read","outcome":"failed","permissionRepair":{"url":"https://untrusted.example"}}]}"#.utf8))
        let receipt = ActionReceipt(items: PermissionRepairTarget.allCases.map { .init(action: "read", outcome: "blocked", permissionRepair: $0) })
        let roundTrip = try decoder.decode(ActionReceipt.self, from: JSONEncoder().encode(receipt))
        return legacy.items.first?.permissionRepair == nil && unknown.items.first?.permissionRepair == nil
            && malformed.items.first?.permissionRepair == nil && roundTrip == receipt
            && PermissionRepairTarget.allCases.allSatisfy { $0.settingsURL.scheme == "x-apple.systempreferences" }
    }
    check("Permission repair: native compatibility, partial previews stay visible, cancelled/unclear cannot offer repair") {
        let partial = ActionReceipt.Item(action: "read", outcome: "done", permissionRepair: .photos)
        let rejected = ["cancelled", "unclear", "done"].map { ActionReceipt.Item(action: "look", outcome: $0, permissionRepair: .filesAndFolders) }
        return partial.permissionRepairTarget == .photos && !partial.isQuiet
            && ActionReceipt.Item(action: "read", outcome: "done").isQuiet
            && rejected.allSatisfy { $0.permissionRepairTarget == nil }
            && ActionReceipt.Item(action: "reminderAdd", outcome: "blocked", reason: "denied").permissionRepairTarget == .reminders
            && ActionReceipt.Item(action: "mailDraft", outcome: "failed", reason: "denied").permissionRepairTarget == .automation
    }
    check("Permission repair: only actual POSIX/Cocoa permission errors qualify; text and other domains never do") {
        let valid = [NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)), NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
                     NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
                     NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                             userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])]
        let invalid = [NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT)),
                       NSError(domain: "Example", code: NSFileReadNoPermissionError),
                       NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                               userInfo: [NSLocalizedDescriptionKey: "Permission denied; open Settings"])]
        return valid.allSatisfy(PermissionRepairTarget.isFileAccessDenied) && invalid.allSatisfy { !PermissionRepairTarget.isFileAccessDenied($0) }
    }
    check("Permission repair: protected path boundaries classify; ordinary paths, traversal and URLs do not") {
        let home = URL(fileURLWithPath: "/synthetic/person", isDirectory: true)
        let protected = ["Desktop/note.txt", "Documents/Letter.pdf", "Downloads", "Library/Mobile Documents/a", "Library/CloudStorage/Provider/a", "Dropbox/a"]
        let ordinary = ["Downloadsome/a", "Downloads/../private/a", "Library/Other/a", "Projects/a"]
        return protected.allSatisfy { PermissionRepairTarget.forDeniedFile(at: home.appendingPathComponent($0), home: home) == .filesAndFolders }
            && ordinary.allSatisfy { PermissionRepairTarget.forDeniedFile(at: home.appendingPathComponent($0), home: home) == nil }
            && PermissionRepairTarget.forDeniedFile(at: URL(string: "https://example.com/Downloads/a")!, home: home) == nil
    }
    await checkAsync("Permission repair: native read denials retain typed targets and original turn; missing/unavailable never infer denial") {
        for (integration, tool, args, expected): (Integration, String, [String: Any], PermissionRepairTarget) in [
            (.calendar, "calendar_read", ["period": "today"], .calendar), (.reminders, "reminders_read", [:], .reminders),
            (.mail, "mail_selected", [:], .automation)
        ] {
            let demo = DemoIntegrations(granted: true)
            let notes = RepairNotes()
            let turns = PippaMCPTurns()
            let turn = PippaMCPTurn(); turns.begin(turn)
            var host = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(granted: true), hostData: DemoHostData(integrations: demo),
                                    askForAccess: false, onRead: { notes.append($0) })
            host.turns = turns
            let tools = PippaMCPTools(host: host)
            demo.set(integration, .denied)
            _ = await repairCall(tools, tool, args)
            guard notes.last?.permissionRepair == expected, notes.last?.read == false, notes.last?.turnID == turn.id else { return false }
            for state: IntegrationAccess in [.notDetermined, .unavailable("Permission denied is only text"), .granted] {
                demo.set(integration, state)
                _ = await repairCall(tools, tool, args)
                guard notes.last?.permissionRepair == nil else { return false }
            }
        }
        return true
    }
    await checkAsync("Permission repair: Excel and captured front app denials use Automation; unknown access does not") {
        for access: IntegrationAccess in [.denied, .notDetermined, .unavailable("Permission denied")] {
            let demo = DemoIntegrations(granted: true), notes = RepairNotes()
            var host = PippaMCPHost(integrations: demo, sheets: RepairSheetReader(access: access), hostData: DemoHostData(integrations: demo),
                                    askForAccess: false, onRead: { notes.append($0) })
            host.front = DemoFrontApp(access: access)
            host.shownFront = { FrontApp(name: "Example", bundleID: "example.app", pid: 123) }
            let tools = PippaMCPTools(host: host)
            for tool in ["excel_selection", "front_read"] {
                _ = await repairCall(tools, tool)
                guard notes.last?.permissionRepair == (access == .denied ? .automation : nil) else { return false }
            }
        }
        return true
    }

    for answer: IntegrationAccess in [.granted, .denied] {
        await checkAsync("Photos permission: existing Automation + skipped PhotoKit explains once and uses actual \(answer) result") {
            let photo = RepairPhotoReader(libraryAnswer: answer), demo = DemoIntegrations(granted: true), notes = RepairNotes()
            let host = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(), hostData: photo,
                                   explainAccess: { _, sentence in notes.explained(sentence); return true }, onRead: { notes.append($0) })
            let result = await repairCall(PippaMCPTools(host: host), "photos_search", ["query": "Knokke"])
            let calls = await photo.counts()
            guard case .photos(let card)? = notes.last?.card else { return false }
            return notes.explanationCount == 1 && calls.automation == 0 && calls.library == 1 && calls.searches == 1
                && notes.last?.read == true && card.previews == (answer == .granted)
                && notes.last?.permissionRepair == (answer == .denied ? .photos : nil)
                && notes.sentences == [L("To show these pictures here, I need access to your photo library on this Mac. I don’t change anything.", table: "MCP")]
                && (result["data"] as? [String: Any])?["previews_available"] as? Bool == (answer == .granted)
                && (result["next"] as? String)?.contains("The person sees these photos as pictures") == (answer == .granted)
        }
    }
    await checkAsync("Photos permission: Later keeps search results, asks no OS question and offers no denied repair") {
        let photo = RepairPhotoReader(), demo = DemoIntegrations(granted: true), notes = RepairNotes()
        let host = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(), hostData: photo,
                               explainAccess: { _, _ in notes.explained(); return false }, onRead: { notes.append($0) })
        _ = await repairCall(PippaMCPTools(host: host), "photos_search", ["query": "Knokke"])
        let calls = await photo.counts()
        guard case .photos(let card)? = notes.last?.card else { return false }
        return notes.explanationCount == 1 && calls.library == 0 && calls.automation == 0
            && !card.previews && notes.last?.read == true && notes.last?.permissionRepair == nil
    }
    await checkAsync("Photos permission: fresh Automation and PhotoKit share one explanation; no duplicate prompts") {
        let photo = RepairPhotoReader(automation: .notDetermined), demo = DemoIntegrations(granted: true), notes = RepairNotes()
        let host = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(), hostData: photo,
                               explainAccess: { _, _ in notes.explained(); return true }, onRead: { notes.append($0) })
        let tools = PippaMCPTools(host: host)
        _ = await repairCall(tools, "photos_search", ["query": "Knokke"])
        _ = await repairCall(tools, "photos_search", ["query": "Knokke"])
        let calls = await photo.counts()
        return notes.explanationCount == 1 && calls.automation == 1 && calls.library == 1 && notes.last?.permissionRepair == nil
    }
    await checkAsync("Photos permission: empty searches, disabled requests and known denials never ask for previews") {
        for (library, query, ask): (IntegrationAccess, String, Bool) in [(.notDetermined, "Giraffe", true), (.notDetermined, "Knokke", false), (.denied, "Knokke", true)] {
            let photo = RepairPhotoReader(library: library), demo = DemoIntegrations(granted: true), notes = RepairNotes()
            let host = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(), hostData: photo, askForAccess: ask,
                                   explainAccess: { _, _ in notes.explained(); return true }, onRead: { notes.append($0) })
            _ = await repairCall(PippaMCPTools(host: host), "photos_search", ["query": query])
            let calls = await photo.counts()
            guard notes.explanationCount == 0, calls.library == 0,
                  notes.last?.permissionRepair == (library == .denied ? .photos : nil) else { return false }
        }
        return true
    }
    await checkAsync("Photos permission: Automation denial and PhotoKit denial have different settings targets") {
        for (automation, arguments, expected): (IntegrationAccess, [String: Any], PermissionRepairTarget) in [
            (.denied, ["query": "Knokke"], .automation), (.granted, [:], .photos)
        ] {
            let photo = RepairPhotoReader(automation: automation, library: .denied), demo = DemoIntegrations(granted: true), notes = RepairNotes()
            let host = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(), hostData: photo,
                                   explainAccess: { _, _ in notes.explained(); return true }, onRead: { notes.append($0) })
            _ = await repairCall(PippaMCPTools(host: host), "photos_search", arguments)
            let calls = await photo.counts()
            guard notes.last?.read == false, notes.last?.permissionRepair == expected, notes.explanationCount == 0,
                  calls.automation == 0, calls.library == 0, calls.searches == 0 else { return false }
        }
        return true
    }
    await checkAsync("Document permission: denied synthetic file/parent stays no_access; missing stays not_found without repair") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-permission-repair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("example.txt")
        try Data("Synthetic fixture only".utf8).write(to: file)
        defer {
            _ = chmod(folder.path, 0o700); _ = chmod(file.path, 0o600)
            try? FileManager.default.removeItem(at: folder)
        }
        let reader = PippaMCPTurnTools(turns: PippaMCPTurns())
        func status(_ result: PippaMCPToolResult) -> String? {
            (try? JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])?["status"] as? String
        }
        _ = chmod(file.path, 0)
        let deniedFile = await reader.call("read_document", ["path": file.path])
        _ = chmod(file.path, 0o600); _ = chmod(folder.path, 0)
        let deniedParent = await reader.call("read_document", ["path": file.path])
        _ = chmod(folder.path, 0o700)
        let missing = await reader.call("read_document", ["path": folder.appendingPathComponent("absent.txt").path])
        return status(deniedFile) == "no_access" && status(deniedParent) == "no_access" && status(missing) == "not_found"
            && deniedFile.permissionRepair == nil && deniedParent.permissionRepair == nil && missing.permissionRepair == nil
    }
    await checkAsync("Document read notes: successful then denied calls keep receipt order and captured turn identity") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-permission-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("example.txt")
        try Data("Synthetic fixture only".utf8).write(to: file)
        defer { _ = chmod(file.path, 0o600); try? FileManager.default.removeItem(at: folder) }
        let demo = DemoIntegrations(granted: true), notes = RepairNotes(), turns = PippaMCPTurns()
        let turn = PippaMCPTurn(); turns.begin(turn)
        var host = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(), hostData: DemoHostData(integrations: demo),
                                onRead: { notes.append($0) })
        host.turns = turns
        let tools = PippaMCPTools(host: host)
        _ = await repairCall(tools, "read_document", ["path": file.path])
        _ = chmod(file.path, 0)
        _ = await repairCall(tools, "read_document", ["path": file.path])
        return notes.all.map(\.read) == [true, false] && notes.all.allSatisfy { $0.tool == "read_document" && $0.turnID == turn.id }
    }
}
