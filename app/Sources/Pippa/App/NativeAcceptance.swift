#if PIPPA_NATIVE_ACCEPTANCE
import AppKit
import Darwin
import Foundation
import PippaCore

/// Fixed synthetic integration probe, compiled only into explicitly marked development candidates.
/// No server, generic tool arguments, normal app history, permission prompts or model are involved.
enum NativeAcceptance {
    struct Fixture: Codable {
        let id: UUID
        let origin: PippaMCPOrigin
        let creatorPID: Int32
        var title: String { "PIPPA-NATIVE-ACCEPT-" + id.uuidString }
        var notes: String { "Synthetic native integration acceptance. No due date or alarm." }
    }
    struct Proof: Codable {
        let operationID: UUID
        let targetID: String
        let item: CreatedItem
        let pid: Int32
        let interruptAfterSave: Bool
    }
    struct ProcessStart: Encodable {
        let phase: String
        let launchToken: UUID
        let pid = getpid()
    }
    struct Report: Encodable {
        let schema = 1
        let evidence = "instrumented-signed-native-integration"
        let phase: String
        var status = "fail"
        var detail = "Acceptance did not complete."
        let pid = getpid()
        var operationID: UUID?
        var nativeID: String?
        var targetID: String?
        var revision: Int?
        var recovered: Bool?
        var nativeWrites = 0
        var reminderPermission = "unknown"
    }
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    static func write<T: Encodable>(_ value: T, to file: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func read<T: Decodable>(_ type: T.Type, from file: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: file))
    }

    /// All native operations are the product adapters. Only the precise after-save interruption is instrumented.
    final class Writer: HostWriting, @unchecked Sendable {
        let system: SystemIntegrations
        let directory: URL
        let interrupt: Bool
        private let lock = NSLock()
        private var writes = 0
        var count: Int { lock.withLock { writes } }
        init(system: SystemIntegrations, directory: URL, interrupt: Bool) {
            self.system = system; self.directory = directory; self.interrupt = interrupt
        }
        func addEvent(_ event: NewCalendarEvent) async throws -> HostWrite { throw PippaError.notAvailable }
        func addReminder(_ reminder: NewReminder) async throws -> HostWrite { throw PippaError.notAvailable }
        func reminderTarget(for reminder: NewReminder) async throws -> NativeReminderTarget {
            try await system.reminderTarget(for: reminder)
        }
        func lookupReminder(marker: URL, target: NativeReminderTarget, identifier: String?) async -> NativeReminderLookup {
            await system.lookupReminder(marker: marker, target: target, identifier: identifier)
        }
        func addReminder(_ reminder: NewReminder, target: NativeReminderTarget, marker: URL) async throws -> HostWrite {
            guard let operationID = UUID(uuidString: marker.lastPathComponent) else { throw PippaError.notAvailable }
            let result = try await system.addReminder(reminder, target: target, marker: marker)
            lock.withLock { writes += 1 }
            try NativeAcceptance.write(Proof(operationID: operationID, targetID: target.identifier,
                                              item: result.item, pid: getpid(), interruptAfterSave: interrupt), to: directory.appendingPathComponent("after-save.json"))
            if interrupt {
                // The real native save returned; the production journal still says dispatched.
                Darwin.kill(getpid(), SIGKILL)
                Darwin._exit(86)
            }
            return result
        }
    }

    @MainActor static func run(_ arguments: [String]) async -> Int32 {
        print("PIPPA_NATIVE_ACCEPTANCE_BUILD_1")
        guard arguments.count == 5, arguments[1] == "--native-acceptance",
              ["create", "interrupt", "readback", "deduplicate", "recover", "cleanup"].contains(arguments[2]),
              let launchToken = UUID(uuidString: arguments[4]),
              arguments[3].hasPrefix("/"), Bundle.main.object(forInfoDictionaryKey: "PippaNativeAcceptance") as? Bool == true else {
            fputs("Native acceptance requires a marked candidate, fixed phase, absolute output directory and launch token.\n", stderr)
            return 2
        }
        let phase = arguments[2], directory = URL(fileURLWithPath: arguments[3], isDirectory: true).standardizedFileURL
        var report = Report(phase: phase)
        var code: Int32 = 1
        var validDirectory = false
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            try require(attributes[.type] as? FileAttributeType == .typeDirectory
                        && directory.resolvingSymlinksInPath() == directory
                        && (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
                        && ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0,
                        "Output must be a private owned directory without symlinks.")
            validDirectory = true
            let fixtureURL = directory.appendingPathComponent("fixture.json")
            let fixture: Fixture
            if phase == "create" || phase == "interrupt" {
                try require(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty, "Creation requires an empty directory.")
                fixture = Fixture(id: UUID(), origin: PippaMCPOrigin(conversationID: UUID(), requestID: UUID()), creatorPID: getpid())
                try write(fixture, to: fixtureURL)
            } else { fixture = try read(Fixture.self, from: fixtureURL) }
            try write(ProcessStart(phase: phase, launchToken: launchToken), to: directory.appendingPathComponent(phase + "-process.json"))
            setenv("PIPPA_LOG_DIR", directory.appendingPathComponent("logs").path, 1)
            let system = SystemIntegrations()
            let access = await system.access(.reminders)
            switch access {
            case .granted: report.reminderPermission = "granted"
            case .denied: report.reminderPermission = "denied"
            case .notDetermined: report.reminderPermission = "notDetermined"
            case .unavailable: report.reminderPermission = "unavailable"
            }
            guard access == .granted else {
                report.status = "blocked"; report.detail = "Existing Reminders permission is required; no permission was requested."
                try write(report, to: directory.appendingPathComponent(phase + ".json")); return 3
            }
            // Construct with the isolated journal from the outset; .system() would open the normal app journal.
            let journal = try Executor(baseDirectory: directory.appendingPathComponent("journal"))
            let writer = Writer(system: system, directory: directory, interrupt: phase == "interrupt")
            var host = PippaMCPHost(integrations: system, sheets: system, hostData: system, askForAccess: false)
            host.writer = writer; host.reminderJournal = journal; host.requiresReminderJournal = true
            host.turns = PippaMCPTurns(); host.requireActiveWriteTurn = true
            let turn = PippaMCPTurn(origin: fixture.origin)
            host.turns.begin(turn); defer { host.turns.end(turn) }
            func records() async throws -> [NativeReminderRecord] {
                let rows = try await journal.nativeReminderRecords()
                try require(rows.count == 1 && rows[0].origin == fixture.origin && rows[0].reminder.title == fixture.title
                            && rows[0].reminder.notes == fixture.notes && rows[0].reminder.due == nil,
                            "Journal must contain exactly this synthetic request.")
                return rows
            }
            func call() async throws -> [String: Any] {
                let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                    "params": ["name": "reminder_add", "arguments": ["title": fixture.title, "notes": fixture.notes]]]
                guard let data = await PippaMCPTools(host: host).handle(try JSONSerialization.data(withJSONObject: request)),
                      let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = reply["result"] as? [String: Any], result["isError"] as? Bool == false,
                      let content = result["content"] as? [[String: Any]], let text = content.first?["text"] as? String,
                      let value = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      value["done"] as? Bool == true else { throw Failure(message: "Product dispatch did not confirm creation.") }
                return value
            }
            if phase == "create" || phase == "interrupt" {
                _ = try await call()
                try require(phase == "create" && writer.count == 1, "Native create count or interruption was unexpected.")
            }
            var record = try await records()[0]
            let proof = try read(Proof.self, from: directory.appendingPathComponent("after-save.json"))
            guard let target = record.target else { throw Failure(message: "Missing immutable native destination.") }
            try require(record.id == proof.operationID && target.identifier == proof.targetID
                        && proof.item.integration == .reminders && proof.item.fingerprint != nil,
                        "Native proof must identify this operation and destination.")
            if !["create", "interrupt"].contains(phase) {
                try require(getpid() != fixture.creatorPID && getpid() != proof.pid, "Readback must run in a fresh process.")
            }
            if phase == "recover" {
                try require(record.phase == .dispatched || record.phase == .uncertain, "Interrupted journal was not unresolved.")
                let oldRevision = record.revision
                _ = try await journal.reconcileNativeReminders(using: writer, conversationID: fixture.origin.conversationID)
                record = try await records()[0]
                try require(record.phase == .completed && record.recovered && record.revision > oldRevision && writer.count == 0,
                            "Recovery must resolve the original operation without a native write.")
            }
            let native = await system.lookupReminder(marker: record.marker, target: target, identifier: proof.item.identifier)
            // A missing marker in the original list cannot prove absence: the item may have moved or been edited.
            do {
                guard case .found(let found) = native else { throw Failure(message: "Exact native marker and target could not be read back uniquely.") }
                try require(found.item.identifier == proof.item.identifier && found.containerIdentifier == proof.targetID,
                            "Native identity changed across processes.")
                if phase == "cleanup" {
                    // Use the original fingerprint, not a refreshed recovery fingerprint, to protect user edits.
                    try require(found.item.fingerprint == proof.item.fingerprint, "Synthetic reminder changed; cleanup refused.")
                    let removal = try await system.remove(proof.item)
                    try require(removal == .removed || removal == .gone, "Guarded native cleanup refused a changed reminder.")
                    guard case .notFound = await system.lookupReminder(marker: record.marker, target: target, identifier: proof.item.identifier) else {
                        throw Failure(message: "Cleanup absence could not be verified.")
                    }
                    report.detail = "Only the unchanged synthetic reminder was removed; absence verified."
                } else {
                    try require(record.phase == .completed && record.result?.item.identifier == proof.item.identifier,
                                "Persisted completion and native identity do not agree.")
                    if phase == "deduplicate" {
                        let revision = record.revision, response = try await call()
                        record = try await records()[0]
                        try require(response["already_completed"] as? Bool == true && response["operationID"] as? String == record.id.uuidString
                                    && record.revision == revision && writer.count == 0,
                                    "Same request must return its original completion without writing again.")
                    }
                    report.detail = "Exact synthetic native identity and durable journal agree."
                }
            }
            report.operationID = record.id; report.nativeID = proof.item.identifier; report.targetID = target.identifier
            report.revision = record.revision; report.recovered = record.recovered; report.nativeWrites = writer.count
            report.status = "pass"; code = 0
        } catch let failure as Failure { report.detail = failure.message }
        catch { report.detail = "Native acceptance failed; private native error details are omitted." }
        guard validDirectory else { fputs("Native acceptance directory rejected.\n", stderr); return 2 }
        do { try write(report, to: directory.appendingPathComponent(phase + ".json")) }
        catch { fputs("Could not write native acceptance report.\n", stderr); return 1 }
        print("native_acceptance \(phase) \(report.status)")
        return code
    }
}
#endif
