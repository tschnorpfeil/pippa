import Foundation

// `mail_move` (class undoable): inbox mails, named by `mail_ref` from this answer's `mail_search`, into an existing
// folder of the same account. A dry run moves nothing and returns counts and a `plan` id; applying takes only the plan.
// Refusals come before anything moves; the moves themselves are `MailMover` (MailMove.swift).

extension PippaMCPWriteTools {
    /// Most refs one call takes: the previews one answer can show (`MailPageStore.extendedRowsPerAnswer`).
    static let mailMoveRefsLimit = MailPageStore.extendedRowsPerAnswer

    func mailMove(_ input: Input) async -> PippaMCPToolResult {
        // The answer this request belongs to owns the search's references and plans; any other answer finds none.
        let (active, generation) = host.turns.capture()
        guard active == nil || active?.writes === scope else { return Self.moveRefused("stale_ref", "This mail_ref is not from a mail_search in this answer. Nothing was moved. Search again and use mail_refs from that result.") }
        guard let reader = host.mailAccounts else {
            return Self.blocked("unavailable", L("Pippa can’t move mails here.", table: "MCP"), receipt: nil)
        }
        let store = host.mailPages
        let mover = MailMover(reader: reader, settle: host.mailMoveSettle)
        if let token = input.text("plan") {
            guard input.refs == nil, input.text("to") == nil, input.dryRun == nil else { return Self.invalid("With plan, pass only plan.") }
            guard MailPageStore.isToken(token, prefix: "p") else { return Self.invalid("plan must be the plan from a mail_move dry run in this answer.") }
            guard let plan = store.takePlan(token, turn: generation) else {
                return Self.moveRefused("stale_plan", "This plan is not from a mail_move dry run in this answer, or it was already used. Nothing was moved. Make a new dry run.")
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
            case .found: return Self.moveRefused("unknown_folder", "The target folder changed since the dry run. Nothing was moved. Make a new dry run.")
            }
            return await apply(plan, mover: mover, active: active, generation: generation)
        }
        guard let tokens = input.refs, !tokens.isEmpty else { return Self.invalid("refs must list mail_refs from mail_search, or pass plan from a dry run.") }
        guard tokens.count <= Self.mailMoveRefsLimit else { return Self.invalid("refs takes at most \(Self.mailMoveRefsLimit) mail_refs.") }
        guard let to = input.text("to"), to.count <= 400 else { return Self.invalid("to must be a folder path from mail_folders.") }
        let dryRun = input.dryRun ?? false
        if !dryRun && Set(tokens).count > MailMover.directLimit {
            return Self.moveRefused("plan_required", "More than \(MailMover.directLimit) mails need a plan. Nothing was moved. Call mail_move with the same refs, to and dry_run true, then call it with only the plan it returns.")
        }
        var refs: [MailRef] = []
        for token in tokens {
            guard MailPageStore.isToken(token, prefix: "m"), let ref = store.ref(token, turn: generation) else {
                return Self.moveRefused("stale_ref", "A mail_ref is not from a mail_search in this answer. Nothing was moved. Search again and use mail_refs from that result.")
            }
            refs.append(ref)
        }
        guard let first = refs.first, refs.allSatisfy({ $0.account == first.account }) else {
            return Self.moveRefused("cross_account", "These mails are in more than one account. Nothing was moved. Move each account's mails in its own call; mails never move to another account.")
        }
        guard refs.allSatisfy({ $0.mailbox == .inbox && $0.path == first.path }) else {
            return Self.moveRefused("not_inbox", "Only mails from one inbox can be moved. Nothing was moved. Use mail_refs from a mail_search of the inbox.")
        }
        if case .blocked(let status, let tell) = await moveAccess() { return Self.blocked(status, tell, receipt: nil) }
        let target: MailFolderInfo
        switch await resolveTarget(to, account: first.account, reader: reader) {
        case .refused(let result): return result
        case .failed(let error): return moveFailure(error)
        case .found(let folder): target = folder
        }
        guard target.path != first.path else {
            return Self.moveRefused("same_folder", "These mails are already in that folder. Nothing was moved.")
        }
        guard host.turns.isLive(active, generation: generation) else { return Self.stopped(receipt: nil) }
        let plan: MailMovePlan
        do {
            plan = try await mover.plan(account: first.account, label: first.label, source: first.path, target: target.path,
                                        messageIDs: refs.map { $0.messageID })
        } catch {
            return moveFailure(error)
        }
        guard host.turns.isLive(active, generation: generation) else { return Self.stopped(receipt: nil) }
        if dryRun {
            var data = Self.planData(plan)
            data["moved"] = 0
            guard !plan.entries.isEmpty else {
                return Self.response(["done": true, "dry_run": true, "dispatched": false, "data": data,
                                      "next": "Nothing to move: none of these mails can be moved (see not_found and skipped). Tell the person why."])
            }
            guard store.savePlan(plan, turn: generation) else { return Self.stopped(receipt: nil) }
            data["plan"] = plan.id
            return Self.response(["done": true, "dry_run": true, "dispatched": false, "data": data,
                                  "next": "Nothing moved yet. To move these \(plan.entries.count) mails into \(target.display), call mail_move with only plan."])
        }
        return await apply(plan, mover: mover, active: active, generation: generation)
    }

