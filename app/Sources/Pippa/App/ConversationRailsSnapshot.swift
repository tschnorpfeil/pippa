import AppKit
import PippaCore

#if DEBUG
/// `PIPPA_DEMO=1 PIPPA_DEMO_MODEL=missing PIPPA_SNAPSHOT_ONLY=rails`: the three-pane conversation (1180 × 760 by default,
/// narrowed by `PIPPA_SNAPSHOT_WIDTH`/`_HEIGHT` or the screen) with synthetic history and results, the rail switches,
/// the fallback to the plain conversation at 400 points and the lists the rails show. Report `rails.txt`.
@MainActor enum ConversationRailsSnapshot {
    static func run(model: AppModel, shell: ShellController, directory: URL, snapshot: (String) async -> Void) async {
        var lines: [String] = []
        func check(_ ok: Bool, _ description: String) { lines.append("\(ok ? "PASS" : "FAIL"): \(description)") }
        defer {
            let success = !lines.contains { $0.hasPrefix("FAIL:") }
            try? ((success ? "PASS" : "FAIL") + ": conversation rails\n" + lines.joined(separator: "\n") + "\n")
                .write(to: directory.appendingPathComponent("rails.txt"), atomically: true, encoding: .utf8)
        }
        func layout() -> ConversationRailLayout {
            ConversationRailLayout.resolve(width: model.conversationSize.width, rails: model.activeRails, scale: Theme.widthScale)
        }
        guard DevSnapshot.showsRails, model.engine is StubEngine, DevSnapshot.directory == directory else {
            check(false, "Requires PIPPA_SNAPSHOT_ONLY=rails and PIPPA_DEMO=1"); return
        }
        let folder = directory.appendingPathComponent("rails-files", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let letter = folder.appendingPathComponent("Tax assessment 2025.pdf")
        let receipts = folder.appendingPathComponent("Receipts 2025.pdf")
        let lease = folder.appendingPathComponent("Rental agreement.pdf")
        let packet = folder.appendingPathComponent("For the tax advisor.pdf")
        for url in [letter, receipts, lease, packet] { try? Data("Synthetic fixture for the conversation rails.\n".utf8).write(to: url) }

        model.newConversation()
        model.conversations.append(.user, "Plan a weekend in Hamburg (synthetic)")
        model.conversations.append(.assistant, "A short plan for Saturday and Sunday. (Synthetic fixture.)")
        let weekendID = model.conversations.current?.id
        model.newConversation()
        model.conversations.append(.user, "Which deadlines are in this letter? (synthetic)")
        model.conversations.append(.assistant, "One deadline: 30 November. (Synthetic fixture.)")
        let deadlinesID = model.conversations.current?.id
        model.newConversation()
        model.conversations.setContext(name: letter.lastPathComponent, files: [letter], selectedText: nil, announce: false)
        model.conversations.append(.user, "Get everything ready for my tax advisor (synthetic)", capturingAttachments: true)
        let card = PreparedFilesCard(jobID: UUID(), files: [packet], pageCount: 3, totalBytes: 48_000,
                                     sizeLimitBytes: 5_000_000, withinLimit: true, note: "Synthetic fixture")
        var cards: [ResultCard] = [.preparedFiles(card)]
        if let web = WebSourcesCard(queries: ["tax return deadline 2025"],
                                    pagesRead: ["https://www.bundesfinanzministerium.de/fristen", "https://www.elster.de/eportal/start"],
                                    searchResults: [], now: Date(), calendar: .autoupdatingCurrent) { cards.append(.web(web)) }
        let items: [ActionReceipt.Item] = [
            .init(action: "create", outcome: "done", name: packet.lastPathComponent, reason: "preparedFiles", operationID: card.jobID, nativeRevision: 2),
            .init(action: "calendarAdd", outcome: "done", name: "Fri, Nov 6, 09:00 – Tax advisor", operationID: UUID(), nativeRevision: 1),
            .init(action: "reminderAdd", outcome: "done", name: "Bring the receipts folder", operationID: UUID(), nativeRevision: 1),
            .init(action: "webPage", outcome: "done", name: "bundesfinanzministerium.de/fristen"),
        ]
        model.conversations.append(.assistant, "One PDF for your tax advisor, the appointment and a reminder. (Synthetic fixture.)",
                                   attachments: [lease], actions: ActionReceipt(items: items, cards: cards))
        let letterText = "Hello Ms. Weber,\n\nattached are the documents for my 2025 tax return.\n\nBest regards"
        model.conversations.append(.assistant, letterText, draft: true,
                                   mailDraft: ConversationMailDraft(subject: "Documents for my 2025 tax return", body: letterText))
        let draftID = model.conversations.current?.messages.last?.id
        model.conversations.setContext(name: "2 files", files: [letter, receipts], selectedText: nil, announce: false)
        guard let current = model.conversations.current?.id, let weekend = weekendID, let deadlines = deadlinesID else {
            check(false, "Fixture conversations exist"); return
        }

        // The everyday workspace starts with navigation and keeps results inline; details remain available on demand.
        model.conversationRails = ConversationRails(sessions: true, details: false)
        shell.railsChanged(minimumWidth: nil)
        await snapshot("rails-00-workspace")
        check(layout().showsSessions && !layout().showsDetails, "The everyday workspace shows navigation without the detail rail")

        // 1: both rails beside the conversation.
        model.conversationRails = .both
        shell.railsChanged(minimumWidth: nil)
        await snapshot("rails-01-three-panes")
        let scale = Theme.widthScale
        let width = model.conversationSize.width
        let wide = layout()
        let fitsBoth = width >= (ConversationRailLayout.centerMinimum + ConversationRailLayout.sessionBase + ConversationRailLayout.detailBase) * scale
        check(model.mode.isConversation, "The conversation is open")
        check(abs(shell.shellScreenRect.width - width) <= 1, "The window frame is the conversation width (\(Int(width)) pt)")
        check(width > Theme.conversationWidth + 1 && width <= ShellTokens.workspaceWideMax.width + 1, "With rails the window opens wider")
        check(fitsBoth && wide.showsSessions && wide.showsDetails, "Both rails show beside 400 points of conversation (screen has room)")
        check(wide.centerWidth >= ConversationRailLayout.centerMinimum * scale - 0.5, "The conversation keeps at least 400 points")
        let artifacts = model.conversations.artifacts
        let fileNames: [String] = artifacts.filesInUse.map(\.url.lastPathComponent)
        check(fileNames == [receipts.lastPathComponent, letter.lastPathComponent]
              && artifacts.filesInUse.first?.pending == true, "Files in Use: the waiting file first, then the one already used")
        let madeKinds: [ConversationArtifacts.Made.Kind] = artifacts.made.map(\.kind)
        check(madeKinds == [.mailDraft, .prepared, .calendarEvent, .reminder, .found],
              "Results: draft, prepared PDF, appointment, reminder and found file, newest first, each once")
        let hosts: [String] = artifacts.sources.map(\.host)
        check(hosts == ["bundesfinanzministerium.de", "elster.de"], "Sources: the two pages read")
        let sections = ConversationRailGroups.sections(model.conversations.history, current: current, now: Date(), calendar: .autoupdatingCurrent)
        let firstToday: [UUID]? = sections.first.map { section in Array(section.items.prefix(3).map(\.id)) }
        check(sections.first?.group == .today && firstToday == [current, deadlines, weekend],
              "The rail lists the conversations under Today, the open one first")

        // 2 and 3: switching off gives the room back, down to the plain conversation with its switches.
        model.toggleRail(.details)
        await snapshot("rails-02-conversations-only")
        let sessionsOnly = layout()
        check(sessionsOnly.showsSessions && !sessionsOnly.showsDetails && !model.conversationRails.details, "The details switch hides the detail rail")
        check(abs(model.conversationSize.width - min(ConversationRailLayout.preferredWidth(rails: model.activeRails, scale: scale), width)) <= 1,
              "The window gives the detail rail's room back")
        model.toggleRail(.sessions)
        await snapshot("rails-03-plain")
        let plain = layout()
        check(!plain.showsSessions && !plain.showsDetails && plain.showsToggles, "Without rails the header keeps its switches")
        check(abs(model.conversationSize.width - min(Theme.conversationWidth, width)) <= 1, "Without rails the window has the plain width")

        // 4: 400 points: the plain conversation, even with both rails wanted.
        model.conversationRails = .both
        model.conversationSize = CGSize(width: 400, height: model.conversationSize.height)
        shell.layout(animated: false, force: true)
        await snapshot("rails-04-plain-at-400")
        let compact = layout()
        check(abs(shell.shellScreenRect.width - 400) <= 1 && !compact.showsToggles && !compact.showsSessions && !compact.showsDetails,
              "At 400 points the window is the plain conversation without switches")

        // 5 and 6: working indicator, new conversation, select, rename, delete, show in conversation.
        shell.railsChanged(minimumWidth: nil)
        model.busy = true
        await snapshot("rails-05-working")
        let count = model.conversations.history.count
        model.startNewConversation()
        check(model.conversations.current?.id == current && model.conversations.history.count == count, "No new conversation while Pippa works")
        model.busy = false
        model.startNewConversation()
        let fresh = model.conversations.current?.id
        model.startNewConversation()
        check(fresh != current && model.conversations.current?.id == fresh && model.conversations.history.count == count + 1,
              "A new conversation starts once and is reused while it is still empty")
        model.selectConversation(current)
        check(model.conversations.current?.id == current, "Choosing a row opens that conversation")
        let order = model.conversations.history.map(\.id)
        model.conversations.rename(weekend, title: "Weekend in Hamburg")
        let renamedTitle = model.conversations.history.first(where: { $0.id == weekend })?.title
        check(model.conversations.history.map(\.id) == order && renamedTitle == "Weekend in Hamburg", "Renaming keeps the conversation's place")
        model.conversations.delete(deadlines)
        check(model.conversations.current?.id == current && !model.conversations.history.contains(where: { $0.id == deadlines }),
              "Deleting another conversation keeps the open one")
        if let draftID { model.showInConversation(draftID) }
        await snapshot("rails-06-after-changes")
        check(model.conversationJumpTarget == draftID, "Show in Conversation points the conversation at the draft")

        let gate = WorkspaceAnswerGate()
        let heldAnswer = SnapshotChat(script: { _, _, _, _ in try await gate.wait() }, onCancel: { await gate.stop() })
        model.conversations.send("A short synthetic question", chat: heldAnswer)
        await snapshot("rails-07-stoppable")
        check(model.conversations.isRunning, "A held answer keeps the labeled Stop control available")
        model.conversationSize = CGSize(width: 400, height: model.conversationSize.height)
        shell.layout(animated: false, force: true)
        await snapshot("rails-08-stoppable-compact")
        model.stopChat()
        for _ in 0..<20 where model.conversations.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        check(!model.conversations.isRunning, "Stop cancels the held answer in the compact workspace")
    }
}

private actor WorkspaceAnswerGate {
    private var waiter: CheckedContinuation<Void, Never>?
    private var stopped = false
    func wait() async throws -> String? {
        if !stopped { await withCheckedContinuation { waiter = $0 } }
        throw CancellationError()
    }
    func stop() {
        stopped = true
        waiter?.resume()
        waiter = nil
    }
}
#endif
