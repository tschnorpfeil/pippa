import Foundation
import PippaCore

/// Cards under the answer: built from Pippa's own tool result (never the model's text), stored with the answer,
/// older histories without cards still open. Synthetic mails via `DemoHostData` only.
func runResultCardChecks() async {
    var berlin = Calendar(identifier: .gregorian)
    berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!; berlin.locale = Locale(identifier: "de_DE")

    check("Mail card: sender name without address, one-line preview at most 160 characters, Message-ID without brackets") {
        let long = String(repeating: "Wort ", count: 60)
        let mails = [MailHeader(subject: "Zeile eins\nZeile zwei", sender: "Hausverwaltung Berger <info@berger-hv.de>", date: nil,
                                mailbox: "Eingang", preview: "Guten Tag,\n\n  anbei  die Abrechnung.", messageID: "<a1@berger.example>"),
                     MailHeader(subject: "Ohne Namen", sender: "<nur@adresse.example>", date: nil, mailbox: "Eingang", preview: long),
                     MailHeader(subject: "Ohne ID", sender: "Schule", date: nil, mailbox: "Eingang", preview: "", messageID: " ")]
        let card = MailCard(query: "Berger", mails: mails, total: 3, calendar: berlin)
        return card.items.map(\.sender) == ["Hausverwaltung Berger", "nur@adresse.example", "Schule"]
            && card.items[0].subject == "Zeile eins Zeile zwei" && card.items[0].preview == "Guten Tag, anbei die Abrechnung."
            && card.items[1].preview.count == 160 && card.items[1].preview.hasSuffix("…")
            && card.items.map(\.messageID) == ["a1@berger.example", nil, nil] && card.items.allSatisfy { $0.dateLabel == nil }
    }
    check("Mail card: footer counts only when more mails matched than are shown") {
        let one = [DemoHostData.sampleMails[0]]
        let all = MailCard(query: "x", mails: one, total: 1, calendar: berlin)
        let some = MailCard(query: "x", mails: one, total: 4, calendar: berlin)
        return all.footer != some.footer && some.footer.contains("1") && some.footer.contains("4") && !all.footer.contains("4")
    }
    check("Cards are stored with the answer; receipts from before cards still open; an empty list stores nothing") {
        let mail = ResultCard.mail(MailCard(query: "Berger", mails: [DemoHostData.sampleMails[0]], total: 1, calendar: berlin))
        let receipt = ActionReceipt(items: [ActionReceipt.Item(action: "tool", outcome: "done", name: "read")], cards: [mail])
        let round = (try? JSONEncoder().encode(receipt)).flatMap { try? JSONDecoder().decode(ActionReceipt.self, from: $0) }
        let old = try? JSONDecoder().decode(ActionReceipt.self, from: Data(#"{"items":[{"action":"tool","outcome":"done","name":"read"}]}"#.utf8))
        return round?.cards == [mail] && old != nil && old?.cards == nil && ActionReceipt(items: [], cards: []).cards == nil
    }
    await checkAsync("mail_search and calendar_read hand a card to Pippa, outside what the model reads") {
        let notes = LockedBox<[PippaMCPReadNote]>([])
        var host = PippaMCPHost.demo()
        host.onRead = { note in notes.mutate { $0.append(note) } }
        let tools = PippaMCPTools(host: host)
        func call(_ name: String, _ arguments: [String: Any]) async -> String {
            let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]])
            let reply = await tools.handle(body).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            return (((reply?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        }
        let found = await call("mail_search", ["query": "Berger"])
        let none = await call("mail_search", ["query": "Steuer"])
        _ = await call("calendar_read", ["period": "today"])
        let cards = notes.value.map(\.card)
        guard cards.count == 3, case .mail(let mail)? = cards[0], case .calendar? = cards[2] else { return false }
        return mail.items.first?.messageID == "nk-2025@berger-hv.example" && mail.items.first?.sender == "Hausverwaltung Berger"
            && cards[1] == nil && !found.contains("nk-2025") && !none.isEmpty
    }
}

