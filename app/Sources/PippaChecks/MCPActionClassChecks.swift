import Foundation
import PiRPC
import PippaCore

/// Action classes (PippaMCPActionClass.swift): one class per tool, annotations from the class, and the gate at dispatch.
/// The card is proven with check-only host tools, because no shipped tool is `irreversible` or `external` behind a card.
func runMCPActionClassChecks() async {
    let context = MCPCheckContext()

    let listed = PippaMCPTools.toolList().compactMap { $0["name"] as? String }
    let piTools = PippaPiLaunch.tools.filter { !$0.hasPrefix("mcp__") }
    check("Action classes: every MCP tool and every Pi tool has exactly one class") {
        let missing = (listed + PippaMCPTools.toolNames + piTools).filter { PippaActionClasses.of($0) == nil }
        if !missing.isEmpty { print("  without a class: \(missing)") }
        return missing.isEmpty && PippaPiLaunch.tools.contains("mcp__pippa__*")
    }
    check("Action classes: readers read; events, reminders, drafts, prepared files, moves and write undoable") {
        let readers = ["calendar_read", "reminders_read", "mail_search", "mail_read", "photos_search", "front_read", "read_document",
                       "read", "search_files", "list_folder"]
        let undoable = ["calendar_add", "reminder_add", "mail_draft", "prepare_files", "move_files", "write"]
        return readers.allSatisfy { PippaActionClasses.of($0) == .read } && undoable.allSatisfy { PippaActionClasses.of($0) == .undoable }
            && ["bash", "browse", "web_search", "fetch_content"].allSatisfy { PippaActionClasses.of($0) == .external }
    }
    check("Action classes: MCP annotations match the class of every listed tool") {
        func expected(_ c: PippaActionClass) -> (readOnly: Bool, destructive: Bool, openWorld: Bool) {
            switch c {
            case .read: (true, false, false)
            case .undoable: (false, false, false)
            case .irreversible: (false, true, false)
            case .external: (false, false, true)
            }
        }
        return PippaMCPTools.toolList().allSatisfy { tool in
            guard let name = tool["name"] as? String, let c = PippaActionClasses.of(name) else { return false }
            let a = tool["annotations"] as? [String: Any] ?? [:], e = expected(c)
            let ok = a["readOnlyHint"] as? Bool == e.readOnly && a["destructiveHint"] as? Bool == e.destructive
                && a["openWorldHint"] as? Bool == e.openWorld && a["title"] as? String == tool["title"] as? String
            if !ok { print("  \(name): \(a)") }
            return ok
        }
    }

    /// A host with one check-only tool, a running answer, and a card that answers through `answer`.
    final class Gate: @unchecked Sendable {
        let runs = LockedBox<[[String: String]]>([])
        let cards = LockedBox<[PippaMCPConfirmation]>([])
        let turns = PippaMCPTurns()
        let turn = PippaMCPTurn()
        var host = PippaMCPHost.demo()
        init(_ actionClass: PippaActionClass?, answer: (@Sendable (PippaMCPConfirmation) async -> Bool)?) {
            let runs = runs, cards = cards
            host.turns = turns
            host.requireActiveWriteTurn = true
            if let answer { host.confirmAction = { card in cards.mutate { $0.append(card) }; return await answer(card) } }
            host.extraTools = [PippaMCPHostTool(name: "check_send", actionClass: actionClass, describe: { arguments in
                guard let to = arguments["to"] as? String, let text = arguments["text"] as? String else { return nil }
                return PippaMCPConfirmation(tool: "check_send", actionClass: actionClass ?? .external, title: "Send this message?",
                                            recipient: to, content: text)
            }, run: { arguments in
                runs.mutate { $0.append(arguments.compactMapValues { $0 as? String }) }
                return PippaMCPToolResult(text: #"{"done":true}"#, isError: false)
            })]
            turns.begin(turn)
        }
        var tools: PippaMCPTools { PippaMCPTools(host: host) }
    }
    let message: [String: Any] = ["to": "anna@example.test", "text": "Hallo Anna, bis morgen."]

    await checkAsync("Action classes: an external tool without a yes never dispatches, whatever the arguments say") {
        let none = Gate(.external, answer: nil)
        let forged = await context.call(none.tools, "check_send", message.merging(["confirmed": true, "approved": "yes"]) { a, _ in a })
        let no = Gate(.external, answer: { _ in false })
        let declined = await context.call(no.tools, "check_send", message)
        let notDone = [forged.json, declined.json].allSatisfy {
            $0["done"] as? Bool == false && $0["dispatched"] as? Bool == false
                && ($0["next"] as? String ?? "").contains("Do not try another way")
        }
        return none.runs.value.isEmpty && no.runs.value.isEmpty && notDone && forged.isError
            && declined.json["status"] as? String == "declined" && no.cards.value.count == 1
    }
    await checkAsync("Action classes: with a yes it dispatches once, after a card with the recipient and the exact text") {
        let yes = Gate(.external, answer: { _ in true })
        let result = await context.call(yes.tools, "check_send", message)
        let card = yes.cards.value.first
        let irreversible = Gate(.irreversible, answer: { _ in true })
        _ = await context.call(irreversible.tools, "check_send", message)
        return !result.isError && result.json["done"] as? Bool == true && yes.runs.value == [message as! [String: String]]
            && yes.cards.value.count == 1 && card?.recipient == "anna@example.test" && card?.content == "Hallo Anna, bis morgen."
            && card?.message.contains("Hallo Anna, bis morgen.") == true && card?.turnID == yes.turn.id
            && irreversible.runs.value.count == 1 && irreversible.cards.value.count == 1
    }
    await checkAsync("Action classes: a confirmed class with nothing to show runs nothing and asks nothing") {
        let gate = Gate(.external, answer: { _ in true })
        let result = await context.call(gate.tools, "check_send", ["to": "anna@example.test"])
        return result.json["dispatched"] as? Bool == false && gate.runs.value.isEmpty && gate.cards.value.isEmpty
    }
    await checkAsync("Action classes: a tool without a class is blocked before dispatch, even with a yes ready") {
        let gate = Gate(nil, answer: { _ in true })
        let result = await context.call(gate.tools, "check_send", message)
        return result.isError && result.json["status"] as? String == "blocked" && result.json["dispatched"] as? Bool == false
            && gate.runs.value.isEmpty && gate.cards.value.isEmpty
    }
    await checkAsync("Action classes: read and undoable tools dispatch without any card, as before") {
        let read = Gate(.read, answer: { _ in false }), undoable = Gate(.undoable, answer: { _ in false })
        let a = await context.call(read.tools, "check_send", message), b = await context.call(undoable.tools, "check_send", message)
        // A shipped undoable tool: calendar_add adds the event with a card that would have said no.
        let shipped = Gate(.external, answer: { _ in false })
        let added = await context.call(shipped.tools, "calendar_add", ["title": "Gate check", "date": "tomorrow", "time": "10:00"])
        let reader = await context.call(shipped.tools, "calendar_read", ["period": "today"])
        return !a.isError && !b.isError && read.runs.value.count == 1 && undoable.runs.value.count == 1
            && read.cards.value.isEmpty && undoable.cards.value.isEmpty
            && !added.isError && added.json["done"] as? Bool == true && !reader.isError && shipped.cards.value.isEmpty
    }
    await checkAsync("Action classes: Stop or a newer answer while the card is open means not dispatched; a late yes does nothing") {
        // Stop: the answer ends while the card waits, then the button is pressed.
        let stopped = LockedBox<Gate?>(nil)
        let stop = Gate(.external, answer: { _ in
            if let gate = stopped.value { gate.turns.end(gate.turn) }
            return true
        })
        stopped.mutate { $0 = stop }
        let a = await context.call(stop.tools, "check_send", message)
        // Replaced: a newer answer begins while the card waits.
        let replacedBox = LockedBox<Gate?>(nil)
        let replace = Gate(.external, answer: { _ in
            if let gate = replacedBox.value { gate.turns.begin(PippaMCPTurn()) }
            return true
        })
        replacedBox.mutate { $0 = replace }
        let b = await context.call(replace.tools, "check_send", message)
        // Already stopped before the call: no card at all.
        let ended = Gate(.external, answer: { _ in true })
        ended.turns.end(ended.turn)
        let c = await context.call(ended.tools, "check_send", message)
        return [a, b, c].allSatisfy { $0.json["status"] as? String == "cancelled" && $0.json["dispatched"] as? Bool == false }
            && stop.runs.value.isEmpty && replace.runs.value.isEmpty && ended.runs.value.isEmpty
            && stop.cards.value.count == 1 && replace.cards.value.count == 1 && ended.cards.value.isEmpty
    }
}
