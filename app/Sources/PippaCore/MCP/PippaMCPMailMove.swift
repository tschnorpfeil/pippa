import Foundation

// `mail_move` (class undoable): inbox mails, named by `mail_ref` from this answer's `mail_search`, into an existing
// folder of the same account. A dry run moves nothing and returns counts and a `plan` id; applying takes only the plan.
// Refusals come before anything moves; the moves themselves are `MailMover` (MailMove.swift).

/// Every status of its own `mail_move` returns with nothing moved: refused before dispatch, or read back with nothing
/// moved. Each must be in the no-effect lists of PiActionReceipt.swift and pippa-assist.ts (a check reads both); the
/// shared ones (`invalid_arguments`, `cancelled`, access and Mail errors) are there already.
public enum MailMoveStatus: String, CaseIterable, Sendable {
    case planRequired = "plan_required", stalePlan = "stale_plan", staleRef = "stale_ref", crossAccount = "cross_account"
    case notInbox = "not_inbox", unknownFolder = "unknown_folder", ambiguousFolder = "ambiguous_folder"
    case targetNotAllowed = "target_not_allowed", sameFolder = "same_folder", foldersIncomplete = "folders_incomplete"
    case notMoved = "not_moved"
}

extension PippaMCPWriteTools {
    /// Most refs one call takes: the previews one answer can show (`MailPageStore.extendedRowsPerAnswer`).
    static let mailMoveRefsLimit = MailPageStore.extendedRowsPerAnswer

