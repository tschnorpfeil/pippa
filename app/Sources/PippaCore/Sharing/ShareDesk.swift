import Foundation

// The review's lifecycle (issue #193, P5): a review belongs to the conversation it was opened in, never to whichever one
// is selected later. Cancel, closing the sheet, switching conversations and a failed send keep the person's edits,
// parked under that conversation; nothing is sent again without a new press of Send. Pure values, so it is checked
// without a window or Pi (`PippaChecks`).

/// What the composer holds: the person's words and the attached files.
public struct ShareComposer: Sendable, Equatable {
    public var text: String
    public var files: [URL]
    public init(text: String = "", files: [URL] = []) { self.text = text; self.files = files }
    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && files.isEmpty }
}

/// One review: who receives it, the person's edited words and excerpts, and where it came from.
public struct ShareDraft: Identifiable, Sendable, Equatable {
    public let id: UUID
    /// The conversation it was opened in and its answer goes to; `nil`: a conversation not started yet.
    public var conversation: String?
    public var plan: SharePlan
    /// A single question for the recipient while conversations stay on this Mac.
    public var handoff: Bool
    /// The attached files it was made from.
    public var files: [URL]
    /// Which part was read from which attached file, so a file removed from the composer takes its part along.
    public var fileOf: [UUID: URL]
    /// What the composer held when it opened: cleared on Send only if it still holds exactly this, put back after a
    /// failure only into an empty composer. A draft typed meanwhile is never overwritten or cleared.
    public var composer: ShareComposer
    /// Reads on this Mac still running; Send waits for them.
    public var pending: Int
    public var loading: Bool { pending > 0 }
    /// Why it can't be sent, or why it was not answered last time.
    public var problem: String?

    public init(plan: SharePlan, handoff: Bool, files: [URL], conversation: String? = nil, fileOf: [UUID: URL] = [:],
                composer: ShareComposer = ShareComposer(), pending: Int = 0, problem: String? = nil, id: UUID = UUID()) {
        self.id = id; self.plan = plan; self.handoff = handoff; self.files = files; self.conversation = conversation
        self.fileOf = fileOf; self.composer = composer; self.pending = pending; self.problem = problem
    }
}

/// The open review and the parked ones, one per conversation and kind (single question or the online route).
public struct ShareDesk: Sendable, Equatable {
    public private(set) var open: ShareDraft?
    public private(set) var parked: [String: ShareDraft] = [:]

    public init() {}

    static func key(_ conversation: String?, handoff: Bool) -> String { (conversation ?? "") + (handoff ? "|handoff" : "|online") }

    /// A parked review for `conversation`, to offer "Continue checking".
    public func parked(in conversation: String?, handoff: Bool) -> ShareDraft? { parked[Self.key(conversation, handoff: handoff)] }

    /// Snapshots only.
    public mutating func present(_ draft: ShareDraft?) { open = draft }

    /// Opens the review for `conversation` and returns the files still to be read on this Mac. A parked review there is
    /// resumed with every edit: `explicit` ("Continue checking") takes it as it was; otherwise the composer counts, its
    /// new words replace the old question, a removed file takes its part along and a new file is read. Parts are offered
    /// again under the rules as they are now and named for `destination`, which may differ from the last one.
    @discardableResult
    public mutating func open(in conversation: String?, destination: ShareDestination, handoff: Bool, composer: ShareComposer,
                              fresh candidates: [SharePiece], rules: SourceSharing, explicit: Bool = false) -> [URL] {
        if let current = open { park(current) }
        let key = Self.key(conversation, handoff: handoff)
        guard let old = parked.removeValue(forKey: key) else {
            let question = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
            open = ShareDraft(plan: SharePlan(destination: destination, question: question, candidates: candidates, rules: rules),
                              handoff: handoff, files: composer.files, conversation: conversation, composer: composer,
                              pending: composer.files.isEmpty ? 0 : 1)
            return composer.files
        }
        let typed = composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let keepsQuestion = explicit || typed.isEmpty || typed == old.composer.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = explicit ? old.files : composer.files
        // A part read from a file stays only while that file is attached; one withheld before is read again (the rule may allow it now).
        let offered = old.plan.pieces.filter { piece in old.fileOf[piece.id].map(files.contains) ?? true }
        let withheld = old.plan.withheld.filter { old.fileOf[$0.id] == nil }
        let kept = Set(offered.compactMap { old.fileOf[$0.id] })
        let unread = files.filter { !kept.contains($0) }
        var plan = SharePlan(destination: destination, question: keepsQuestion ? old.plan.question : typed, candidates: offered, rules: rules)
        plan.withheld += withheld
        open = ShareDraft(plan: plan, handoff: handoff, files: files, conversation: conversation,
                          fileOf: old.fileOf.filter { files.contains($0.value) }, composer: explicit ? old.composer : composer,
                          pending: old.pending + (unread.isEmpty ? 0 : 1), problem: nil, id: old.id)
        return unread
    }

