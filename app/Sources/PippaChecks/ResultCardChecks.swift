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
    await checkAsync("Photos card: stored with the answer next to a mail card and read back the same (Codable)") {
        let photos = try await PippaMCPHost.demo().hostData.searchPhotos("Fahrrad", limit: 12)
        guard !photos.items.isEmpty else { return false }
        let card = ResultCard.photos(PhotoCard(query: "Fahrrad", items: photos.items.map {
            PhotoCard.Item(id: $0.id, date: $0.date, dateLabel: "x", label: $0.title.isEmpty ? $0.filename : $0.title)
        }, total: photos.total, previews: false, footer: "Fotos auf diesem Mac · 2 gefunden", truncatedNote: nil))
        let mail = ResultCard.mail(MailCard(query: "Berger", mails: [DemoHostData.sampleMails[0]], total: 1, calendar: berlin))
        let receipt = ActionReceipt(items: [ActionReceipt.Item(action: "read", outcome: "done", name: "Fotos durchsucht")], cards: [card, mail])
        let round = (try? JSONEncoder().encode(receipt)).flatMap { try? JSONDecoder().decode(ActionReceipt.self, from: $0) }
        guard case .photos(let back)? = round?.cards?.first else { return false }
        return round?.cards == [card, mail] && back.items.map(\.id) == ["DEMO-0001/L0/001", "DEMO-0002/L0/001"] && back.items.first?.date != nil
    }
    check("A card from a newer app (unknown kind) is dropped; the receipt and the other cards still open") {
        let mail = ResultCard.mail(MailCard(query: "Berger", mails: [DemoHostData.sampleMails[0]], total: 1, calendar: berlin))
        guard let data = try? JSONEncoder().encode(ActionReceipt(items: [ActionReceipt.Item(action: "tool", outcome: "done", name: "read")], cards: [mail])),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], var cards = json["cards"] as? [Any] else { return false }
        cards.insert(["hologram": ["_0": ["x": 1]]], at: 0)
        json["cards"] = cards
        let onlyUnknown = #"{"items":[],"cards":[{"hologram":{}}]}"#
        let mixed = (try? JSONSerialization.data(withJSONObject: json)).flatMap { try? JSONDecoder().decode(ActionReceipt.self, from: $0) }
        let none = try? JSONDecoder().decode(ActionReceipt.self, from: Data(onlyUnknown.utf8))
        return mixed?.cards == [mail] && mixed?.items.count == 1 && none != nil && none?.cards == nil
    }
    check("Mail card: at most 20 rows, footer counts what is shown") {
        let many = Array(repeating: DemoHostData.sampleMails[0], count: 25)
        let card = MailCard(query: "x", mails: many, total: 25, calendar: berlin)
        return card.items.count == MailCard.maxItems && card.footer.contains("20") && card.footer.contains("25")
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
    check("Reminders card: overdue only before now (with a time) or before today (day only), list names only across several lists") {
        let now = berlin.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 14, minute: 32))!
        func at(_ d: Int, _ h: Int = 0, _ m: Int = 0) -> Date { berlin.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))! }
        let items = [ReminderItem(title: "Müll raus", list: "Zuhause", due: at(7, 9), dueHasTime: true),
                     ReminderItem(title: "Blumen gießen", list: "Zuhause", due: at(7), dueHasTime: false),
                     ReminderItem(title: "Steuer", list: "Büro", due: at(6), dueHasTime: false),
                     ReminderItem(title: "Zeile\nzwei", list: "Büro")]
        let card = ReminderCard(days: 1, reminders: items, total: 4, now: now, calendar: berlin)
        let single = ReminderCard(days: nil, reminders: Array(items.prefix(2)), total: 9, now: now, calendar: berlin)
        return card.items.map(\.overdue) == [true, false, true, false] && card.items[3].title == "Zeile zwei" && card.items[3].dueLabel == nil
            && card.items[0].dueLabel != nil && card.showsList && !single.showsList
            && card.title != single.title && single.footer.contains("2") && single.footer.contains("9") && !card.footer.contains("4")
    }
    await checkAsync("reminders_read hands a card to Pippa; nothing open means no card") {
        let notes = LockedBox<[PippaMCPReadNote]>([])
        var host = PippaMCPHost.demo()
        host.onRead = { note in notes.mutate { $0.append(note) } }
        let tools = PippaMCPTools(host: host)
        let body = try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                                "params": ["name": "reminders_read", "arguments": [:] as [String: Any]]])
        _ = await tools.handle(body)
        guard case .reminders(let card)? = notes.value.first?.card else { return false }
        let round = (try? JSONEncoder().encode(ActionReceipt(items: [], cards: [.reminders(card)])))
            .flatMap { try? JSONDecoder().decode(ActionReceipt.self, from: $0) }
        return !card.items.isEmpty && card.items.count <= ReminderCard.maxItems && round?.cards == [.reminders(card)]
    }
}