    func mailMove(_ input: Input) async -> PippaMCPToolResult {
        // The answer this request belongs to owns the search's references and plans; any other answer finds none.
        let (active, generation) = host.turns.capture()
        guard active == nil || active?.writes === scope else { return Self.moveRefused(.staleRef, "This mail_ref is not from a mail_search in this answer. Nothing was moved. Search again and use mail_refs from that result.") }
        guard let reader = host.mailAccounts else {
            return Self.blocked("unavailable", L("Pippa can’t move mails here.", table: "MCP"), receipt: nil)
        }
        let store = host.mailPages
        let mover = MailMover(reader: reader, settle: host.mailMoveSettle)
        if let token = input.text("plan") {
            guard input.refs == nil, input.text("to") == nil, input.dryRun == nil else { return Self.invalid("With plan, pass only plan.") }
            guard MailPageStore.isToken(token, prefix: "p") else { return Self.invalid("plan must be the plan from a mail_move dry run in this answer.") }
            guard let plan = store.takePlan(token, turn: generation) else {
                return Self.moveRefused(.stalePlan, "This plan is not from a mail_move dry run in this answer, or it was already used. Nothing was moved. Make a new dry run.")
            }
            if case .blocked(let status, let tell) = await moveAccess() {
                store.restorePlan(plan, turn: generation)
                return Self.blocked(status, tell, receipt: nil)
            }
            // The target must still be there and still be allowed.
            switch await resolveTarget(plan.target.joined(separator: "/"), account: plan.account, reader: reader) {
            case .refused(let result): return result
            case .failed(let error): store.restorePlan(plan, turn: generation); return moveFailure(error)
            case .found(let folder) where folder.path == plan.target: break
            case .found: return Self.moveRefused(.unknownFolder, "The target folder changed since the dry run. Nothing was moved. Make a new dry run.")
            }
            return await apply(plan, mover: mover, active: active, generation: generation)
        }
        guard let tokens = input.refs, !tokens.isEmpty else { return Self.invalid("refs must list mail_refs from mail_search, or pass plan from a dry run.") }
        guard tokens.count <= Self.mailMoveRefsLimit else { return Self.invalid("refs takes at most \(Self.mailMoveRefsLimit) mail_refs.") }
        guard let to = input.text("to"), to.count <= 400 else { return Self.invalid("to must be a folder path from mail_folders.") }
        let dryRun = input.dryRun ?? false
        if !dryRun && Set(tokens).count > MailMover.directLimit {
            return Self.moveRefused(.planRequired, "More than \(MailMover.directLimit) mails need a plan. Nothing was moved. Call mail_move with the same refs, to and dry_run true, then call it with only the plan it returns.")
        }
        var refs: [MailRef] = []
        for token in tokens {
            guard MailPageStore.isToken(token, prefix: "m"), let ref = store.ref(token, turn: generation) else {
                return Self.moveRefused(.staleRef, "A mail_ref is not from a mail_search in this answer. Nothing was moved. Search again and use mail_refs from that result.")
            }
            refs.append(ref)
        }
        guard let first = refs.first, refs.allSatisfy({ $0.account == first.account }) else {
            return Self.moveRefused(.crossAccount, "These mails are in more than one account. Nothing was moved. Move each account's mails in its own call; mails never move to another account.")
        }
        guard refs.allSatisfy({ $0.mailbox == .inbox && $0.path == first.path }) else {
            return Self.moveRefused(.notInbox, "Only mails from one inbox can be moved. Nothing was moved. Use mail_refs from a mail_search of the inbox.")
        }
        if case .blocked(let status, let tell) = await moveAccess() { return Self.blocked(status, tell, receipt: nil) }
        let target: MailFolderInfo
        switch await resolveTarget(to, account: first.account, reader: reader) {
        case .refused(let result): return result
        case .failed(let error): return moveFailure(error)
        case .found(let folder): target = folder
        }
        guard target.path != first.path else {
            return Self.moveRefused(.sameFolder, "These mails are already in that folder. Nothing was moved.")
        }
        guard host.turns.isLive(active, generation: generation) else { return Self.stopped(receipt: nil) }
        let plan: MailMovePlan
        do {
            plan = try await mover.plan(account: first.account, label: first.label, source: first.path, target: target.path,
                                        messageIDs: refs.map { $0.messageID }, mailIDs: refs.map(\.mailID))
        } catch {
            return moveFailure(error)
        }
        guard host.turns.isLive(active, generation: generation) else { return Self.stopped(receipt: nil) }
        if dryRun {
            var data = Self.planData(plan)
            data["moved"] = 0
            let both = Self.inBothNote(plan)
            guard !plan.entries.isEmpty else {
                return Self.response(["done": true, "dry_run": true, "dispatched": false, "data": data,
                                      "next": "Nothing to move: none of these mails can be moved (see not_found and skipped). Tell the person why." + both])
            }
            guard store.savePlan(plan, turn: generation) else { return Self.stopped(receipt: nil) }
            data["plan"] = plan.id
            return Self.response(["done": true, "dry_run": true, "dispatched": false, "data": data,
                                  "next": "Nothing moved yet. To move these \(plan.entries.count) mails into \(target.display), call mail_move with only plan." + both])
        }
        return await apply(plan, mover: mover, active: active, generation: generation)
    }

    private enum Target { case found(MailFolderInfo), refused(PippaMCPToolResult), failed(Error) }