    private enum Target { case found(MailFolderInfo), refused(PippaMCPToolResult), failed(Error) }

    /// `to` among this account's folders, freshly listed: exact path, then the same path ignoring case, then a unique
    /// folder name. Not there: another account's folder is named as such. Roles (Trash, Junk, Sent, Drafts, Outbox) never.
    private func resolveTarget(_ to: String, account: MailAccountInfo, reader: any MailAccountReading) async -> Target {
        let folders: [MailFolderInfo]
        do { folders = try await reader.folders(account: account.id, samples: 0) } catch { return .failed(error) }
        let wanted = to.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        func pick(_ match: (MailFolderInfo) -> Bool) -> [MailFolderInfo] { folders.filter(match) }
        var found = pick { $0.display == wanted }
        if found.isEmpty { found = pick { $0.display.compare(wanted, options: .caseInsensitive) == .orderedSame } }
        if found.isEmpty, !wanted.contains("/") { found = pick { $0.path.last?.compare(wanted, options: .caseInsensitive) == .orderedSame } }
        if found.count > 1 {
            return .refused(Self.moveRefused("ambiguous_folder", "Several folders match to. Nothing was moved. Pass the whole path from mail_folders."))
        }
        guard let folder = found.first else {
            if await inOtherAccount(wanted, not: account, reader: reader) {
                return .refused(Self.moveRefused("cross_account", "That folder belongs to another account. Nothing was moved. Mails move only between folders of their own account."))
            }
            return .refused(Self.moveRefused("unknown_folder", "No folder of this account has that path. Nothing was moved. Use a path from mail_folders for this account; Pippa does not create folders."))
        }
        if let role = MailFolderRole.of(folder), role.refusedAsTarget {
            return .refused(Self.moveRefused("target_not_allowed", "Pippa does not move mails into \(role.rawValue). Nothing was moved. Choose an ordinary folder from mail_folders."))
        }
        return .found(folder)
    }

