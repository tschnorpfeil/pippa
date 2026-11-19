import Foundation

// Demo fixtures for `DemoHostData` (PIPPA_DEMO=1, checks and the end-to-end run). Freely invented: no real mails, photos
// or reminders.
extension DemoHostData {
    /// Freely invented (no real mails).
    public static let sampleMails: [MailHeader] = [
        MailHeader(subject: "Nebenkostenabrechnung 2025", sender: "Hausverwaltung Berger <info@berger-hv.de>",
                   date: DayDate(year: 2026, month: 10, day: 1)?.localNoon, mailbox: "Eingang",
                   preview: "Guten Tag, anbei die Nebenkostenabrechnung 2025. Die Nachzahlung von 312,48 € ist zahlbar bis 31.10.2026.",
                   messageID: "nk-2025@berger-hv.example"),
        MailHeader(subject: "Elternabend am Donnerstag", sender: "Testschule Musterstadt <sekretariat@testschule.example>",
                   date: DayDate(year: 2026, month: 10, day: 5)?.localNoon, mailbox: "Eingang",
                   preview: "Liebe Eltern, der Elternabend der Klasse 4b findet am Donnerstag um 19:30 Uhr im Raum 12 statt.",
                   messageID: "elternabend-4b@testschule.example", unread: true),
    ]

    /// Freely invented (no real photos): labels as Photos would find them, then the hit.
    public static let samplePhotos: [(words: [String], hit: PhotoHit)] = [
        (["Fahrrad", "bicycle", "Köln"], PhotoHit(id: "DEMO-0001/L0/001", date: DayDate(year: 2026, month: 5, day: 1)?.localNoon, filename: "IMG_0101.HEIC")),
        (["Fahrrad", "bicycle", "Strand", "beach", "Knokke"],
         PhotoHit(id: "DEMO-0002/L0/001", date: DayDate(year: 2025, month: 8, day: 3)?.localNoon, filename: "IMG_0202.HEIC", title: "Radtour (Beispiel)")),
        (["Strand", "beach", "Knokke"], PhotoHit(id: "DEMO-0003/L0/001", date: DayDate(year: 2025, month: 8, day: 4)?.localNoon, filename: "IMG_0203.HEIC")),
        (["Hund", "dog"], PhotoHit(id: "DEMO-0004/L0/001", date: nil, filename: "Scan 12.jpg")),
    ]

    /// Freely invented, relative to `now`.
    public static func sampleReminders(now: Date, calendar: Calendar = .autoupdatingCurrent) -> [ReminderItem] {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        return [
            ReminderItem(title: "Nebenkosten überweisen (Beispiel)", list: "Erinnerungen", due: tomorrow),
            ReminderItem(title: "Geschenk für Oma besorgen (Beispiel)", list: "Privat"),
        ]
    }
}
