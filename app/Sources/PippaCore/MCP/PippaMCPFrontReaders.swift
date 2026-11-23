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

    /// What is open in the app of the chip. Mail is dispatched by the caller with its read scope.
    /// Without a chip nothing is read, whatever is in front now.
    func frontRead(_ capturedApp: FrontApp?) async -> (result: PippaMCPToolResult, noted: String) {
        guard let app = capturedApp else {
            return (blocked("nothing_shown", L("I don’t see which app you mean. Copy the text you mean or drop the file on me, then ask again.", table: "MCP")),
                    "front_read")
        }
        if app.bundleID == ExcelScript.bundleIdentifier { return (await excelSelection(), "excel_selection") }
        func tagged(_ result: PippaMCPToolResult) -> PippaMCPToolResult {
            // The app's name for the receipt line ("Nicht gelesen: Safari"): from the chip, not from the app.
            guard result.isError, var json = (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any] else { return result }
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
        case .unavailable: return (tagged(await accessibilityRead(app, otherwise: blocked("unavailable", cannot))), "front_read")
        }
        do {
            // Apple Events first: the real page or file. Accessibility only when they bring nothing.
            guard let content = try await host.front.readFront(app) else {
                return (tagged(await accessibilityRead(app, otherwise: blocked("nothing_open", cannot))), "front_read")
            }
            return (Self.frontResult(app, content, accessibility: false), "front_read")
        } catch PippaError.accessDenied {
            return (tagged(blocked("denied", Self.deniedAutomation(app.name), repair: .automation)), "front_read")
        } catch {
            return (tagged(await accessibilityRead(app, otherwise: blocked("failed", cannot))), "front_read")
        }
    }

    /// Lists open Safari tabs (capped at 40) or reads one specific tab's native text via Apple Events (no JS).
    /// Pass both `windowIndex` and `tabIndex` (1-based) to read one tab; omit both to list open tabs.
    public func safariTabsRead(windowIndex: Int? = nil, tabIndex: Int? = nil,
                               capturedApp: FrontApp? = nil) async -> (result: PippaMCPToolResult, noted: String) {
        if (windowIndex == nil) != (tabIndex == nil) {
            return (invalid("Pass both window_index and tab_index to read a specific Safari tab."), "front_read")
        }
        if let w = windowIndex, let t = tabIndex, w < 1 || t < 1 {
            return (invalid("window_index and tab_index must be 1 or greater."), "front_read")
        }
        let safariApp = (capturedApp?.bundleID == FrontApp.safari ? capturedApp : nil)
            ?? FrontApp(name: "Safari", bundleID: FrontApp.safari, pid: 0)
        func tagged(_ result: PippaMCPToolResult) -> PippaMCPToolResult {
            guard result.isError, var json = (try? JSONSerialization.jsonObject(with: Data(result.text.utf8))) as? [String: Any] else { return result }
            json["app"] = safariApp.name
            var named = result
            named.text = Self.json(json)
            return named
        }
        var access = await host.front.frontAccess(safariApp, ask: false)
        if access == .notDetermined && host.askForAccess, await mayAsk(.front(safariApp.name)) {
            access = await host.front.frontAccess(safariApp, ask: true)
        }
        switch access {
        case .granted: break
        case .notDetermined:
            return (tagged(blocked("needs_access", Self.notYet(app: safariApp.name))), "front_read")
        case .denied:
            return (tagged(blocked("denied", Self.deniedAutomation(safariApp.name), repair: .automation)), "front_read")
        case .unavailable(let why):
            let tell = why.isEmpty ? L("Open %@ first. Then ask again.", table: "MCP", safariApp.name) : why
            return (tagged(blocked("unavailable", tell)), "front_read")
        }
        do {
            if let windowIndex, let tabIndex {
                guard let content = try await host.front.readSafariTab(window: windowIndex, tab: tabIndex) else {
                    return (tagged(blocked("not_found", L("That tab isn’t open in Safari. List the open tabs first and try again.", table: "MCP"))), "front_read")
                }
                return (Self.frontResult(safariApp, content, accessibility: false), "front_read")
            }
            let maxTabs = 40
            let allTabs = try await host.front.listSafariTabs()
            guard !allTabs.isEmpty else {
                return (tagged(blocked("nothing_open", L("No tabs are open in Safari.", table: "MCP"))), "front_read")
            }
            var items: [[String: Any]] = []
            var usedBytes = 0
            let budget = Self.maxResultBytes - 1400
            for tab in allTabs.prefix(maxTabs) {
                let entry: [String: Any] = [
                    "window_index": tab.windowIndex,
                    "tab_index": tab.tabIndex,
                    "title": String(tab.title.prefix(100)),
                    "url": String(tab.url.prefix(180)),
                    "active": tab.active,
                ]
                let size = Self.encode(entry).count + 2
                guard usedBytes + size <= budget else { break }
                items.append(entry)
                usedBytes += size
            }
            let data: [String: Any] = [
                "app": safariApp.name,
                "title": L("Safari tabs", table: "MCP"),
                "tabs": items,
                "shown": items.count,
                "total": allTabs.count,
                "truncated": allTabs.count > items.count,
            ]
            return (Self.bounded(source: "Safari on this Mac (open tabs)", data: data,
                                 next: "Use front_read with window_index and tab_index to read a specific tab."), "front_read")
        } catch PippaError.accessDenied {
            return (tagged(blocked("denied", Self.deniedAutomation(safariApp.name), repair: .automation)), "front_read")
        } catch PippaError.appNotOpen {
            return (tagged(blocked("unavailable", L("Open %@ first. Then ask again.", table: "MCP", safariApp.name))), "front_read")
        } catch {
            return (tagged(blocked("failed", L("Pippa couldn’t read %@ just now. Please try again.", table: "MCP", safariApp.name))), "front_read")
        }
    }

    /// The window's visible text via Accessibility, with its own permission: Pippa's sentence first, then the system
    /// prompt. `otherwise`: the answer when there is no such reader or it finds nothing.
    private func accessibilityRead(_ app: FrontApp, otherwise: PippaMCPToolResult) async -> PippaMCPToolResult {
        guard let reader = host.front.accessibility else { return otherwise }
        var access = reader.accessibilityAccess(ask: false)
        if access == .notDetermined && host.askForAccess, await mayAsk(.front(app.name)) {
            access = reader.accessibilityAccess(ask: true)
        }
        switch access {
        case .granted: break
        case .notDetermined: return blocked("needs_access", Self.notYetAccessibility(app.name))
        case .denied: return blocked("denied", Self.deniedAccessibility(app.name), repair: .accessibility)
        case .unavailable: return otherwise
        }
        guard let content = try? await reader.readAccessibility(app), !content.text.isEmpty || content.file != nil else { return otherwise }
        return Self.frontResult(app, content, accessibility: true)
    }

    private static func frontResult(_ app: FrontApp, _ content: FrontContent, accessibility: Bool) -> PippaMCPToolResult {
        let limit = 6000
        let text = compact(content.text)
        var data: [String: Any] = ["app": app.name, "title": content.title, "text": String(text.prefix(limit)),
                                   "textTruncated": content.clipped || text.count > limit]
        if let url = content.url { data["url"] = url }
        if let file = content.file { data["path"] = file.path }
        if accessibility { data["via"] = "accessibility" }
        let next: String
        switch (content.kind, text.isEmpty) {
        case _ where accessibility && !text.isEmpty:
            next = "This is the visible text of the window, button labels included; it may be cut (textTruncated). Use only what it says. Name it by its title."
        case (.page, false): next = "Use only what the page says; it may be cut (textTruncated). Name the page by its title."
        case (.page, true): next = "The page text could not be read, only title and url. Say so in one sentence; do not guess what the page says."
        case (.document, false): next = "Use only what the document says. For more pages use mcp__pippa__read_document with path."
        case (.document, true): next = "The document has no text layer (a scan or image). Read it with mcp__pippa__read_document and path."
        }
        return bounded(source: "\(app.name) on this Mac (what is open in front)", data: data, next: next)
    }
}
