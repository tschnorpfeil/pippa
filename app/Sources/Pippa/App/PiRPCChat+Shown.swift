import Foundation
import PiRPC
import PippaCore

/// The default, like the whole RPC path. Deliberately its own
/// file next to PiRPCChat.swift: one answer with everything the person shows.
///
/// 1. **Shown items** (files, folders, tray, selected mail as .eml, Excel selection as .tsv, scans, text) appear as a
///    short description with path and tool in the message (`PiShownContext`); Pi reads them itself, PDFs, scans and
///    images via Pippa's `read_document` (PippaMCPTurn.swift).
/// 2. **Source check** as in the old path: after the stream ends, Pippa reads the same files with its own
///    reader and checks the answer with `SourceFidelity`. Pages Pi already read via
///    `read_document` come from the text-recognition cache. For every file Pi read in the answer,
///    exactly this text applies (`PiReadLedger`), otherwise Pippa's own read state.
/// 3. **Look up online**: Pi's `web_search`/`fetch_content` (pi-web-access) run without a card; what went out appears
///    as a receipt line below (PiTurnReceipt, from the tool arguments).
extension PiRPCChat {
    /// What ConversationController needs from an answer: text (checked) and receipt (events).
    struct ShownAnswer {
        var text: String
        /// The check removed or marked something.
        var reviewed: Bool
    }

    /// Like `chat`, with this message's shown items. `newFiles`: newly shown in this message.
    /// `skill` (button) puts the bundled instructions before the message (`PiSkillTurn`); `draftOnly`: the text
    /// lands in Pippa's own line (letter draft), Pi should create nothing.
    func answer(_ text: String, taskID: String, context: ChatContext, newFiles: [URL], skill: PippaSkill? = nil, draftOnly: Bool = false,
                onDelta: @escaping @Sendable (String) -> Void, onSteered: @escaping @Sendable (String) -> Void,
                onReset: (@Sendable (String) -> Void)? = nil) async throws -> ShownAnswer {
        let turn = PippaMCPTurn(onWork: context.onWork)
        PippaMCPTurns.shared.begin(turn)
        Self.pendingMail = nil
        defer { PippaMCPTurns.shared.end(turn) }
        let language = Bundle.module.preferredLocalizations.first ?? "en"
        let input = PiShownContext.Input(question: text, files: context.files, newFiles: newFiles, focused: context.focusedFiles,
                                         selectedText: context.selectedText, workflowSummary: context.workflowSummary, language: language,
                                         inlineShortText: Self.inlinesShortText)
        // Read metadata (and, if the setting is on, short texts): off the main thread.
        let shown = await Task.detached(priority: .userInitiated) { PiShownContext.prompt(input) }.value
        let prompt = skill.map { PiSkillTurn.prompt(for: $0, message: shown, language: language, draftOnly: draftOnly) } ?? shown
        do {
            let answer = try await chat(prompt, taskID: taskID, onWork: context.onWork, onDelta: onDelta, onSteered: onSteered, onReset: onReset)
            // Drafts (button "Antwort schreiben", letter line) have their own insert path: no second offer,
            // and as in the old path no source check in the draft text ("bitte prüfen" does not belong in a letter).
            let writesDraft = draftOnly || skill?.writesDraft == true
            if !writesDraft {
                // Shown mail (file) or read selected mail → check the offer (takeShownActions).
                let source = MailDraftOfferRule.shownMail(files: context.files, focused: context.focusedFiles) ?? lastSelectedMail
                Self.pendingMail = (answer, source)
            }
            guard !writesDraft, !context.files.isEmpty else { return ShownAnswer(text: answer, reviewed: false) }
            context.onWork?(.phase(.checkingSources))
            // Only now read: what Pi read via read_document is in the session cache of text recognition, and
            // Pi's own reading did not have to compete with a second text recognition of the same pages.
            var quiet = context
            quiet.onWork = nil
            let snapshots = await Task.detached(priority: .userInitiated) { (try? await LocalEngine.snapshots(for: quiet)) ?? [] }.value
            // Check against what Pi actually read in this answer (read_document, read), not against
            // Pippa's shortened read state.
            let reads = await turn.ledger
            guard let review = PiAnswerReview.review(answer: answer, question: text, snapshots: snapshots, fileCount: context.files.count,
                                                     reads: reads, files: context.files), review.changed else {
                return ShownAnswer(text: answer, reviewed: false)
            }
            DiagnosticsLog.shared.event("quellenpruefung", ["weg": "pi-rpc", "entfernt": String(review.findings.filter(\.removes).count),
                                                           "markiert": String(review.findings.filter { !$0.removes }.count)])
            return ShownAnswer(text: review.text, reviewed: true)
        }
    }

    /// Setting "send short texts along" (`PippaSettings.piInlineShortText`, default on).
    /// `PIPPA_INLINE_SHORT_TEXT=1|0` only for measurement runs.
    static var inlinesShortText: Bool {
        if let forced = DevEnvironment.value("PIPPA_INLINE_SHORT_TEXT") { return forced == "1" }
        let support = DevEnvironment.value("PIPPA_PI_HOME").map {
            URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("Library/Application Support/Pippa", isDirectory: true)
        } ?? Pippa.supportDirectory
        return PippaSettings.load(from: support).inlinesShortText
    }

    /// Receipt of the last answer, once. Pippa's own read tool does not appear as "Benutzt: mcp__pippa__…": what it
    /// did is told by the read receipt.
    func takeShownActions() -> ActionReceipt? {
        let own = Set(PippaMCPTurnTools.names.map { "mcp__\(PippaMCPTools.serverName)__" + $0 })
        let events = (takeActions()?.items ?? []).filter { !($0.action == "tool" && own.contains($0.name ?? "")) }
        var items = events
        // Answer text without a mail draft from code → "Noch kein Entwurf in Mail" + "Als Entwurf in Mail".
        var offer: MailDraftOffer?
        if let (answer, source) = Self.pendingMail {
            let rule = MailDraftOfferRule.evaluate(answer: answer, mailSource: source, items: items)
            if let line = rule.line { items.append(line) }
            offer = rule.offer
        }
        Self.pendingMail = nil
        return items.isEmpty ? nil : ActionReceipt(items: items, mailOffer: offer)
    }

    /// Answer and identity of the mail in question (shown .eml or `mail_selected`), of the last finished answer.
    @MainActor static var pendingMail: (answer: String, source: MailReplySource?)?

}
