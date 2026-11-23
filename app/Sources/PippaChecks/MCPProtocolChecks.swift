import Foundation
import PippaCore

extension MCPCheckContext {
    func protocolChecks() async {
        // MARK: Protocol

        await checkAsync("MCP: initialize names Pippa, version as requested (else the newest), tools only") {
            let s = setup()
            let asked = await rpc(s.tools, "initialize", ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "pi", "version": "1.0.4"]])
            let odd = await rpc(s.tools, "initialize", ["protocolVersion": "1999-01-01"])
            let result = asked?["result"] as? [String: Any] ?? [:]
            let info = result["serverInfo"] as? [String: Any] ?? [:]
            let caps = result["capabilities"] as? [String: Any] ?? [:]
            return result["protocolVersion"] as? String == "2025-06-18" && info["name"] as? String == "pippa"
                && (odd?["result"] as? [String: Any])?["protocolVersion"] as? String == PippaMCPTools.protocolVersions[0]
                && caps.keys.sorted() == ["tools"] && asked?["id"] as? Int == 1
        }
        await checkAsync("MCP: notification without reply, ping, unknown method, broken JSON, batch") {
            let s = setup()
            let note = await s.tools.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
            let ping = await rpc(s.tools, "ping", id: "p")
            let unknown = await rpc(s.tools, "resources/list")
            let broken = await s.tools.handle(Data("{nope".utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let batch = await s.tools.handle(Data(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"}]"#.utf8))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [Any] }
            return note == nil && ping?["id"] as? String == "p" && ping?["result"] != nil
                && (unknown?["error"] as? [String: Any])?["code"] as? Int == -32601
                && (broken?["error"] as? [String: Any])?["code"] as? Int == -32700 && batch?.count == 1
        }
        await checkAsync("MCP: five readers and front_read (+ read_document), all read-only (readOnly, non-destructive, closed world), schema as object") {
            let s = setup()
            let list = (await rpc(s.tools, "tools/list"))?["result"] as? [String: Any]
            let all = list?["tools"] as? [[String: Any]] ?? []
            let names = all.compactMap { $0["name"] as? String }
            // calendar_add/reminder_add/mail_draft and prepare_files change something on the Mac; browse and mail_send go online.
            let tools = all.filter { !(PippaMCPWriteTools.names + [PippaMCPFilePreparation.name, PippaMCPBrowserTool.name, PippaMCPMailSend.name]).contains($0["name"] as? String ?? "") }
            let hintsOK = tools.allSatisfy { tool in
                let a = tool["annotations"] as? [String: Any] ?? [:]
                return a["readOnlyHint"] as? Bool == true && a["destructiveHint"] as? Bool == false && a["openWorldHint"] as? Bool == false
                    && (tool["inputSchema"] as? [String: Any])?["type"] as? String == "object"
            }
            // Keep the reader list under 5,000 bytes and the full 20-tool `tools/list` under 9,800 bytes (1.0 was 15 tools / 7,118 bytes;
            // 1.1 adds notes_read, contacts_search, compute, calendar_update, reminder_update and Safari multi-tab args).
            // The whole list also has its own ceiling in ComputeAndBudgetChecks.swift.
            let readerBytes = (try? JSONSerialization.data(withJSONObject: tools))?.count ?? .max
            let allBytes = (try? JSONSerialization.data(withJSONObject: all))?.count ?? .max
            if readerBytes >= 5000 || allBytes >= 9800 { print("  tools/list bytes: readers \(readerBytes), all \(allBytes)") }
            return names == PippaMCPTools.toolNames && hintsOK && readerBytes < 5000 && allBytes < 9800 && tools.count == 11 && all.count == 20
        }
        await checkAsync("MCP: browse is listed once, open world, not destructive, not read-only") {
            let s = setup()
            let list = (await rpc(s.tools, "tools/list"))?["result"] as? [String: Any]
            let browse = (list?["tools"] as? [[String: Any]] ?? []).filter { $0["name"] as? String == PippaMCPBrowserTool.name }
            let a = browse.first?["annotations"] as? [String: Any] ?? [:]
            return browse.count == 1 && a["openWorldHint"] as? Bool == true && a["destructiveHint"] as? Bool == false
                && a["readOnlyHint"] as? Bool == false && a["idempotentHint"] as? Bool == false
        }
        await checkAsync("MCP: unknown tool is a protocol error, unknown arguments a tool error") {
            let s = setup()
            let unknown = await rpc(s.tools, "tools/call", ["name": "mail_forward", "arguments": [:]])
            let extra = await call(s.tools, "calendar_read", ["period": "today", "recipient": "x"])
            let wrongType = await call(s.tools, "mail_search", ["query": "Berger", "limit": "3"])
            return (unknown?["error"] as? [String: Any])?["code"] as? Int == -32602
                && extra.isError && extra.json["status"] as? String == "invalid_arguments"
                && wrongType.isError && wrongType.json["status"] as? String == "invalid_arguments"
        }
        await checkAsync("MCP read_document: a web address is refused and points to fetch_content") {
            let s = setup()
            let web = await call(s.tools, "read_document", ["path": "https://example.org/a.pdf"])
            return web.isError && web.json["status"] as? String == "invalid_arguments"
                && (web.json["error"] as? String ?? "").contains("fetch_content")
        }
        await checkAsync("MCP readers: fields from another tool are rejected before permissions, launching apps or reading") {
            let s = setup(granted: false, ask: true)
            let calls: [(String, [String: Any])] = [
                ("calendar_read", ["period": "today", "query": "Berger"]),
                ("reminders_read", ["limit": 1]),
                ("mail_selected", ["query": "Berger"]),
                ("mail_search", ["query": "Berger", "days": 1]),
                ("excel_selection", ["limit": 1]),
                ("photos_search", ["period": "today"]),
                ("front_read", ["start": "2026-10-07"]),
            ]
            for (tool, arguments) in calls {
                let result = await call(s.tools, tool, arguments)
                guard result.isError, result.json["status"] as? String == "invalid_arguments", result.json["data"] == nil else { return false }
            }
            let calendar = await s.demo.access(.calendar), reminders = await s.demo.access(.reminders), mail = await s.demo.access(.mail)
            return calendar == .notDetermined && reminders == .notDetermined && mail == .notDetermined
                && s.demo.calendarReads.isEmpty && s.demo.mailPreparations == 0 && s.data.photoQueries.isEmpty
        }
        await checkAsync("MCP photos_search: malformed query never becomes an unfiltered read; omitted query remains valid") {
            let s = setup(ask: true)
            s.data.libraryPermission = .notDetermined
            let badQueries: [Any] = [123, true, NSNull(), ["Fahrrad"], ["text": "Fahrrad"]]
            for query in badQueries {
                let result = await call(s.tools, "photos_search", ["query": query])
                guard result.isError, result.json["status"] as? String == "invalid_arguments",
                      (result.json["error"] as? String)?.contains("query") == true, result.json["data"] == nil else { return false }
            }
            let untouched = s.data.libraryPermission == .notDetermined && s.data.photoQueries.isEmpty
            let omitted = await call(s.tools, "photos_search", ["limit": 1])
            return untouched && !omitted.isError && s.data.libraryPermission == .granted
                && ((omitted.json["data"] as? [String: Any])?["photos"] as? [Any])?.count == 1
        }
        await checkAsync("MCP readers: optional means absent, not null; booleans, fractional and overflowing integers are invalid") {
            let s = setup()
            let calls: [(String, [String: Any])] = [
                ("calendar_read", ["period": NSNull()]),
                ("calendar_read", ["period": "today", "start": false]),
                ("calendar_read", ["period": "today", "end": NSNull()]),
                ("calendar_read", ["period": "today", "days": NSNull()]),
                ("reminders_read", ["days": true]),
                ("reminders_read", ["days": 1.5]),
                ("reminders_read", ["days": 1e30]),
                ("mail_search", ["query": "Berger", "limit": NSNull()]),
                ("mail_search", ["query": false]),
                ("photos_search", ["days": NSNull()]),
                ("photos_search", ["limit": true]),
            ]
            for (tool, arguments) in calls {
                let result = await call(s.tools, tool, arguments)
                guard result.isError, result.json["status"] as? String == "invalid_arguments" else { return false }
            }
            let defaults = await call(s.tools, "reminders_read")
            let integral = await call(s.tools, "photos_search", ["limit": 1.0])
            return !defaults.isError && !integral.isError && s.demo.calendarReads.isEmpty && s.demo.mailPreparations == 0
        }
        await checkAsync("MCP arguments: non-object and null never become empty arguments; omission is allowed") {
            let s = setup(ask: true)
            s.data.libraryPermission = .notDetermined
            let malformed: [Any] = [NSNull(), [], ["query"], true, 123, "{}"]
            for arguments in malformed {
                let reply = await rpc(s.tools, "tools/call", ["name": "photos_search", "arguments": arguments])
                let result = reply?["result"] as? [String: Any] ?? [:]
                let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
                let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
                guard result["isError"] as? Bool == true, json["status"] as? String == "invalid_arguments" else { return false }
            }
            let untouched = s.data.libraryPermission == .notDetermined
            let omitted = await rpc(s.tools, "tools/call", ["name": "photos_search"])
            return untouched && (omitted?["result"] as? [String: Any])?["isError"] as? Bool == false
        }
    }
}