    /// The person's changes in the sheet.
    public mutating func update(_ change: (inout SharePlan) -> Void) {
        guard var current = open else { return }
        change(&current.plan)
        open = current
    }

    /// Parts read on this Mac for review `id`, open or parked meanwhile: they are never lost, and never join another one.
    /// `files`: the attached files they were read from, in order. Ends one pending read.
    public mutating func add(_ pieces: [SharePiece], files: [URL]? = nil, problem: String? = nil, to id: UUID, rules: SourceSharing) {
        func apply(_ draft: inout ShareDraft) {
            let added = SharePlan(destination: draft.plan.destination, question: draft.plan.question, candidates: pieces, rules: rules)
            draft.plan.pieces += added.pieces
            draft.plan.withheld += added.withheld
            if let files { for (piece, file) in zip(pieces, files) { draft.fileOf[piece.id] = file } }
            draft.pending = max(0, draft.pending - 1)
            if let problem { draft.problem = problem }
        }
        if var current = open, current.id == id { apply(&current); open = current; return }
        if let key = parked.first(where: { $0.value.id == id })?.key, var draft = parked[key] { apply(&draft); parked[key] = draft }
    }

    /// One more read on this Mac for the open review.
    public mutating func reading() { open?.pending += 1 }

    public mutating func setProblem(_ problem: String?) { open?.problem = problem }

    /// Cancel or closing the sheet: nothing is sent, every edit stays, parked under its conversation. When the composer
    /// still holds what the review opened with, the edited words go back into it (returned); otherwise it is left alone.
    public mutating func cancel(current conversation: String?, composer: ShareComposer) -> ShareComposer? {
        guard var draft = open else { return nil }
        open = nil
        var restored: ShareComposer?
        if draft.conversation == conversation, composer == draft.composer,
           draft.plan.question != composer.text.trimmingCharacters(in: .whitespacesAndNewlines) {
            restored = ShareComposer(text: draft.plan.question, files: composer.files)
            draft.composer = restored!
        }
        park(draft)
        return restored
    }

    /// Another conversation is shown (sidebar, Pippa Island, a new conversation): the open review stays with its own.
    public mutating func select(_ conversation: String?) {
        guard let draft = open, draft.conversation != conversation else { return }
        open = nil
        park(draft)
    }

    public enum Outcome: Equatable {
        /// Send this approval in `draft.conversation`; clear the composer only if `clearComposer`.
        case send(ShareApproval, ShareDraft, clearComposer: Bool)
        /// The review belongs to another conversation than the one shown: parked there, nothing sent.
        case parked
        /// The recipient changed while it was open: nothing sent, the review stays open and says so.
        case destinationChanged
        case nothing
    }

    /// Send: the approval is fixed now, for the destination shown and the rules as they are now.
    public mutating func approve(current conversation: String?, destination now: ShareDestination?, composer: ShareComposer,
                                 rules: SourceSharing) -> Outcome {
        guard let draft = open, !draft.loading else { return .nothing }
        guard draft.conversation == conversation else { open = nil; park(draft); return .parked }
        guard now == draft.plan.destination else { return .destinationChanged }
        guard let approval = draft.plan.approve(rules: rules) else { return .nothing }
        open = nil
        return .send(approval, draft, clearComposer: composer == draft.composer)
    }

    /// The approved review was not answered (Pi failed, the provider failed mid-answer, or it was refused before going
    /// out): parked under its conversation with `problem`, never sent again by itself. Returns what to put back into the
    /// composer: the review's own words and files, only into an empty composer of that same conversation.
    public mutating func failed(_ draft: ShareDraft, problem: String?, current conversation: String?, composer: ShareComposer) -> ShareComposer? {
        var draft = draft
        draft.problem = problem
        draft.pending = 0
        park(draft)
        guard draft.conversation == conversation, composer.isEmpty, !draft.composer.isEmpty else { return nil }
        return draft.composer
    }

    /// "Discard" on a parked review, or its conversation deleted.
    public mutating func discard(in conversation: String?, handoff: Bool) { parked[Self.key(conversation, handoff: handoff)] = nil }

    public mutating func forget(_ conversation: String) {
        parked = parked.filter { $0.value.conversation != conversation }
        if open?.conversation == conversation { open = nil }
    }

    private mutating func park(_ draft: ShareDraft) { parked[Self.key(draft.conversation, handoff: draft.handoff)] = draft }
}