    /// `to` among this account's folders, freshly listed: the exact path, else (no "/") the one folder with exactly this
    /// name. Names compare exactly: folders that differ only in case are different folders, and a match only in case is
    /// refused with the exact path. Never a folder at or below a role (Trash, Junk, Sent, Drafts, Outbox). Not there:
    /// another account's folder is named as such.
    private func resolveTarget(_ to: String, account: MailAccountInfo, reader: any MailAccountReading) async -> Target {
        let list: MailFolderList
        do { list = try await reader.folders(account: account.id, samples: 0) } catch { return .failed(error) }
        let folders = list.folders
        let wanted = to.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        func notAllowed(_ role: MailFolderRole) -> Target {
            .refused(Self.moveRefused(.targetNotAllowed, "Pippa does not move mails into \(role.rawValue) or a folder inside it. Nothing was moved. Choose an ordinary folder from mail_folders."))
        }
        func allowed(_ folder: MailFolderInfo) -> Bool { MailFolderRole.refused(folder, in: folders) == nil }
        if let folder = folders.first(where: { $0.display == wanted }) {
            if let role = MailFolderRole.refused(folder, in: folders) { return notAllowed(role) }
            return .found(folder)
        }
        // Mail did not list every folder in time: a folder it left out may match too, so only the exact path counts.
        if !list.allListed {
            return .refused(Self.moveRefused(.foldersIncomplete, "Mail did not list every folder of this account in time, and no listed folder has exactly this path. Nothing was moved. Pass a whole path exactly as mail_folders lists it, or try again in a moment."))
        }
        if !wanted.contains("/") {
            let named = folders.filter { $0.path.last == wanted }
            let open = named.filter(allowed)
            if named.count > 1, !open.isEmpty {
                return .refused(Self.moveRefused(.ambiguousFolder, "Several folders have this name. Nothing was moved. Pass the whole path of one of candidates, exactly as written.",
                                                 candidates: open.map(\.display)))
            }
            if let folder = named.first {
                if let role = MailFolderRole.refused(folder, in: folders) { return notAllowed(role) }
                return .found(folder)
            }
        }
        let caseOnly = folders.filter {
            allowed($0) && ($0.display.compare(wanted, options: .caseInsensitive) == .orderedSame
                || (!wanted.contains("/") && $0.path.last?.compare(wanted, options: .caseInsensitive) == .orderedSame))
        }
        if !caseOnly.isEmpty {
            return .refused(Self.moveRefused(.unknownFolder, "No folder of this account has exactly this path; folder names differ in case (see candidates). Nothing was moved. Pass the whole path exactly as written in candidates.",
                                             candidates: caseOnly.map(\.display)))
        }
        if await inOtherAccount(wanted, not: account, reader: reader) {
            return .refused(Self.moveRefused(.crossAccount, "That folder belongs to another account. Nothing was moved. Mails move only between folders of their own account."))
        }
        return .refused(Self.moveRefused(.unknownFolder, "No folder of this account has that path. Nothing was moved. Use a path from mail_folders for this account; Pippa does not create folders."))
    }

    /// Whether `wanted` names a folder of another account, as its path or as "account/path".
    private func inOtherAccount(_ wanted: String, not account: MailAccountInfo, reader: any MailAccountReading) async -> Bool {
        guard let accounts = try? await reader.inboxAccounts() else { return false }
        let labels = MailAccountFlow.labels(accounts)
        for (other, label) in zip(accounts, labels) where other.id != account.id && !other.id.isEmpty {
            guard let folders = try? await reader.folders(account: other.id, samples: 0).folders else { continue }
            for folder in folders {
                let names = [folder.display, "\(label)/\(folder.display)", "\(other.name)/\(folder.display)"]
                if names.contains(where: { $0.compare(wanted, options: .caseInsensitive) == .orderedSame }) { return true }
            }
        }
        return false
    }

    private func moveAccess() async -> Gate {
        await ensure(.mail, openMail: true, explanation: L("To do this, I need access to Mail on this Mac – I only move mails into your folders and never send anything.", table: "MCP"))
    }

    private func apply(_ plan: MailMovePlan, mover: MailMover, active: PippaMCPTurn?, generation: UUID) async -> PippaMCPToolResult {
        let lease = PippaMCPWriteLease.current
        var journal: MailMover.Journal?
        if let lease, let run = lease.turnID {
            if let executor = host.reminderJournal { journal = .init(executor: executor, run: run) }
            else if host.requiresReminderJournal {
                return Self.blocked("unavailable", L("Pippa couldn’t move the mails just now. Nothing was moved.", table: "MCP"), receipt: nil)
            }
        }
        let host = self.host, journalRows = journal
        // Its own task: once a batch's move was sent, its read-back and rows finish even if this request is cancelled,
        // and the answer's receipt waits for them (`MailMoveRuns`).
        let finished: Result<MailMoveOutcome, Error> = await host.mailMoveRuns.run(lease?.turnID) {
            do { return .success(try await mover.apply(plan, journal: journalRows, live: { host.turns.isLive(active, generation: generation) })) }
            catch { return .failure(error) }
        }
        guard case .success(let outcome) = finished else {
            return Self.blocked("unavailable", L("Pippa couldn’t move the mails just now. Nothing was moved.", table: "MCP"), receipt: nil)
        }
        return Self.moveResult(plan, outcome)
    }

