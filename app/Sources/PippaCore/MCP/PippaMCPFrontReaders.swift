import Foundation

extension PippaMCPTools {
    // MARK: Excel

    func excelSelection() async -> PippaMCPToolResult {
        var access = await host.sheets.sheetAccess()
        if access == .notDetermined && host.askForAccess, await mayAsk(.excel) { access = await host.sheets.requestSheetAccess() }
        switch access {
        case .granted: break
        case .notDetermined: return blocked("needs_access", Self.notYet(app: ExcelScript.appName))
        case .denied: return blocked("denied", Self.deniedAutomation(ExcelScript.appName), repair: .automation)
        case .unavailable(let why): return blocked("unavailable", why)
        }
        do {
            guard let sheet = try await host.sheets.selectedSheet() else {
                return blocked("nothing_open", L("No table is open in Excel. Open it, select the cells and ask again.", table: "MCP"))
            }
            return Self.bounded(source: "Excel on this Mac (active sheet)",
                                data: ["sheet": sheet.contextText(maxRows: 200), "clipped": sheet.isClipped],
                                next: "Rows are numbered, columns lettered; formulas are in [brackets]. Use the numbers exactly. Never claim you changed the table.")
        } catch PippaError.accessDenied {
            return blocked("denied", Self.deniedAutomation(ExcelScript.appName), repair: .automation)
        } catch PippaError.appNotOpen {
            return blocked("unavailable", L("First open your table in Excel and select the cells. Then try again.", table: "Sheet"))
        } catch {
            return blocked("failed", L("Pippa couldn’t read %@ just now. Please try again.", table: "MCP", ExcelScript.appName))
        }
    }

    // MARK: App in front

    /// What is open in the app of the chip. Mail and Excel: their own readers (same receipt, same draft offer).
    /// Without a chip nothing is read, whatever is in front now.
    func frontRead(_ capturedApp: FrontApp?) async -> (result: PippaMCPToolResult, noted: String) {
        guard let app = capturedApp else {
            return (blocked("nothing_shown", L("I don’t see which app you mean. Copy the text you mean or drop the file on me, then ask again.", table: "MCP")),
                    "front_read")
        }
        if app.bundleID == Integration.mail.bundleIdentifier { return (await mailSelected(), "mail_selected") }
        if app.bundleID == ExcelScript.bundleIdentifier { return (await excelSelection(), "excel_selection") }
        func tagged(_ result: PippaMCPToolResult) -> PippaMCPToolResult {
            // The app's name for the receipt line ("Nicht gelesen: Safari"): from the chip, not from the app.
            guard var json = (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any] else { return result }
            json["app"] = app.name
            var named = result
            named.text = Self.json(json)
            return named
        }
        let cannot = L("I can’t read anything from %@. Copy the text you mean or drop the file on me, then ask again.", table: "MCP", app.name)
        var access = await host.front.frontAccess(app, ask: false)
        if access == .notDetermined && host.askForAccess, await mayAsk(.front(app.name)) {
            access = await host.front.frontAccess(app, ask: true)
        }
        switch access {
        case .granted: break
        case .notDetermined: return (tagged(blocked("needs_access", Self.notYet(app: app.name))), "front_read")
        case .denied: return (tagged(blocked("denied", Self.deniedAutomation(app.name), repair: .automation)), "front_read")
        case .unavailable: return (tagged(blocked("unavailable", cannot)), "front_read")
        }
        do {
            guard let content = try await host.front.readFront(app) else { return (tagged(blocked("nothing_open", cannot)), "front_read") }
            let limit = 6000
            let text = Self.compact(content.text)
            var data: [String: Any] = ["app": app.name, "title": content.title, "text": String(text.prefix(limit)), "textTruncated": text.count > limit]
            if let url = content.url { data["url"] = url }
            if let file = content.file { data["path"] = file.path }
            let next: String
            switch (content.kind, text.isEmpty) {
            case (.page, false): next = "Use only what the page says; it may be cut (textTruncated). Name the page by its title."
            case (.page, true): next = "The page text could not be read, only title and url. Say so in one sentence; do not guess what the page says."
            case (.document, false): next = "Use only what the document says. For more pages use mcp__pippa__read_document with path."
            case (.document, true): next = "The document has no text layer (a scan or image). Read it with mcp__pippa__read_document and path."
            }
            return (Self.bounded(source: "\(app.name) on this Mac (what is open in front)", data: data, next: next), "front_read")
        } catch PippaError.accessDenied {
            return (tagged(blocked("denied", Self.deniedAutomation(app.name), repair: .automation)), "front_read")
        } catch {
            return (tagged(blocked("failed", cannot)), "front_read")
        }
    }
}
