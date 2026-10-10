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
    check("Web sources card: pages read first, the same page once, only http(s), links from search results without punctuation") {
        let now = berlin.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 14, minute: 32))!
        let search = "1. [Wetter Köln](https://www.wetter.example/koeln/morgen) – Regen ab 15 Uhr.\n2. https://dwd.example/warnungen, "
            + "siehe auch javascript:alert(1) und https://wetter.example/koeln/morgen/#top."
        guard let card = WebSourcesCard(queries: ["Wetter morgen Köln", ""], pagesRead: ["https://wetter.example/koeln/morgen", "file:///etc/hosts"],
                                        searchResults: [search], now: now, calendar: berlin) else { return false }
        let many = (1...12).map { "https://seite\($0).example/" }.joined(separator: " ")
        let capped = WebSourcesCard(queries: [], pagesRead: [], searchResults: [many], now: now, calendar: berlin)
        return card.items.map(\.host) == ["wetter.example", "dwd.example"] && card.items.map(\.read) == [true, false]
            && card.items[0].path == "/koeln/morgen" && card.items[1].path == "/warnungen" && card.queries == ["Wetter morgen Köln"]
            && card.footer.contains("14:32") && capped?.items.count == WebSourcesCard.maxItems && capped?.items.first?.path == nil
            && WebSourcesCard(queries: ["x"], pagesRead: [], searchResults: ["keine Treffer"], now: now, calendar: berlin) == nil
            && (try? JSONEncoder().encode(ActionReceipt(items: [], cards: [.web(card)])))
                .flatMap { try? JSONDecoder().decode(ActionReceipt.self, from: $0) }?.cards == [.web(card)]
    }
    check("Memory line: what Pippa kept or let go, never the text of something it refused to keep") {
        func de(_ outcome: String, _ add: String?, _ forget: String?, _ reason: String? = nil) -> String {
            ActionReceipt.Item(action: "remember", outcome: outcome, name: add, toName: forget, reason: reason).line(language: "de")
        }
        return de("done", "Meine Ärztin heißt Dr. Wolf", nil) == "Gemerkt: „Meine Ärztin heißt Dr. Wolf“"
            && de("done", "Ärztin: Dr. Lang", "Dr. Wolf") == "Gemerkt: „Ärztin: Dr. Lang“ (statt „Dr. Wolf“)"
            && de("done", nil, "Dr. Wolf") == "Vergessen: „Dr. Wolf“"
            && de("done", nil, "Dr. Wolf", "nothingMatched") == "Nichts zu vergessen für „Dr. Wolf“"
            && de("done", nil, "*") == "Alles vergessen, was Pippa über dich wusste"
            && de("failed", "IBAN DE89 3704 0044 0532 0130 00", nil) == "Nicht gemerkt"
    }
    check("Calendar follow-up buttons: from the period read, and each one is answered by the calendar itself (de, en)") {
        let now = berlin.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 14, minute: 32))!
        func read(_ kind: CalendarRange.Kind, day: Int) -> ConversationCalendarRead {
            let start = berlin.date(from: DateComponents(year: 2026, month: 10, day: day))!
            return ConversationCalendarRead(state: .read, question: "x", range: CalendarRange(kind: kind, start: start, end: start.addingTimeInterval(86_400)))
        }
        var ok = true
        for language in ["de", "en"] {
            let today = CalendarConversation.followUps(for: read(.day, day: 7), now: now, calendar: berlin, language: language)
            let week = CalendarConversation.followUps(for: read(.restOfWeek, day: 7), now: now, calendar: berlin, language: language)
            let all = today + week + CalendarConversation.followUps(for: read(.weekend, day: 10), now: now, calendar: berlin, language: language)
            ok = ok && today.count == 2 && week.count == 2
                && all.allSatisfy { CalendarIntent.parse($0, now: now, calendar: berlin, recentCalendarTurn: true) != nil }
        }
        var denied = read(.day, day: 7); denied.state = .denied
        return ok && CalendarConversation.followUps(for: read(.lastWeek, day: 1), now: now, calendar: berlin).isEmpty
            && CalendarConversation.followUps(for: denied, now: now, calendar: berlin).isEmpty
            && CalendarConversation.followUps(for: read(.day, day: 7), now: now, calendar: berlin, language: "de") == ["Und morgen?", "Und diese Woche?"]
    }
    check("Files card: files the answer names first, folders and missing files left out") {
        let a = URL(fileURLWithPath: "/Users/x/Documents/Mietvertrag.pdf"), b = URL(fileURLWithPath: "/Users/x/Bilder/Urlaub.jpg")
        let gone = URL(fileURLWithPath: "/Users/x/weg.txt"), folder = URL(fileURLWithPath: "/Users/x/Documents", isDirectory: true)
        let order = FoundFiles.ordered([a, folder, gone, b], answer: "Das Bild ist [Urlaub.jpg](\(b.absoluteString)).") { $0 != gone }
        return order == [b, a] && FoundFiles.ordered([], answer: "") == []
    }
    check("What Pippa knows: read the remember file, forget one fact or all, other lines stay, only the person can read it") {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-memory-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("memory.md")
        write("# Meine Notiz\n- Ärztin: Dr. Wolf\n-  Hund heißt Bello \n- Antworten kurz\n", file)
        let before = MemoryFacts.read(file)
        try? MemoryFacts.forget(["Hund heißt Bello"], in: file)
        let after = MemoryFacts.read(file)
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let mode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? 0
        try? MemoryFacts.forget(nil, in: file)
        let none = MemoryFacts.read(file)
        let missing = MemoryFacts.read(folder.appendingPathComponent("gibt-es-nicht.md"))
        return before == ["Ärztin: Dr. Wolf", "Hund heißt Bello", "Antworten kurz"] && after == ["Ärztin: Dr. Wolf", "Antworten kurz"]
            && text.hasPrefix("# Meine Notiz\n") && mode == 0o600 && none.isEmpty && missing.isEmpty
            && (try? String(contentsOf: file, encoding: .utf8))?.contains("# Meine Notiz") == true
    }
}
