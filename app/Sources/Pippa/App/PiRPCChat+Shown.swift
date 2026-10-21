import Foundation
import PiRPC
import PippaCore

/// The default, like the whole RPC path. Deliberately its own
/// file next to PiRPCChat.swift: one answer with everything the person shows.
///
/// Shown files reach Pi as metadata and bounded inline text. Final source review uses only that exact
/// pre-generation text or successful reader results, never a later host-side read. Missing evidence buffers
/// the text until review; native receipts and Undo remain owned by `chat` regardless of the text result.
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
        try Task.checkCancellation()
        let writesDraft = draftOnly || skill?.writesDraft == true
        let actionPolicy: PiActionPolicy = writesDraft ? .draftOnly : .standard
        let origin: PippaMCPOrigin?
        if let conversationID = context.nativeConversationID, let requestID = context.nativeRequestID {
            origin = .init(conversationID: conversationID, requestID: requestID)
        } else { origin = nil }
        let turn = PippaMCPTurn(onWork: context.onWork, origin: origin, allowsNativeWrites: !writesDraft)
        activeNativeTurn = turn
        if let onWrite = context.onNativeWrite { turn.writes.observeReceipts(onWrite) }
        PippaMCPTurns.shared.begin(turn)
        Self.pendingMail = nil
        // The chip's app for this answer: `front_read` reads only this one, and nothing without a chip.
        FrontAppStage.shared.current = context.frontApp
        defer {
            PippaMCPTurns.shared.end(turn)
            if activeNativeTurn === turn { activeNativeTurn = nil }
            FrontAppStage.shared.current = nil
        }
        let language = Bundle.module.preferredLocalizations.first ?? "en"
        var input = PiShownContext.Input(question: text, files: context.files, newFiles: newFiles, focused: context.focusedFiles,
                                         selectedText: context.selectedText, workflowSummary: context.workflowSummary, language: language,
                                         inlineShortText: Self.inlinesShortText)
        input.requiresFileContents = writesDraft
        let exposureToken = Self.beginSourceExposure(taskID)
        let previous = Self.sourceExposures[taskID] ?? PiSourceExposure()
        // Read metadata and bounded permitted text off the main thread. The app in front as a label
        // before it (10 to 20 tokens), once per conversation (`FrontLabelMemo`); its content when the question means
        // it (`FrontQuestion`, read below) or when Pi asks for it with `front_read`.
        let preparedInput = input
        let prepared = await Task.detached(priority: .userInitiated) { PiShownContext.prepare(preparedInput, previous: previous) }.value
        try Task.checkCancellation()
        let german = language.hasPrefix("de")
        let front = Self.frontLabels.line(for: context.frontApp, conversation: taskID, german: german)
        // "Was hältst du hiervon?" with the chip: Pippa reads what is open itself. Left to the model, K2 answered
        // "Ich kann nicht sehen, was in Safari angezeigt wird" instead of calling `front_read`. Not when the person
        // showed something else (files, selected text): then "this" means that.
        var opened: String?
        var carried: [PippaMCPReadNote] = []
        if let app = context.frontApp, context.files.isEmpty, context.selectedText.isEmpty, FrontQuestion.meansOpen(text) {
            let read = await PippaMCPService.readFront()
            carried = PippaMCPService.readNotes.take().filter { $0.turnID == turn.id }
            opened = Self.frontReadSection(read, app: app, german: german)
        }
        let nativeHistory = context.nativeReceiptSummary.isEmpty ? nil : context.nativeReceiptSummary
        let shown = [nativeHistory, front ?? (opened != nil ? context.frontApp?.label(german: german) : nil), opened, prepared.prompt]
            .compactMap { $0 }.joined(separator: "\n")
        let prompt = skill.map { PiSkillTurn.prompt(for: $0, message: shown, language: language, draftOnly: draftOnly) } ?? shown
        // Do not show an unsupported streamed answer (including Stop's partial) before reader evidence exists.
        let buffered = !PiAnswerReview.missingSources(prepared: prepared, reads: .init(), files: context.files).isEmpty
        let stream: @Sendable (String) -> Void = { if !buffered { onDelta($0) } }
        let reset: (@Sendable (String) -> Void)?
        if let onReset {
            reset = { value in if !buffered { onReset(value) } }
        } else { reset = nil }
        do {
            let answer = try await chat(prompt, taskID: taskID, onWork: context.onWork, onDelta: stream, onSteered: onSteered, onReset: reset,
                                        carriedReads: carried, turn: turn, actionPolicy: actionPolicy)
            let reads = await turn.ledger
            Self.rememberSourceExposure(prepared, reads: reads, files: context.files, taskID: taskID, token: exposureToken)
            if !prepared.requiredFiles.isEmpty { context.onWork?(.phase(.checkingSources)) }
            let missing = PiAnswerReview.missingSources(prepared: prepared, reads: reads, files: context.files)
            // Drafts still require source evidence, but numeric review annotations do not belong inside a letter.
            let review = PiAnswerReview.grounded(answer: answer, question: text, prepared: prepared, reads: reads,
                                                 files: context.files, language: language, verifyValues: !writesDraft)
            let result = review?.text ?? answer
            if buffered { onDelta(result) }
            if !writesDraft, missing.isEmpty {
                let source = MailDraftOfferRule.shownMail(files: context.files, focused: context.focusedFiles) ?? lastSelectedMail
                Self.pendingMail = (result, source)
            }
            if let review, review.changed {
                DiagnosticsLog.shared.event("quellenpruefung", ["weg": "pi-rpc", "entfernt": String(review.findings.filter(\.removes).count),
                                                               "markiert": String(review.findings.filter { !$0.removes }.count)])
            }
            return ShownAnswer(text: result, reviewed: review?.changed == true)
        } catch AnswerFailure.stopped(let partial) where buffered {
            let reads = await turn.ledger
            Self.rememberSourceExposure(prepared, reads: reads, files: context.files, taskID: taskID, token: exposureToken)
            let review = PiAnswerReview.grounded(answer: partial, question: text, prepared: prepared, reads: reads,
                                                 files: context.files, language: language, verifyValues: !writesDraft)
            // `chat` has already retained all native actions and file changes. Only its unverified text is replaced.
            throw AnswerFailure.stopped(partial: review?.text ?? partial)
        } catch PiRPCError.processExited(let status, let diagnostics) {
            // Pi ended mid-answer: without its last stderr lines the cause cannot be found afterwards (0.2.0 logged only "code 4").
            let excerpt = diagnostics.replacingOccurrences(of: Self.homePath, with: "~").trimmingCharacters(in: .whitespacesAndNewlines)
            DiagnosticsLog.shared.event("pi-beendet", ["status": String(status), "stderr": String(excerpt.suffix(600))])
            throw PiRPCError.processExited(status: status, diagnostics: diagnostics)
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
        let taken = takeActions()
        let events = (taken?.items ?? []).filter { !($0.action == "tool" && own.contains($0.name ?? "")) }
        var items = events
        // Answer text without a mail draft from code → "Noch kein Entwurf in Mail" + "Als Entwurf in Mail".
        var offer: MailDraftOffer?
        if let (answer, source) = Self.pendingMail {
            let rule = MailDraftOfferRule.evaluate(answer: answer, mailSource: source, items: items)
            if let line = rule.line { items.append(line) }
            offer = rule.offer
        }
        Self.pendingMail = nil
        return items.isEmpty ? nil : ActionReceipt(items: items, mailOffer: offer, cards: taken?.cards)
    }

    /// The `front_read` result Pippa got itself, as a block in the message. Read: the page as data. Not read (no
    /// permission, nothing open): the sentence for the person, so Pi says what to click instead of "ich sehe nichts".
    static func frontReadSection(_ read: PippaMCPToolResult, app: FrontApp, german: Bool) -> String {
        let head = read.isError
            ? (german ? "[Pippa konnte \(app.name) nicht lesen. Sag der Person in einem Satz, was zu tun ist (tell):]"
                      : "[Pippa could not read \(app.name). Tell the person in one sentence what to do (tell):]")
            : (german ? "[Was in \(app.name) offen ist, schon gelesen (front_read). Die Frage meint das:]"
                      : "[What is open in \(app.name), already read (front_read). The question means this:]")
        return head + "\n" + read.text
    }

    /// Per Pi session, not shared between conversations. Stored text is re-injected on use, so neither restart
    /// nor compaction is treated as proof that Pi retained it. File metadata changes invalidate a cached record.
    @MainActor private static var sourceExposures: [String: PiSourceExposure] = [:]
    @MainActor private static var sourceExposureOrder: [String] = []
    @MainActor private static var sourceExposureTokens: [String: UUID] = [:]

    private static func beginSourceExposure(_ taskID: String) -> UUID {
        let token = UUID()
        sourceExposureTokens[taskID] = token
        sourceExposureOrder.removeAll { $0 == taskID }; sourceExposureOrder.append(taskID)
        while sourceExposureOrder.count > 8 {
            let evicted = sourceExposureOrder.removeFirst()
            sourceExposures.removeValue(forKey: evicted); sourceExposureTokens.removeValue(forKey: evicted)
        }
        return token
    }

    static func forgetSourceExposure(_ keys: [String]) {
        for key in keys { sourceExposures.removeValue(forKey: key); sourceExposureTokens.removeValue(forKey: key) }
        sourceExposureOrder.removeAll { keys.contains($0) }
    }

    private static func rememberSourceExposure(_ prepared: PiShownContext.Prepared, reads: PiReadLedger, files: [URL], taskID: String, token: UUID) {
        guard !Task.isCancelled, sourceExposureTokens[taskID] == token else { return }
        var exposure = sourceExposures[taskID] ?? PiSourceExposure()
        exposure.remember(prepared, reads: reads, files: files)
        sourceExposures[taskID] = exposure
    }

    /// Which chip each conversation already named (`FrontLabelMemo`).
    @MainActor static var frontLabels = FrontLabelMemo()

    /// Answer and identity of the mail in question (shown .eml or `mail_selected`), of the last finished answer.
    @MainActor static var pendingMail: (answer: String, source: MailReplySource?)?

}
