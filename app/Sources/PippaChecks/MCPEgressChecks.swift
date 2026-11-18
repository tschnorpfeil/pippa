import Foundation
import PippaCore

private struct EgressReply {
    let wire: String
    let payload: [String: Any]
    let isError: Bool
}

private func egressCall(_ server: PippaMCPServer, _ tool: String, _ arguments: [String: Any]) async throws -> EgressReply {
    let body = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": arguments],
    ])
    let response = await server.respond(to: .init(method: "POST", path: "/mcp", headers: [
        "host": "127.0.0.1:4242", "authorization": "Bearer " + server.token, "content-type": "application/json",
    ], body: body), port: 4242)
    guard response.status == 200,
          let envelope = try JSONSerialization.jsonObject(with: response.body) as? [String: Any],
          let result = envelope["result"] as? [String: Any], let isError = result["isError"] as? Bool,
          let content = result["content"] as? [[String: Any]], content.count == 1,
          let text = content.first?["text"] as? String,
          let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
        throw CocoaError(.coderReadCorrupt)
    }
    return EgressReply(wire: String(decoding: response.body, as: UTF8.self), payload: payload, isError: isError)
}

func runMCPEgressChecks() async {
    await checkAsync("H3: an online endpoint cannot snapshot or act on the local signed-in page") {
        let marker = "PRIVATE-PAGE-H3"
        let browser = DemoBrowserOperator { url, id in
            .init(snapshotId: id, url: url.absoluteString, title: marker, text: marker,
                  refs: [.init(ref: "@e1", role: "button", name: marker)])
        }
        let turns = PippaMCPTurns()
        let handoffs = LockedBox<[String]>([])
        let confirmed = LockedBox<[String]>([])
        var host = PippaMCPHost.demo()
        host.requireActiveWriteTurn = true
        host.turns = turns
        host.browser = browser
        host.resolveHostIsPrivate = { _ in false }
        host.confirmBrowser = { action, _, _ in confirmed.mutate { $0.append(action) }; return true }
        host.onBrowserHandoff = { reason, _ in handoffs.mutate { $0.append(reason) } }
        let local = try PippaMCPServer(host: host)
        let before = PippaMCPTurn()
        turns.begin(before)
        let opened = try await egressCall(local, "browse", ["action": "open", "url": "https://example.org/account"])
        turns.end(before)
        local.revoke()

        let challengeMarker = "PRIVATE-CHALLENGE-H3"
        let onlineBrowser = await PippaMCPOnlineBrowser { _ in
            DemoBrowserOperator { url, id in
                if url.path == "/login" {
                    return .init(snapshotId: id, url: url.absoluteString, title: challengeMarker, text: challengeMarker,
                                 refs: [.init(ref: "@e1", role: "textbox", name: challengeMarker)], loginDetected: true)
                }
                return .init(snapshotId: id, url: url.absoluteString, title: "Public page", text: "PUBLIC-PAGE-H3",
                             refs: [.init(ref: "@e1", role: "button", name: "Details")])
            }
        }
        var egress = PippaMCPEgress(rules: SourceSharing(), web: true)
        egress.onlineBrowser = onlineBrowser
        host.egress = egress
        let online = try PippaMCPServer(host: host)
        let during = PippaMCPTurn()
        turns.begin(during)
        let snapshot = try await egressCall(online, "browse", ["action": "snapshot"])
        let oldRef = try await egressCall(online, "browse", ["action": "click", "ref": "@e1", "snapshot_id": "s1"])
        let back = try await egressCall(online, "browse", ["action": "back"])
        let publicPage = try await egressCall(online, "browse", ["action": "open", "url": "https://example.org/public"])
        let publicClick = try await egressCall(online, "browse", ["action": "click", "ref": "@e1", "snapshot_id": "s1"])
        let challenge = try await egressCall(online, "browse", ["action": "open", "url": "https://example.org/login"])
        let afterChallenge = try await egressCall(online, "browse", ["action": "snapshot"])
        let reopened = try await egressCall(online, "browse", ["action": "open", "url": "https://example.org/public"])
        turns.end(during)
        await onlineBrowser.end(during)
        let next = PippaMCPTurn()
        turns.begin(next)
        let nextSnapshot = try await egressCall(online, "browse", ["action": "snapshot"])
        turns.end(next)
        online.revoke()
        await onlineBrowser.invalidate()

        host.egress = nil
        let after = PippaMCPTurn()
        turns.begin(after)
        let restored = try await egressCall(PippaMCPServer(host: host), "browse", ["action": "snapshot"])
        turns.end(after)

        let refused = [snapshot, oldRef, back, challenge, afterChallenge, nextSnapshot]
        let publicReplies = [publicPage, publicClick, reopened]
        return opened.wire.contains(marker) && restored.wire.contains(marker)
            && refused.allSatisfy { $0.isError && !$0.wire.contains(challengeMarker) && !$0.wire.contains(marker) }
            && publicReplies.allSatisfy { !$0.isError && $0.wire.contains("PUBLIC-PAGE-H3") && !$0.wire.contains(marker) }
            && handoffs.value.isEmpty && confirmed.value == ["open", "open", "click"]
            && browser.actions == [.open(URL(string: "https://example.org/account")!), .snapshot]
    }

    await checkAsync("H3: native access errors keep local diagnostic text out of the online wire reply") {
        let marker = "PRIVATE-MAIL-ACCESS-H3"
        var host = PippaMCPHost.demo()
        guard let demo = host.integrations as? DemoIntegrations else { return false }
        demo.set(.mail, .unavailable(marker))
        let draft = ["body": "Synthetic draft", "subject": "Synthetic subject"]
        let local = try PippaMCPServer(host: host)
        let before = try await egressCall(local, "mail_draft", draft)
        host.egress = PippaMCPEgress(rules: SourceSharing(), web: false)
        let online = try PippaMCPServer(host: host)
        let blocked = try await egressCall(online, "mail_draft", draft)
        return before.wire.contains(marker) && blocked.isError && blocked.payload["status"] as? String == "unavailable"
            && !blocked.wire.contains(marker) && demo.insertedDrafts.isEmpty
    }

    await checkAsync("H3: native writers create once and keep events, lists and original mail off the online wire") {
        let eventMarker = "PRIVATE-EVENT-H3", calendarMarker = "PRIVATE-CALENDAR-H3"
        let listMarker = "PRIVATE-LIST-H3", mailMarker = "PRIVATE-MAIL-H3"
        var host = PippaMCPHost.demo()
        guard let demo = host.integrations as? DemoIntegrations else { return false }
        let calendar = host.calendar
        let today = calendar.startOfDay(for: host.now())
        guard let start = calendar.date(bySettingHour: 16, minute: 0, second: 0, of: today) else { return false }
        host.now = { today }
        demo.calendarNames = [calendarMarker]
        demo.calendarEvents = [.init(id: "event-h3", title: eventMarker, start: start,
                                     end: start.addingTimeInterval(3600), calendar: calendarMarker)]
        demo.reminderLists = [listMarker]
        demo.sampleMail = .init(subject: mailMarker, sender: "Fixture <private-h3@example.invalid>", date: today,
                                body: "PRIVATE-MAIL-BODY-H3", attachmentNames: [], messageID: "private-h3@example.invalid")
        let event: [String: Any] = ["title": "New event", "date": "today", "time": "16:15"]
        let reminder = ["title": "New reminder", "list": "Unavailable fixture list"]
        let reply = ["body": "Synthetic reply", "reply_to": "selected"]
        let draft = ["body": "Synthetic draft", "subject": "New draft", "to": "fixture@example.invalid"]
        let local = try PippaMCPServer(host: host)
        let localEvent = try await egressCall(local, "calendar_add", event)
        let localReminder = try await egressCall(local, "reminder_add", reminder)
        let localReply = try await egressCall(local, "mail_draft", reply)
        local.revoke()
        guard localEvent.wire.contains(eventMarker), localEvent.wire.contains(calendarMarker),
              localReminder.wire.contains(listMarker), localReply.wire.contains(mailMarker),
              demo.createdCount == 2, demo.insertedDrafts.count == 1 else { return false }

        host.egress = PippaMCPEgress(rules: SourceSharing(), web: false)
        let online = try PippaMCPServer(host: host)
        let added = try await egressCall(online, "calendar_add", event)
        let reminded = try await egressCall(online, "reminder_add", reminder)
        let drafted = try await egressCall(online, "mail_draft", draft)
        let blocked = try await egressCall(online, "mail_draft", reply)
        online.revoke()

        var rules = SourceSharing()
        rules.calendar = .localOnly; rules.reminders = .localOnly; rules.mail = .localOnly
        host.egress = PippaMCPEgress(rules: rules, web: false)
        let restricted = try PippaMCPServer(host: host)
        let refused = try await [
            egressCall(restricted, "calendar_add", event), egressCall(restricted, "reminder_add", reminder),
            egressCall(restricted, "mail_draft", draft),
        ]
        let onlineReplies = [added, reminded, drafted, blocked] + refused
        return [added, reminded, drafted].allSatisfy { !$0.isError && $0.payload["done"] as? Bool == true }
            && drafted.payload["state"] as? String == "new_mail_open" && drafted.payload["sent"] as? Bool == false
            && blocked.isError && blocked.payload["status"] as? String == "reply_needs_mail"
            && refused.allSatisfy { $0.isError && $0.payload["status"] as? String == "stays_on_mac" }
            && onlineReplies.allSatisfy { reply in
                ![eventMarker, calendarMarker, listMarker, mailMarker, "private-h3@example.invalid"].contains { reply.wire.contains($0) }
            }
            && demo.createdCount == 4 && demo.insertedDrafts.count == 2 && demo.insertedDrafts.last?.isReply == false
    }

    await checkAsync("Egress: calendar_add naming any calendar is refused before Calendar is touched; native not_found/ambiguous stay typed") {
        let host = PippaMCPHost.demo()
        guard let demo = host.integrations as? DemoIntegrations else { return false }
        demo.calendarNames = ["PRIVATE-CAL-A", "dup", "Dup"]
        let egress = PippaMCPEgress(rules: SourceSharing(), web: false)
        let probes: [Any] = ["PRIVATE-CAL-A", "", "  ", 0, false, NSNull(), ["x"]]
        let refusedAll = probes.allSatisfy { egress.refusal("calendar_add", ["title": "x", "date": "today", "calendar": $0]) == "needs_calendar" }
        let plain = egress.refusal("calendar_add", ["title": "x", "date": "today"])
        let tools = PippaMCPWriteTools(host: host)
        let missing = await tools.call("calendar_add", ["title": "x", "date": "tomorrow", "calendar": "Nope"])
        let twice = await tools.call("calendar_add", ["title": "x", "date": "tomorrow", "calendar": "dup"])
        let scrubbed = [egress.scrubWriter("calendar_add", missing), egress.scrubWriter("calendar_add", twice)]
        return refusedAll && plain == nil && demo.createdCount == 0
            && scrubbed[0].isError && scrubbed[0].text.contains("\"status\":\"not_found\"")
            && scrubbed[1].isError && scrubbed[1].text.contains("\"status\":\"ambiguous\"")
            && scrubbed.allSatisfy { !$0.text.contains("PRIVATE-CAL-A") && !$0.text.contains("unclear") }
    }

    await checkAsync("H3: malformed native outcomes fail closed and unknown fields are discarded") {
        let host = PippaMCPHost.demo()
        let egress = PippaMCPEgress(rules: SourceSharing(), web: false)
        var native = await PippaMCPWriteTools(host: host).call("calendar_add", [:])
        let marker = "PRIVATE-NATIVE-PAYLOAD-H3"
        for malformed in [
            marker, "[\"\(marker)\"]", #"{ "done": 1, "error": "\#(marker)" }"#,
            #"{ "done": false, "status": "\#(marker)" }"#,
            #"{ "done": false, "state": "unclear", "dispatched": "\#(marker)" }"#,
        ] {
            native.text = malformed
            let filtered = egress.scrubWriter("calendar_add", native)
            guard filtered.isError, filtered.text.contains("\"state\":\"unclear\""), !filtered.text.contains(marker) else { return false }
        }
        native.text = #"{ "done": true, "added": { "title": "\#(marker)" }, "future_field": "\#(marker)" }"#
        native.isError = false
        let completed = egress.scrubWriter("calendar_add", native)
        return !completed.isError && completed.text.contains("\"done\":true") && !completed.text.contains(marker)
    }
}
