import CoreGraphics
import Foundation
import PippaCore

@MainActor func runConversationRailChecks() {
    let berlin: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()
    func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        berlin.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    func summary(_ title: String, _ updated: Date, messages: Int = 2) -> ConversationSummary {
        ConversationSummary(id: UUID(), title: title, createdAt: updated, updatedAt: updated, messageCount: messages)
    }

    check("Conversation rail: groups by the day of the last change, newest first, empty ones only when open") {
        let open = summary("New Conversation", at(20, 9), messages: 0)
        let list = [summary("Today", at(28, 9)), summary("Yesterday late", at(27, 23, 59)), summary("Monday", at(26, 8)),
                    summary("Eight days", at(20, 23)), summary("Hidden empty", at(28, 8), messages: 0), open]
        let sections = ConversationRailGroups.sections(list, current: open.id, now: at(28, 15), calendar: berlin)
        let groups: [ConversationRailGroup] = [.today, .yesterday, .previousWeek, .older]
        guard sections.map(\.group) == groups else { return false }
        let titles: [[String]] = sections.map { $0.items.map(\.title) }
        return titles == [["New Conversation", "Today"], ["Yesterday late"], ["Monday"], ["Eight days"]]
    }
    check("Conversation rail: day boundaries follow the calendar, also across the end of summer time") {
        // Clocks went back on Sunday, 25 October 2026: that day has 25 hours, so 24-hour steps would put its 00:30
        // into the week before.
        let now = at(26, 10)
        func group(_ date: Date) -> ConversationRailGroup { ConversationRailGroups.group(of: date, now: now, calendar: berlin) }
        let groups = [at(26, 0), at(25, 23, 59), at(25, 0, 30), at(24, 23, 59), at(19, 0), at(18, 23, 59), at(27, 9)].map(group)
        let expected: [ConversationRailGroup] = [.today, .yesterday, .yesterday, .previousWeek, .previousWeek, .older, .today]
        return groups == expected
    }
    check("Conversation rail: below room for one rail the window is the plain conversation") {
        let narrow = ConversationRailLayout.resolve(width: 400, rails: .both)
        let edge = ConversationRailLayout.resolve(width: 631, rails: .both)
        let center: CGFloat = narrow.centerWidth
        return !narrow.showsToggles && !narrow.showsSessions && !narrow.showsDetails && center == 400
            && !edge.showsToggles && !edge.showsSessions && !edge.showsDetails
    }
    check("Conversation rail: rails show only beside 400 points of conversation; the one switched on last wins") {
        var detailsLast = ConversationRails.both
        detailsLast.set(.details, shown: true)
        let full = ConversationRailLayout.resolve(width: 1180, rails: .both)
        let tight = ConversationRailLayout.resolve(width: 919, rails: .both)
        let fits = ConversationRailLayout.resolve(width: 920, rails: .both)
        let swapped = ConversationRailLayout.resolve(width: 700, rails: detailsLast)
        let fallback = ConversationRailLayout.resolve(width: 650, rails: detailsLast)
        let centers: [CGFloat] = [full.centerWidth, fits.centerWidth]
        return centers == [660, 400] && full.showsSessions && full.showsDetails
            && tight.showsSessions && !tight.showsDetails && fits.showsSessions && fits.showsDetails
            && detailsLast.prefersDetails && swapped.showsDetails && !swapped.showsSessions
            && fallback.showsSessions && !fallback.showsDetails
    }
    check("Conversation rail: default widths grow with the rails and the text size") {
        let widths: [CGFloat] = [
            ConversationRailLayout.preferredWidth(rails: .plain),
            ConversationRailLayout.preferredWidth(rails: ConversationRails(sessions: true, details: false)),
            ConversationRailLayout.preferredWidth(rails: ConversationRails(sessions: false, details: true)),
            ConversationRailLayout.preferredWidth(rails: .both),
            ConversationRailLayout.preferredWidth(rails: .plain, scale: 1.25),
            ConversationRailLayout.resolve(width: 1475, rails: .both, scale: 1.25).centerWidth,
        ]
        return widths == [760, 892, 948, 1180, 950, 825]
    }
    check("Conversation rail: switching a hidden rail on makes room beside the rails that show") {
        let widths: [CGFloat] = [
            ConversationRailLayout.width(toShow: .details, beside: ConversationRailLayout.resolve(width: 700, rails: .both)),
            ConversationRailLayout.width(toShow: .sessions, beside: ConversationRailLayout.resolve(width: 760, rails: .plain)),
        ]
        return widths == [920, 632]
    }
    check("Conversation artifacts: what Pippa made comes from her own records, newest first, each once") {
        let found = URL(fileURLWithPath: "/fixture/Mietvertrag.pdf"), gone = URL(fileURLWithPath: "/fixture/Weg.pdf")
        let input = URL(fileURLWithPath: "/fixture/Inbox/Scan.pdf")
        let prepared = URL(fileURLWithPath: "/fixture/Results/Unterlagen.pdf")
        let card = PreparedFilesCard(jobID: UUID(), files: [prepared], pageCount: 3, totalBytes: 2048,
                                     sizeLimitBytes: nil, withinLimit: nil, note: "")
        let pi = UUID(), tidy = UUID()
        let answer = ConversationMessage(role: .assistant, text: "Found it.", attachments: [found, gone], receipt: pi,
            actions: ActionReceipt(items: [.init(action: "create", outcome: "done", name: "Notes.md"),
                                           .init(action: "move", outcome: "done", name: "a.txt", toName: "Archiv")]))
        // A receipt without action lines on an answer is still answer text, never a task result.
        let answerText = ConversationMessage(role: .assistant, text: "Answer text", modelLabel: "On this Mac", receipt: UUID())
        let preparedAnswer = ConversationMessage(role: .assistant, text: "Prepared.", actions: ActionReceipt(items: [
            .init(action: "create", outcome: "done", name: "Unterlagen.pdf", reason: "preparedFiles", operationID: card.jobID, nativeRevision: 2),
            .init(action: "calendarAdd", outcome: "done", name: "Fri, Nov 6, 09:00 – Tax advisor", operationID: UUID()),
            .init(action: "reminderAdd", outcome: "failed", name: "Not added")], cards: [.preparedFiles(card)]))
        let draftMessage = ConversationMessage(role: .assistant, text: "Draft", draft: true,
                                               mailDraft: ConversationMailDraft(subject: "Unser Termin", body: "Hallo"))
        // A task result: Pippa's notice; its attachment is the document it used, not a found file.
        let tidied = ConversationMessage(role: .assistant, text: "46 files tidied\nIn 4 folders", attachments: [input], receipt: tidy)
        let again = ConversationMessage(role: .assistant, text: "Here it is again.", attachments: [found])
        let messages = [ConversationMessage(role: .user, text: "Find my rental agreement"),
                        answer, answerText, preparedAnswer, draftMessage, tidied, again]
        let made = ConversationArtifacts(Conversation(title: "Fixture", messages: messages), exists: { $0 != gone }).made
        let kinds: [ConversationArtifacts.Made.Kind] = [.found, .result, .mailDraft, .prepared, .calendarEvent, .created]
        guard made.map(\.kind) == kinds else { return false }
        let titles: [String] = [made[1].title, made[2].title, made[4].title, made[5].title]
        let files = made[0].file == found && made[0].messageID == again.id && made[3].file == prepared && made[3].preparedCard == card
        return files && made[1].receipt == tidy && made[5].receipt == pi
            && titles == ["46 files tidied", "Unser Termin", "Fri, Nov 6, 09:00 – Tax advisor", "Notes.md"]
    }
    check("Conversation artifacts: web pages read, once per page across answers, newest first") {
        let now = Date()
        let older = WebSourcesCard(queries: ["Frist"], pagesRead: ["https://www.dwd.de/a"], searchResults: [], now: now, calendar: .current)!
        let newer = WebSourcesCard(queries: ["Frist"], pagesRead: ["https://dwd.de/a/", "https://tagesschau.de/wetter"],
                                   searchResults: ["https://ignored.example/x"], now: now, calendar: .current)!
        let searchOnly = WebSourcesCard(queries: ["x"], pagesRead: [], searchResults: ["https://a.org/1"], now: now, calendar: .current)!
        let first = ConversationMessage(role: .assistant, text: "1",
            actions: ActionReceipt(items: [.init(action: "webPage", outcome: "done", name: "dwd")], cards: [.web(older)]))
        let second = ConversationMessage(role: .assistant, text: "2",
            actions: ActionReceipt(items: [.init(action: "webSearch", outcome: "done", name: "x")], cards: [.web(searchOnly)]))
        let third = ConversationMessage(role: .assistant, text: "3",
            actions: ActionReceipt(items: [.init(action: "webPage", outcome: "done", name: "dwd")], cards: [.web(newer)]))
        let sources = ConversationArtifacts(Conversation(title: "Web", messages: [first, second, third]), exists: { _ in true }).sources
        guard sources.map(\.host) == ["dwd.de", "tagesschau.de", "a.org"] else { return false }
        return sources[0].messageID == third.id && sources[2].messageID == second.id
    }
    check("Conversation artifacts: files in use list waiting documents first and keep the selected text") {
        let a = URL(fileURLWithPath: "/fixture/a.pdf"), b = URL(fileURLWithPath: "/fixture/b.pdf")
        let context = ConversationContext(name: "2 files", files: [a, b], selectedText: "Hallo", pendingFiles: [b])
        let artifacts = ConversationArtifacts(Conversation(title: "Files", context: context), exists: { _ in true })
        let urls: [URL] = artifacts.filesInUse.map(\.url)
        let pending: [Bool] = artifacts.filesInUse.map(\.pending)
        return urls == [b, a] && pending == [true, false] && artifacts.selectedText == "Hallo" && ConversationArtifacts(nil).isEmpty
    }
    check("Conversation artifacts: a created file is found next to its answer's reveal location, or not at all") {
        let reveal = URL(fileURLWithPath: "/fixture/out/Notes.md")
        let existing: Set<String> = ["/fixture/out/Notes.md", "/fixture/out/Summary.md"]
        let exists: (URL) -> Bool = { existing.contains($0.path) }
        let paths: [String?] = ["Notes.md", "Summary.md", "Missing.md"].map { ConversationArtifacts.file(named: $0, near: reveal, exists: exists)?.path }
        let withoutReveal = ConversationArtifacts.file(named: "Notes.md", near: nil, exists: exists)
        let outside = ConversationArtifacts.file(named: "../Notes.md", near: reveal, exists: { _ in true })
        return paths == ["/fixture/out/Notes.md", "/fixture/out/Summary.md", nil] && withoutReveal == nil && outside == nil
    }
    check("Conversation store: a name chosen in the rail keeps the conversation's place, the first message's name moves it") {
        let store = try ConversationStore(directory: dir("rail-rename"))
        let a = try store.create(), b = try store.create()
        _ = try store.append(ConversationMessage(role: .user, text: "A"), to: a.id)
        _ = try store.append(ConversationMessage(role: .user, text: "B"), to: b.id)
        let before = try store.load(a.id).updatedAt
        let renamed = try store.rename(a.id, title: "  Steuer 2025  ", touch: false)
        let kept = store.list().map(\.id)
        _ = try store.rename(a.id, title: "Steuer")
        let moved = store.list().map(\.id)
        return renamed.title == "Steuer 2025" && renamed.updatedAt == before && kept == [b.id, a.id] && moved == [a.id, b.id]
    }
}