    static func planData(_ plan: MailMovePlan) -> [String: Any] {
        var data: [String: Any] = ["account": plan.label, "from": shown(plan.source), "to": shown(plan.target),
                                   "moves": [shown(plan.target): plan.entries.count], "not_found": plan.notFound]
        if !plan.skipped.isEmpty { data["skipped"] = plan.skipped }
        if plan.inBoth > 0 { data["in_both"] = plan.inBoth }
        if plan.deleted > 0 { data["deleted_status"] = plan.deleted }
        return data
    }

    /// For the dry run's `next`: mails already in the target that are also still in the source.
    static func inBothNote(_ plan: MailMovePlan) -> String {
        guard plan.inBoth > 0 else { return "" }
        let from = shown(plan.source), to = shown(plan.target)
        return " \(plan.inBoth) of the mails already in \(to) are also still in \(from) (see in_both): they are in both folders. Pippa leaves them and does not delete either copy; tell the person so they can look in Mail."
    }

    /// The result from the read-back only: `verified n of m` is what Pippa found in the target folder.
    static func moveResult(_ plan: MailMovePlan, _ o: MailMoveOutcome) -> PippaMCPToolResult {
        let to = shown(plan.target), from = shown(plan.source)
        var data: [String: Any] = ["account": plan.label, "from": from, "to": to, "moved": o.verified,
                                   "verified": "\(o.verified) of \(o.attempted)", "not_moved": o.notMoved, "not_found": o.notFound]
        if !o.skipped.isEmpty { data["skipped"] = o.skipped }
        if o.notStarted > 0 { data["not_started"] = o.notStarted }
        if o.deleted > 0 { data["deleted_status"] = o.deleted }
        if o.unclear > 0 {
            data["unclear"] = o.unclear
            data["unclear_batch"] = o.unclearBatch ?? 0
            if o.notChecked > 0 {
                // Stop ended the read-back: where they are is not known yet, nothing was retried.
                data["not_checked"] = o.notChecked
                let tell = L("Pippa moved %lld mails into “%@” and checked them. She was stopped before she could check %lld more, so she can’t say yet where they are. Please check “%@” and “%@” in Mail. Pippa won’t move them again by herself.",
                             table: "MCP", o.verified, to, o.notChecked, from, to)
                return response(["done": false, "state": "unclear", "data": data, "tell": tell,
                                 "next": "Unclear: the move was stopped before \(o.notChecked) mails could be checked (see not_checked). Do not retry, repeat or undo this move, and do not move these mails again in this answer; Pippa looks once more when the answer ends. Repeat tell."])
            }
            if o.noAnswer > 0 {
                // Mail did not answer the read-back in time: where they are is not known yet, nothing was retried.
                data["no_answer"] = o.noAnswer
                let tell = L("Pippa moved %lld mails into “%@” and checked them. For %lld mails Mail did not answer in time, so Pippa can’t say yet where they are. Please check “%@” and “%@” in Mail. Pippa didn’t retry and won’t move them again by herself.",
                             table: "MCP", o.verified, to, o.noAnswer, from, to)
                return response(["done": false, "state": "unclear", "data": data, "tell": tell,
                                 "next": "Unclear: Mail did not answer in time, so where \(o.noAnswer) mails are is not known yet (see no_answer). Nothing was retried. Do not retry, repeat or undo this move, and do not move these mails again in this answer; Pippa looks once more when the answer ends. Repeat tell."])
            }
            let neither = o.unclear - o.inBoth
            var tell: String
            if neither > 0 {
                tell = L("Pippa moved %lld mails into “%@” and checked them. %lld mails are now neither in “%@” nor in “%@”. Please look for them in Mail. Pippa stopped and won’t repeat the move.",
                         table: "MCP", o.verified, to, neither, from, to)
                if o.inBoth > 0 {
                    tell += " " + L("%lld mails are in both “%@” and “%@”. Pippa doesn’t delete mails; please look at both folders in Mail.", table: "MCP", o.inBoth, from, to)
                }
            } else {
                tell = L("Pippa moved %lld mails into “%@” and checked them. %lld mails are now in both “%@” and “%@”. Pippa doesn’t delete mails; please look at both folders in Mail. Pippa stopped and won’t repeat the move.",
                         table: "MCP", o.verified, to, o.inBoth, from, to)
            }
            var next = "Unclear: do not retry, repeat or undo this move, and do not move these mails again in this answer. Repeat tell."
            if o.inBoth > 0 {
                data["in_both"] = o.inBoth
                next += " \(o.inBoth) mails are in both \(from) and \(to) (see in_both): Pippa does not delete mail, so never offer to delete or move either copy."
            }
            return response(["done": false, "state": "unclear", "data": data, "tell": tell, "next": next])
        }
        if o.verified == 0 {
            if o.stopped && o.attempted == 0 { return stopped(receipt: nil) }
            if let failure = o.failure {
                let tell = switch failure {
                case "denied": PippaMCPTools.deniedAutomation(Integration.mail.appName)
                case "not_open": L("Open %@ first. Then ask again.", table: "MCP", Integration.mail.appName)
                default: L("Pippa couldn’t move the mails just now. Nothing was moved.", table: "MCP")
                }
                return response(["done": false, "status": MailMoveStatus.notMoved.rawValue, "dispatched": false, "data": data, "tell": tell,
                                 "next": "Nothing was moved. Repeat the sentence in tell word for word."], isError: true)
            }
            return response(["done": false, "status": MailMoveStatus.notMoved.rawValue, "dispatched": false, "data": data,
                             "next": "Nothing was moved: the mails are where they were (see not_moved, not_found, skipped). Tell the person; do not retry."],
                            isError: true)
        }
        var next = "Moved \(o.verified) mails into \(to), checked in \(to) by Message-ID. Say so in one sentence with verified; the receipt under the answer has Undo."
        if o.stopped || o.failure != nil {
            next += " The move stopped early: \(o.notStarted) mails were not started and stay in \(from). Do not retry automatically."
        }
        if o.notMoved > 0 { next += " \(o.notMoved) mails stayed in \(from): Mail did not move them." }
        if o.notFound > 0 { next += " \(o.notFound) mails were no longer in \(from)." }
        if !o.skipped.isEmpty { next += " Skipped mails (see skipped) were not moved: no or repeated Message-ID, already in \(to), or (other_mail) the mail in \(from) is not the one the search found." }
        if let already = o.skipped["already_in_target"], already > 0 {
            next += " Mails already in \(to) were still in \(from) too: they are in both folders, and Pippa left them and deletes neither copy."
        }
        return response(["done": true, "dispatched": true, "complete": o.notStarted == 0, "data": data, "next": next])
    }