    /// Whether `wanted` names a folder of another account, as its path or as "account/path".
    private func inOtherAccount(_ wanted: String, not account: MailAccountInfo, reader: any MailAccountReading) async -> Bool {
        guard let accounts = try? await reader.inboxAccounts() else { return false }
        let labels = MailAccountFlow.labels(accounts)
        for (other, label) in zip(accounts, labels) where other.id != account.id && !other.id.isEmpty {
            guard let folders = try? await reader.folders(account: other.id, samples: 0) else { continue }
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
        let host = self.host
        let outcome: MailMoveOutcome
        do {
            outcome = try await mover.apply(plan, journal: journal, live: { host.turns.isLive(active, generation: generation) })
        } catch {
            return Self.blocked("unavailable", L("Pippa couldn’t move the mails just now. Nothing was moved.", table: "MCP"), receipt: nil)
        }
        return Self.moveResult(plan, outcome)
    }

    static func planData(_ plan: MailMovePlan) -> [String: Any] {
        var data: [String: Any] = ["account": plan.label, "from": plan.source.joined(separator: "/"), "to": plan.target.joined(separator: "/"),
                                   "moves": [plan.target.joined(separator: "/"): plan.entries.count], "not_found": plan.notFound]
        if !plan.skipped.isEmpty { data["skipped"] = plan.skipped }
        return data
    }

    /// The result from the read-back only: `verified n of m` is what Pippa found in the target folder.
    static func moveResult(_ plan: MailMovePlan, _ o: MailMoveOutcome) -> PippaMCPToolResult {
        let to = plan.target.joined(separator: "/"), from = plan.source.joined(separator: "/")
        var data: [String: Any] = ["account": plan.label, "from": from, "to": to, "moved": o.verified,
                                   "verified": "\(o.verified) of \(o.attempted)", "not_moved": o.notMoved, "not_found": o.notFound]
        if !o.skipped.isEmpty { data["skipped"] = o.skipped }
        if o.notStarted > 0 { data["not_started"] = o.notStarted }
        if o.unclear > 0 {
            data["unclear"] = o.unclear
            data["unclear_batch"] = o.unclearBatch ?? 0
            return response(["done": false, "state": "unclear", "data": data,
                             "tell": L("Pippa moved %lld mails into “%@” and checked them. %lld mails are now neither in “%@” nor in “%@”. Please look for them in Mail. Pippa stopped and won’t repeat the move.",
                                       table: "MCP", o.verified, to, o.unclear, from, to),
                             "next": "Unclear: do not retry, repeat or undo this move, and do not move these mails again in this answer. Repeat tell."])
        }
        if o.verified == 0 {
            if o.stopped && o.attempted == 0 { return stopped(receipt: nil) }
            if let failure = o.failure {
                let tell = switch failure {
                case "denied": PippaMCPTools.deniedAutomation(Integration.mail.appName)
                case "not_open": L("Open %@ first. Then ask again.", table: "MCP", Integration.mail.appName)
                default: L("Pippa couldn’t move the mails just now. Nothing was moved.", table: "MCP")
                }
                return response(["done": false, "status": "not_moved", "dispatched": false, "data": data, "tell": tell,
                                 "next": "Nothing was moved. Repeat the sentence in tell word for word."], isError: true)
            }
            return response(["done": false, "status": "not_moved", "dispatched": false, "data": data,
                             "next": "Nothing was moved: the mails are where they were (see not_moved, not_found, skipped). Tell the person; do not retry."],
                            isError: true)
        }
        var next = "Moved \(o.verified) mails into \(to), checked in \(to) by Message-ID. Say so in one sentence with verified; the receipt under the answer has Undo."
        if o.stopped || o.failure != nil {
            next += " The move stopped early: \(o.notStarted) mails were not started and stay in \(from). Do not retry automatically."
        }
        if o.notMoved > 0 { next += " \(o.notMoved) mails stayed in \(from): Mail did not move them." }
        if o.notFound > 0 { next += " \(o.notFound) mails were no longer in \(from)." }
        if !o.skipped.isEmpty { next += " Skipped mails (see skipped) were not moved: no or repeated Message-ID, or already in \(to)." }
        return response(["done": true, "dispatched": true, "complete": o.notStarted == 0, "data": data, "next": next])
    }

    static func moveRefused(_ status: String, _ why: String) -> PippaMCPToolResult {
        response(["done": false, "status": status, "dispatched": false, "error": why], isError: true)
    }

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
