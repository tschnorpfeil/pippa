import Foundation
import PippaCore

private func decodeJSON(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
}

func runMCPAppleAppsChecks() async {
    var berlin = Calendar(identifier: .gregorian)
    berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
    berlin.locale = Locale(identifier: "de_DE")

    // MARK: 1. Script compilation, variable hygiene, and safety invariants

    await checkAsync("Apple apps scripts: Notes and Safari compile cleanly with zero undefined variables, no body filter, and no Safari JS") {
        let compiled = await MainActor.run { IntegrationScripts.compileAll() }
        let notesSource = IntegrationScripts.sources.first { $0.name == "Notes" }?.source ?? ""
        let safariSource = IntegrationScripts.sources.first { $0.name == "Safari" }?.source ?? ""
        let (notesUndef, safariUndef) = await MainActor.run {
            (AppleScriptVariables.undefinedVariables(in: notesSource),
             AppleScriptVariables.undefinedVariables(in: safariSource))
        }
        let notesSafe = !notesSource.contains("whose body contains")
            && !notesSource.contains("body of ")
            && notesSource.contains("plaintext of ")
            && notesSource.contains("password protected")
            && notesSource.contains("set isLocked to true")
            && !notesSource.contains("\"Notizen\"")
            && !notesSource.contains("folder \"Notes\"")
        let lockFailClosed = NotesScript.isExplicitlyUnlocked(NSAppleEventDescriptor(boolean: false))
            && !NotesScript.isExplicitlyUnlocked(NSAppleEventDescriptor(boolean: true))
            && !NotesScript.isExplicitlyUnlocked(NSAppleEventDescriptor.null())
            && !NotesScript.isExplicitlyUnlocked(NSAppleEventDescriptor(string: "false"))
        let safariSafe = !safariSource.contains("do JavaScript")
            && safariSource.contains("on listTabs()")
            && safariSource.contains("on tabPage(winIdx, tabIdx)")
            && safariSource.contains("text of theTab")
        return compiled["Notes"] == true && compiled["Safari"] == true
            && notesUndef?.isEmpty == true && safariUndef?.isEmpty == true
            && notesSafe && lockFailClosed && safariSafe
    }

    // MARK: 2. Apple Notes (`notes_read`)

    await checkAsync("MCP notes_read: search, exact id read, locked-note skipping, and never exposing locked body") {
        let demo = DemoNotesReader()
        let tool = PippaMCPNotesTool(reader: demo, askForAccess: false, calendar: berlin)

        // List all notes: unlocked only, locked counted in skippedLocked, secret never exposed.
        let listed = await tool.call([:])
        let listedJSON = decodeJSON(listed.text)
        let listedData = listedJSON["data"] as? [String: Any] ?? [:]
        let notes = listedData["notes"] as? [[String: Any]] ?? []

        // Search by query (title/content) and query matching locked note's title/secret.
        let found = await tool.call(["query": "Zählerstand"])
        let foundData = decodeJSON(found.text)["data"] as? [String: Any] ?? [:]
        let foundNotes = foundData["notes"] as? [[String: Any]] ?? []

        let lockedQuery = await tool.call(["query": "Tresor"])
        let lockedQueryData = decodeJSON(lockedQuery.text)["data"] as? [String: Any] ?? [:]
        let lockedQueryNotes = lockedQueryData["notes"] as? [[String: Any]] ?? []

        // Exact id read of unlocked note.
        let read = await tool.call(["id": "x-coredata://demo/ICNote/p1"])
        let readJSON = decodeJSON(read.text)
        let readData = readJSON["data"] as? [String: Any] ?? [:]

        // Exact id read of locked note: refuses cleanly and never exposes secret body.
        let readLocked = await tool.call(["id": "x-coredata://demo/ICNote/p4-locked"])
        let readLockedJSON = decodeJSON(readLocked.text)

        // Unknown id and invalid arguments.
        let missing = await tool.call(["id": "x-coredata://demo/ICNote/missing"])
        let bothArgs = await tool.call(["id": "x-coredata://demo/ICNote/p1", "query": "test"])
        let badLimit = await tool.call(["limit": 999])

        let secret = "LOCKED-SECRET-MUST-NEVER-LEAK-991"
        let allText = [listed.text, found.text, lockedQuery.text, read.text, readLocked.text].joined()
        let schema = PippaMCPNotesTool.toolList().first ?? [:]
        let annotations = schema["annotations"] as? [String: Any] ?? [:]

        return !listed.isError && listedJSON["untrusted"] as? Bool == true
            && (listedJSON["rule"] as? String)?.isEmpty == false
            && notes.count == 3 && listedData["skippedLocked"] as? Int == 1
            && notes.allSatisfy { ($0["id"] as? String) != "x-coredata://demo/ICNote/p4-locked" }
            && !found.isError && foundNotes.count == 1 && foundNotes.first?["id"] as? String == "x-coredata://demo/ICNote/p1"
            && foundData["skippedLocked"] as? Int == 1
            && !lockedQuery.isError && lockedQueryNotes.isEmpty && lockedQueryData["skippedLocked"] as? Int == 1
            && !read.isError && readJSON["untrusted"] as? Bool == true
            && (readData["text"] as? String)?.contains("48210 kWh") == true && readData["folder"] as? String == "Privat"
            && readLocked.isError && readLockedJSON["status"] as? String == "locked" && readLockedJSON["skippedLocked"] as? Int == 1
            && missing.isError && decodeJSON(missing.text)["status"] as? String == "not_found"
            && bothArgs.isError && decodeJSON(bothArgs.text)["status"] as? String == "invalid_arguments"
            && badLimit.isError && decodeJSON(badLimit.text)["status"] as? String == "invalid_arguments"
            && !allText.contains(secret)
            && schema["name"] as? String == "notes_read" && annotations["readOnlyHint"] as? Bool == true
    }

    await checkAsync("MCP notes_read: denied returns Automation repair; notDetermined asks only when askForAccess is true") {
        let deniedTool = PippaMCPNotesTool(reader: DemoNotesReader(access: .denied), askForAccess: false, calendar: berlin)
        let denied = await deniedTool.call([:])
        let deniedJSON = decodeJSON(denied.text)

        let pendingNoAsk = PippaMCPNotesTool(reader: DemoNotesReader(access: .notDetermined), askForAccess: false, calendar: berlin)
        let needsAccess = await pendingNoAsk.call([:])
        let needsJSON = decodeJSON(needsAccess.text)

        let asked = LockedBox<Int>(0)
        let pendingAsk = PippaMCPNotesTool(reader: DemoNotesReader(access: .notDetermined), askForAccess: true, calendar: berlin,
                                           explainAccess: { _, _ in asked.mutate { $0 += 1 }; return true })
        let granted = await pendingAsk.call([:])

        return denied.isError && deniedJSON["status"] as? String == "denied" && denied.permissionRepair == .automation
            && needsAccess.isError && needsJSON["status"] as? String == "needs_access" && needsAccess.permissionRepair == nil
            && !granted.isError && asked.value == 1
    }

    // MARK: 3. Safari Multi-Tab Reader (`safariTabsRead`)

    await checkAsync("MCP front_read Safari tabs: listTabs (capped at 40), readSafariTab, out-of-range error, and denied handling") {
        func tools(front: DemoFrontApp, ask: Bool = false) -> PippaMCPTools {
            let demo = DemoIntegrations(granted: true)
            var host = PippaMCPHost(integrations: demo, sheets: DemoSheetReader(granted: true),
                                    hostData: DemoHostData(integrations: demo), askForAccess: ask, calendar: berlin)
            host.front = front
            return PippaMCPTools(host: host)
        }

        let happyTools = tools(front: DemoFrontApp())
        let listed = await happyTools.safariTabsRead()
        let listedJSON = decodeJSON(listed.result.text)
        let listedData = listedJSON["data"] as? [String: Any] ?? [:]
        let tabs = listedData["tabs"] as? [[String: Any]] ?? []

        // Cap at 40 when Safari has 50 open tabs.
        let fiftyTabs = (1...50).map { i in
            SafariTab(windowIndex: 1, tabIndex: i, title: "Tab \(i)", url: "https://example.invalid/\(i)", active: i == 1)
        }
        let capped = await tools(front: DemoFrontApp(safariTabs: fiftyTabs)).safariTabsRead()
        let cappedData = decodeJSON(capped.result.text)["data"] as? [String: Any] ?? [:]

        // Read specific tab by window_index + tab_index.
        let tabRead = await happyTools.safariTabsRead(windowIndex: 1, tabIndex: 2)
        let tabJSON = decodeJSON(tabRead.result.text)
        let tabData = tabJSON["data"] as? [String: Any] ?? [:]

        // Out-of-range tab index returns clean not_found error.
        let outOfRange = await happyTools.safariTabsRead(windowIndex: 1, tabIndex: 99)
        let outJSON = decodeJSON(outOfRange.result.text)

        // Partial arguments (only windowIndex without tabIndex).
        let partial = await happyTools.safariTabsRead(windowIndex: 1, tabIndex: nil)

        // Denied automation permission returns .automation repair.
        let denied = await tools(front: DemoFrontApp(access: .denied)).safariTabsRead()
        let deniedJSON = decodeJSON(denied.result.text)

        // Pending without asking returns needs_access.
        let pending = await tools(front: DemoFrontApp(access: .notDetermined), ask: false).safariTabsRead()
        let pendingJSON = decodeJSON(pending.result.text)

        return !listed.result.isError && listed.noted == "front_read"
            && listedJSON["untrusted"] as? Bool == true && tabs.count == 3
            && listedData["total"] as? Int == 3 && listedData["truncated"] as? Bool == false
            && !capped.result.isError && cappedData["shown"] as? Int == 40
            && cappedData["total"] as? Int == 50 && cappedData["truncated"] as? Bool == true
            && !tabRead.result.isError && tabJSON["untrusted"] as? Bool == true
            && tabData["title"] as? String == "Bahnverbindung Köln – München"
            && (tabData["text"] as? String)?.contains("ICE 515") == true
            && outOfRange.result.isError && outJSON["status"] as? String == "not_found" && outJSON["app"] as? String == "Safari"
            && partial.result.isError && decodeJSON(partial.result.text)["status"] as? String == "invalid_arguments"
            && denied.result.isError && deniedJSON["status"] as? String == "denied"
            && denied.result.permissionRepair == .automation && deniedJSON["app"] as? String == "Safari"
            && pending.result.isError && pendingJSON["status"] as? String == "needs_access"
    }

    // MARK: 4. Apple Contacts (`contacts_search`)

    await checkAsync("MCP contacts_search: match by name, email and org; empty match; denied returns .contacts repair") {
        let tool = PippaMCPContactsTool(store: DemoContactsStore(), askForAccess: false)

        let byName = await tool.call(["query": "Anna"])
        let byNameJSON = decodeJSON(byName.text)
        let byNameContacts = (byNameJSON["data"] as? [String: Any])?["contacts"] as? [[String: Any]] ?? []

        let byEmail = await tool.call(["query": "weber-dental.example"])
        let byEmailContacts = (decodeJSON(byEmail.text)["data"] as? [String: Any])?["contacts"] as? [[String: Any]] ?? []

        let byOrg = await tool.call(["query": "Northwind"])
        let byOrgContacts = (decodeJSON(byOrg.text)["data"] as? [String: Any])?["contacts"] as? [[String: Any]] ?? []

        let noMatch = await tool.call(["query": "NiemandExistiert999"])
        let noMatchContacts = (decodeJSON(noMatch.text)["data"] as? [String: Any])?["contacts"] as? [[String: Any]] ?? []

        let badLimit = await tool.call(["query": "Anna", "limit": 25])
        let missingQuery = await tool.call([:])

        let deniedTool = PippaMCPContactsTool(store: DemoContactsStore(access: .denied), askForAccess: false)
        let denied = await deniedTool.call(["query": "Anna"])
        let deniedJSON = decodeJSON(denied.text)

        let pendingTool = PippaMCPContactsTool(store: DemoContactsStore(access: .notDetermined), askForAccess: false)
        let pending = await pendingTool.call(["query": "Anna"])

        let schema = PippaMCPContactsTool.toolList().first ?? [:]
        let annotations = schema["annotations"] as? [String: Any] ?? [:]

        return !byName.isError && byNameJSON["untrusted"] as? Bool == true
            && (byNameJSON["rule"] as? String)?.isEmpty == false
            && byNameContacts.count == 1 && byNameContacts.first?["name"] as? String == "Anna Berger"
            && byNameContacts.first?["birthday"] as? String == "1982-05-14"
            && !byEmail.isError && byEmailContacts.count == 1 && byEmailContacts.first?["name"] as? String == "Dr. Lukas Weber"
            && !byOrg.isError && byOrgContacts.count == 1 && byOrgContacts.first?["name"] as? String == "Clara Miller"
            && byOrgContacts.first?["birthday"] as? String == "--11-03"
            && !noMatch.isError && noMatchContacts.isEmpty
            && badLimit.isError && decodeJSON(badLimit.text)["status"] as? String == "invalid_arguments"
            && missingQuery.isError && decodeJSON(missingQuery.text)["status"] as? String == "invalid_arguments"
            && denied.isError && deniedJSON["status"] as? String == "denied" && denied.permissionRepair == .contacts
            && PermissionRepairTarget.contacts.settingsURL.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts"
            && pending.isError && decodeJSON(pending.text)["status"] as? String == "needs_access"
            && schema["name"] as? String == "contacts_search" && annotations["readOnlyHint"] as? Bool == true
    }

    // MARK: 5. Sharing fail-closed decoding, provenance mapping, and egress refusal

    check("Sharing & Egress: SourceSharing.contacts defaults to ask on upgrade, fails closed on unknown, and egress refuses contacts_search and notes_read") {
        // Upgrade from 1.0 (missing contacts key) -> .ask.
        let upgraded = try JSONDecoder().decode(SourceSharing.self, from: Data(#"{"mail":"localOnly","calendar":"ask"}"#.utf8))
        // Unknown value for contacts -> fails closed to .localOnly.
        let unknown = try JSONDecoder().decode(SourceSharing.self, from: Data(#"{"contacts":"alwaysAllow"}"#.utf8))
        let malformed = try JSONDecoder().decode(SourceSharing.self, from: Data(#"{"contacts":123}"#.utf8))
        // Round-trip when set to localOnly.
        var custom = SourceSharing()
        custom.contacts = .localOnly
        let roundTrip = try JSONDecoder().decode(SourceSharing.self, from: JSONEncoder().encode(custom))

        // Provenance mapping for 1.1 tools.
        let provenanceOK = SharingSource.read(byTool: "contacts_search") == [.contacts]
            && SharingSource.read(byTool: "mcp__pippa__contacts_search") == [.contacts]
            && SharingSource.read(byTool: "notes_read") == [.documents]
            && SharingSource.read(byTool: "mcp__pippa__notes_read") == [.documents]
            && SharingSource.read(byTool: "calendar_update") == [.calendar]
            && SharingSource.read(byTool: "reminder_update") == [.reminders]
            && SharingSource.read(byTool: "compute").isEmpty

        // Egress refuses both new readers even when all sharing rules are .ask and web is enabled.
        let egress = PippaMCPEgress(rules: SourceSharing(), web: true)
        let egressRefuses = !egress.allows("contacts_search")
            && !egress.allows("notes_read")
            && !egress.tools.contains("contacts_search")
            && !egress.tools.contains("notes_read")

        return upgraded.contacts == .ask && upgraded.mail == .localOnly
            && unknown.contacts == .localOnly && malformed.contacts == .localOnly
            && roundTrip == custom && roundTrip.contacts == .localOnly
            && provenanceOK && egressRefuses
    }
}