    static func moveRefused(_ status: MailMoveStatus, _ why: String, candidates: [String] = []) -> PippaMCPToolResult {
        var value: [String: Any] = ["done": false, "status": status.rawValue, "dispatched": false, "error": why]
        if !candidates.isEmpty { value["candidates"] = candidates.prefix(10).map { shown($0) } }
        return response(value, isError: true)
    }

    /// A folder path in a result, clipped like the other fields of mail results.
    static func shown(_ path: String) -> String { PippaMCPTools.jsonClipped(PippaMCPTools.clip(path, 160, bytes: 300), bytes: 300) }
    static func shown(_ path: [String]) -> String { shown(path.joined(separator: "/")) }

    private func moveFailure(_ error: Error) -> PippaMCPToolResult {
        switch error {
        case PippaError.accessDenied: return Self.blocked("denied", Self.denied(.mail), receipt: nil)
        case PippaError.appNotOpen: return Self.blocked("unavailable", L("Open %@ first. Then ask again.", table: "MCP", Integration.mail.appName), receipt: nil)
        case is CancellationError: return Self.stopped(receipt: nil)
        default: return Self.blocked("failed", L("Pippa couldn’t move the mails just now. Nothing was moved.", table: "MCP"), receipt: nil)
        }
    }

    static func response(_ value: [String: Any], isError: Bool = false) -> PippaMCPToolResult {
        PippaMCPToolResult(text: PippaMCPTools.json(value), isError: isError)
    }
}
