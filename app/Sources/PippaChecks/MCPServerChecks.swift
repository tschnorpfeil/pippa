import Darwin
import Foundation
import PippaCore

extension MCPCheckContext {
    func serverChecks() async {
        // MARK: HTTP

        check("MCP HTTP: parse request (incomplete, Content-Length, chunked, too large)") {
            let head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:9\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n"
            let partial = PippaHTTPRequest.parse(Data((head + "{").utf8))
            let full = PippaHTTPRequest.parse(Data((head + "{}").utf8))
            let chunked = PippaHTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
            let huge = PippaHTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 5000000\r\n\r\n".utf8))
            let twice = PippaHTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nAuthorization: a\r\nAuthorization: b\r\n\r\n".utf8))
            guard case .complete(let request) = full else { return false }
            return partial == .incomplete && request.body == Data("{}".utf8) && request.headers["content-type"] == "application/json"
                && chunked == .invalid(411) && huge == .invalid(413) && twice == .invalid(400)
        }
        await checkAsync("MCP HTTP: missing/wrong key 401, browser (Origin) 403, foreign host 403, GET 405, notification 202") {
            let host = PippaMCPHost.demo(now: now)
            guard let server = try? PippaMCPServer(host: host) else { return false }
            let token = server.token
            func request(_ method: String = "POST", headers: [String: String] = [:], body: String = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#) -> PippaHTTPRequest {
                var all = ["host": "127.0.0.1:4711", "content-type": "application/json", "authorization": "Bearer \(token)"]
                for (k, v) in headers { all[k] = v }
                return PippaHTTPRequest(method: method, path: "/mcp", headers: all.filter { !$0.value.isEmpty }, body: Data(body.utf8))
            }
            func status(_ r: PippaHTTPRequest) async -> Int {
                let response = await server.respond(to: r, port: 4711)
                return response.status
            }
            let ok = await server.respond(to: request(), port: 4711)
            let statuses = [
                await status(request(headers: ["authorization": ""])),
                await status(request(headers: ["authorization": "Bearer " + String(repeating: "0", count: 64)])),
                await status(request(headers: ["authorization": "Basic \(token)"])),
                await status(request(headers: ["origin": "https://example.com"])),
                await status(request(headers: ["host": "evil.example:4711"])),
                await status(request(headers: ["host": "localhost:4711"])),
                await status(request("GET")),
                await status(request(body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)),
                await status(request(headers: ["content-type": "text/plain"])),
            ]
            return ok.status == 200 && ok.contentType == "application/json" && statuses == [401, 401, 401, 403, 403, 200, 405, 202, 415]
        }
        await checkAsync("Undo from the receipt row: an added event and reminder are removed once; already deleted says so; mail drafts offer none") {
            let host = PippaMCPHost.demo(now: now)
            let tools = PippaMCPWriteTools(host: host)
            let event = await tools.call("calendar_add", ["title": "Undo fixture", "date": "tomorrow", "time": "10:00"])
            let reminder = await tools.call("reminder_add", ["title": "Undo fixture"])
            guard let added = event.receipt, added.canUndo, let note = reminder.receipt, note.canUndo else { return false }
            let undone = await host.undo(added), undoneNote = await host.undo(note)
            // Pressed again (e.g. an older copy of the conversation): nothing is offered, nothing removed twice.
            let again = await host.undo(undone)
            // Deleted by the person in the meantime: says so instead of claiming it removed something.
            var stale = added; stale.undo = nil
            let gone = await host.undo(stale)
            let draft = PippaMCPWriteReceipt(action: "mailDraft", outcome: "done", name: "Re: Termin")
            let failed = PippaMCPWriteReceipt(action: "calendarAdd", outcome: "failed", name: "x", created: added.created)
            return undone.undo == "removed" && !undone.canUndo && undoneNote.undo == "removed" && again == undone
                && gone.undo == "gone" && !draft.canUndo && !failed.canUndo
        }

        check("MCP: new key on each start, 64 hex characters") {
            let a = PippaMCPServer.newToken(), b = PippaMCPServer.newToken()
            return a != b && a.count == 64 && a.allSatisfy { $0.isHexDigit && !$0.isUppercase }
        }
        await checkAsync("MCP server: real run on 127.0.0.1 (initialize + tools/call over HTTP), not reachable via the network address") {
            guard let server = try? PippaMCPServer(host: PippaMCPHost.demo(now: now)) else { return false }
            do { try await server.start() } catch { print("  Start: \(error)"); return false }
            defer { server.stop() }
            func post(_ url: URL, _ body: String, token: String?) async -> (Int, [String: Any]?) {
                var request = URLRequest(url: url, timeoutInterval: 5)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
                if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                request.httpBody = Data(body.utf8)
                guard let (data, response) = try? await URLSession.shared.data(for: request) else { return (-1, nil) }
                return ((response as? HTTPURLResponse)?.statusCode ?? 0, try? JSONSerialization.jsonObject(with: data) as? [String: Any])
            }
            let (initStatus, initReply) = await post(server.url, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#, token: server.token)
            FrontAppStage.shared.current = FrontApp(name: "Microsoft Excel", bundleID: ExcelScript.bundleIdentifier, pid: 4)
            let (callStatus, callReply) = await post(server.url, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"front_read","arguments":{}}}"#, token: server.token)
            FrontAppStage.shared.current = nil
            let (noTokenStatus, _) = await post(server.url, #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#, token: nil)
            let text = (((callReply?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
            // A network address of this Mac (not loopback): nobody may get through there.
            var external: String?
            var list: UnsafeMutablePointer<ifaddrs>?
            if getifaddrs(&list) == 0, let first = list {
                var cursor: UnsafeMutablePointer<ifaddrs>? = first
                while let entry = cursor {
                    if let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), (entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 {
                        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                            external = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self); break
                        }
                    }
                    cursor = entry.pointee.ifa_next
                }
                freeifaddrs(list)
            }
            var outsideStatus = -1
            if let external, let url = URL(string: "http://\(external):\(server.port)/mcp") {
                outsideStatus = await post(url, #"{"jsonrpc":"2.0","id":4,"method":"ping"}"#, token: server.token).0
            }
            print("  Port \(server.port); via \(external ?? "no network address"): \(outsideStatus == -1 ? "not reachable" : "status \(outsideStatus)")")
            return initStatus == 200 && (initReply?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25"
                && callStatus == 200 && text.contains("Kosten 2026") && noTokenStatus == 401 && outsideStatus == -1
        }
    }
}
