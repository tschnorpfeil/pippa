import Foundation

// `mail_search` across accounts (one snapshot per search, pages through a host-owned cursor) and `mail_read` by `mail_ref`.
// Used when the host has a per-account reader (`PippaMCPHost.mailAccounts`); otherwise the combined inbox search stays.

extension PippaMCPTools {
    /// Longest text per field of a result row: whole characters, and bytes (one character can be thousands of bytes).
    static let mailFieldLimits = (subject: (200, 400), from: (160, 240), mailbox: (80, 120), start: (400, 800))
    /// The start of each email on a page of more than `mailDenseRows` rows: a full page fits `maxResultBytes`.
    static let mailDenseStart = (160, 300)
    static let mailDenseRows = 12
    /// Up to this `limit` a page shows the start of each email; above it (up to `mailHeaderRowsLimit`) only ref, sender,
    /// subject and date, as many as fit `maxResultBytes`.
    static let mailDenseLimit = 20
    static let mailHeaderRowsLimit = 100
    /// Longest Mail account id Pippa can name exactly; a longer one is reported as not read.
    static let mailAccountIDBytes = 128

    /// The search still belongs to the running answer: `turn` is the active one and was not stopped.
    func mailTurnIsLive(_ turn: PippaMCPTurn?) -> Bool {
        !Task.isCancelled && (MailReadScope.current?.live ?? host.turns.isLive(turn))
    }

    /// After every wait for Mail: the answer is still running and still owns the store.
    private func stillOwns(_ turn: PippaMCPTurn?) -> Bool { mailTurnIsLive(turn) && host.mailPages.owns(MailReadScope.current?.owner) }

    static let mailCancelled = notRead("cancelled", "This answer was stopped or replaced while Mail was read. Nothing was read.")

    func mailSearchAccounts(_ reader: any MailAccountReading, _ input: ToolInput, query: String, readStatus: MailReadStatus, mailbox: MailBoxKind,
                            limit: Int, turn: PippaMCPTurn?) async -> PippaMCPToolResult {
        let store = host.mailPages, owner = MailReadScope.current?.owner
        guard store.claim(owner, extended: turn?.extendedBudget == true, live: { mailTurnIsLive(turn) }) else { return Self.mailCancelled }
        if let token = input.cursor {
            guard MailPageStore.isToken(token, prefix: "c") else { return invalid("cursor must be the cursor from the last mail_search result.") }
            guard let found = store.takeCursor(token, turn: owner) else {
                return Self.notRead("stale_cursor", "This cursor is not from a mail_search in this answer, was already used, or that search has ended. Nothing was read. Use the cursor from the newest result, or call mail_search again without cursor.")
            }
            let sameFilters = (input.query.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) == found.snapshot.query } ?? true)
                && ((input.unread == nil && input.readStatus == nil) || readStatus == found.snapshot.readStatus)
                && (input.mailbox == nil || mailbox == found.snapshot.mailbox)
                && (input.account.map { $0 == found.snapshot.account } ?? true)
            guard sameFilters else {
                store.restoreCursor(token, snapshot: found.snapshot.id, offset: found.offset, turn: owner)
                return invalid("cursor continues its own search: pass only cursor (and limit).")
            }
            return await page(reader, found.snapshot, offset: found.offset, limit: limit, turn: turn, from: token)
        }
        let accounts: [MailAccountInfo]
        do { accounts = try await reader.inboxAccounts() } catch { return stillOwns(turn) ? failure(error, .mail) : Self.mailCancelled }
        guard stillOwns(turn) else { return Self.mailCancelled }
        let ids = accounts.map(\.id).filter { !$0.isEmpty }
        guard Set(ids).count == ids.count else {
            return Self.notRead("duplicate_accounts", "Mail returned the same account ID more than once. No inbox was searched. Start a fresh search to retry.")
        }
        let labels = MailAccountFlow.labels(accounts)
        var scope = Array(zip(accounts, labels))
        func known() -> [[String: String]] { scope.map { ["account": $0.1, "account_id": Self.clip($0.0.id, 200, bytes: Self.mailAccountIDBytes)] } }
        if let wanted = input.account?.trimmingCharacters(in: .whitespacesAndNewlines) {
            let byID = scope.filter { !$0.0.id.isEmpty && $0.0.id == wanted }
            let byName = scope.filter {
                $0.1.compare(wanted, options: [.caseInsensitive]) == .orderedSame
                    || $0.0.name.trimmingCharacters(in: .whitespacesAndNewlines).compare(wanted, options: [.caseInsensitive]) == .orderedSame
            }
            let match = byID.isEmpty ? byName : byID
            // An unknown or unclear account never widens the search to every account.
            if match.count != 1 {
                return PippaMCPToolResult(text: Self.json([
                    "read": false, "status": match.isEmpty ? "unknown_account" : "ambiguous_account", "accounts": known(),
                    "retry": "choose_account",
                    "error": match.isEmpty ? "No Mail account is called that. Nothing was read. Use account or account_id from accounts, or omit account for all accounts."
                        : "Several Mail accounts have this name. Nothing was read. Pass its account_id from accounts.",
                ]), isError: true)
            }
            scope = match
        }
        guard !scope.isEmpty else {
            return Self.notRead("no_accounts", "Mail lists no account with an inbox. Nothing was read; do not say the inbox is empty.")
        }
        var searched = query
        var lists = await collect(reader, scope, query: query, readStatus: readStatus, mailbox: mailbox, turn: turn)
        // Mail finds parts of words, not other forms (see `mailSingular`); one retry when every account answered with nothing.
        if stillOwns(turn), lists.coverage.allSatisfy({ $0.status == .ok && $0.total == 0 }), let singular = Self.mailSingular(query) {
            let retry = await collect(reader, scope, query: singular, readStatus: readStatus, mailbox: mailbox, turn: turn)
            if retry.coverage.contains(where: { ($0.total ?? 0) > 0 }) { lists = retry; searched = singular }
        }
        guard stillOwns(turn), let window = store.available(turn: owner) else { return Self.mailCancelled }
        // No account answered: nothing was read, never a successful empty search.
        if lists.coverage.allSatisfy({ $0.status != .ok }) {
            let accounts: [[String: String]] = lists.coverage.map {
                ["account": $0.label, "account_id": Self.clip($0.account.id, 200, bytes: Self.mailAccountIDBytes), "status": $0.status.rawValue]
            }
            return PippaMCPToolResult(text: Self.json([
                "read": false, "status": "not_read", "accounts": accounts, "retry": "fresh_search",
                "error": "No account's inbox could be read (see accounts and status). Nothing was read. Tell the person which accounts could not be read; never say an inbox is empty.",
            ]), isError: true)
        }
        let order = MailAccountFlow.order(lists.lists, page: min(limit, window), window: window)
        let snapshot = MailSnapshot(id: MailPageStore.token("s"), query: searched, readStatus: readStatus, mailbox: mailbox, account: input.account,
                                    entries: order.entries, coverage: lists.coverage, balanced: order.balanced)
        guard stillOwns(turn), store.save(snapshot, turn: owner) else { return Self.mailCancelled }
        return await page(reader, snapshot, offset: 0, limit: limit, turn: turn, from: nil)
    }

    /// Each account's matches, one account after the other. A failing account is reported with its reason, never as empty;
    /// once the answer is stopped or replaced, Mail is not asked again and the remaining accounts are `cancelled`.
    private func collect(_ reader: any MailAccountReading, _ scope: [(MailAccountInfo, String)], query: String, readStatus: MailReadStatus,
                         mailbox: MailBoxKind, turn: PippaMCPTurn?) async
        -> (lists: [(account: MailAccountInfo, label: String, candidates: [MailSearchCandidate])], coverage: [MailAccountCoverage]) {
        var lists: [(account: MailAccountInfo, label: String, candidates: [MailSearchCandidate])] = []
        var coverage: [MailAccountCoverage] = []
        for (account, label) in scope {
            guard !Task.isCancelled, stillOwns(turn) else { coverage.append(MailAccountCoverage(account: account, label: label, status: .cancelled)); continue }
            guard !account.id.isEmpty, account.id.utf8.count <= Self.mailAccountIDBytes else {
                coverage.append(MailAccountCoverage(account: account, label: label, status: .failed)); continue
            }
            do {
                let found = try await reader.candidates(account: account.id, query: query, readStatus: readStatus, mailbox: mailbox)
                guard Set(found.map(\.id)).count == found.count else {
                    coverage.append(MailAccountCoverage(account: account, label: label, status: .duplicate_candidates))
                    continue
                }
                lists.append((account, label, found))
                coverage.append(MailAccountCoverage(account: account, label: label, status: .ok, total: found.count))
            } catch {
                coverage.append(MailAccountCoverage(account: account, label: label, status: MailAccountFlow.status(error)))
            }
        }
        return (lists, coverage)
    }

    /// Only delivered previews consume the reservation. Failed accounts stay failed for the search,
    /// and the cursor advances over their entries so other accounts can still be read.
    private func page(_ reader: any MailAccountReading, _ snapshot: MailSnapshot, offset: Int, limit: Int, turn: PippaMCPTurn?, from cursorToken: String?) async -> PippaMCPToolResult {
        let store = host.mailPages, owner = MailReadScope.current?.owner
        func giveBack(_ held: Int) {
            store.release(held, turn: owner)
            if let cursorToken { store.restoreCursor(cursorToken, snapshot: snapshot.id, offset: offset, turn: owner) }
        }
        // Keyed by the whole account, not its id: Mail can list several accounts without an id, and one must never stand in
        // for another.
        let failed = Set(snapshot.coverage.filter { $0.status != .ok }.map(\.account))
        let remaining = snapshot.entries.dropFirst(offset)
        let wanted = remaining.lazy.filter { !failed.contains($0.account) }.prefix(limit).count
        guard let hold = store.reserve(wanted, turn: owner) else { return Self.mailCancelled }
        if hold.granted == 0 && wanted > 0 {
            giveBack(0)
            guard hold.exhausted else {
                return Self.notRead("budget_busy", "Other Mail pages are using the available preview slots. Retry this cursor after they finish, or start a fresh search if there is no cursor.")
            }
            let shown = store.rowLimit(turn: owner)
            let which = snapshot.balanced ? "the newest of each account" : "the newest \(shown)"
            return Self.notRead("budget_reached", "This answer already showed \(shown) email previews. Nothing more was read. Stop searching: work with the mails already found and tell the person you looked at \(which), not all.")
        }
        var available = hold.granted
        let slice = remaining.prefix { entry in
            if failed.contains(entry.account) { return true }
            guard available > 0 else { return false }
            available -= 1
            return true
        }
        var rows: [MailAccountInfo: [Int: MailSearchRow]] = [:]
        var pageProblems: [MailAccountInfo: MailAccountCoverage.Status] = [:]
        let eligible = slice.filter { !failed.contains($0.account) }
        for account in Self.unique(eligible.map(\.account)) {
            guard stillOwns(turn) else { giveBack(hold.granted); return Self.mailCancelled }
            do {
                let ids = eligible.filter { $0.account == account }.map(\.id)
                var result: [MailSearchRow] = []
                if limit > Self.mailDenseLimit {
                    // Header-only pages read headers only, a dense page's rows per Apple Event: 100 rows never share one timeout.
                    for start in stride(from: 0, to: ids.count, by: Self.mailDenseLimit) {
                        guard stillOwns(turn) else { giveBack(hold.granted); return Self.mailCancelled }
                        result += try await reader.rows(account: account.id, ids: Array(ids[start..<min(start + Self.mailDenseLimit, ids.count)]),
                                                        mailbox: snapshot.mailbox, headerOnly: true)
                    }
                } else {
                    result = try await reader.rows(account: account.id, ids: ids, mailbox: snapshot.mailbox)
                }
                guard Set(result.map(\.id)).count == result.count else {
                    pageProblems[account] = .duplicate_candidates
                    continue
                }
                rows[account] = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
            } catch {
                pageProblems[account] = MailAccountFlow.status(error)
            }
        }
        guard stillOwns(turn) else { giveBack(hold.granted); return Self.mailCancelled }
        let resolved = slice.map { entry -> (entry: MailPageEntry, row: MailSearchRow?, skipped: Bool) in
            let skipped = failed.contains(entry.account) || pageProblems[entry.account] != nil
            let row = rows[entry.account]?[entry.id]
            // An account, date or read status that no longer matches the snapshot cannot identify this message.
            let same = row.flatMap { r in
                MailAccountFlow.sameDate(r.date, entry.date) && (r.accountID ?? entry.account.id) == entry.account.id
                    && snapshot.readStatus.matches(unread: r.header.unread) ? r : nil
            }
            return (entry, same, skipped)
        }

        // Fit the result: shrink variable fields while keeping each row's identity and a start of its text; drop entries
        // from the end only if even compact headers cannot fit. The cursor continues right after the last entry shown.
        let tokens = resolved.map { $0.row == nil ? "" : MailPageStore.token("m") }
        let refs = Dictionary(uniqueKeysWithValues: zip(tokens, resolved).compactMap { token, item -> (String, MailRef)? in
            guard let row = item.row, row.accountID == item.entry.account.id, let path = row.path, !path.isEmpty, !path.contains(where: \.isEmpty),
                  let messageID = row.header.messageID.flatMap(MailReplySource.canonicalMessageID) else { return nil }
            return (token, MailRef(account: item.entry.account, label: item.entry.label, mailID: item.entry.id, messageID: messageID,
                                   date: item.entry.date, path: path, mailbox: snapshot.mailbox))
        })
        let nextToken = MailPageStore.token("c")
        func sized(_ count: Int) -> (text: String, headers: [MailHeader], notRead: [String], gone: Int, isError: Bool) {
            func build(_ caps: MailRowCaps) -> (text: String, headers: [MailHeader], notRead: [String], gone: Int, isError: Bool) {
                render(snapshot, offset: offset, resolved: resolved, tokens: tokens, refs: refs, count: count, pageProblems: pageProblems,
                       left: hold.left + hold.granted - resolved.prefix(count).filter { $0.row != nil }.count,
                       cursor: offset + count < snapshot.entries.count ? nextToken : nil, caps: caps)
            }
            // Header-only rows keep fixed caps; the loop below drops rows from the end until the page fits.
            if limit > Self.mailDenseLimit {
                return build(MailRowCaps(subject: (120, 200), from: (80, 120), mailbox: (0, 0), account: (40, 80), start: (0, 0), accountsBytes: 900, headerOnly: true))
            }
            let rows = resolved.prefix(count).filter { $0.row != nil }.count
            let initialStart = rows > Self.mailDenseRows ? Self.mailDenseStart : Self.mailFieldLimits.start
            let full = MailRowCaps(subject: Self.mailFieldLimits.subject, from: Self.mailFieldLimits.from,
                                   mailbox: Self.mailFieldLimits.mailbox, account: (60, 160), start: initialStart, accountsBytes: 2200)
            let built = build(full)
            guard built.text.utf8.count > Self.maxResultBytes, rows > 0 else { return built }
            var headerOnly = full; headerOnly.start = (0, 0)
            let bare = build(headerOnly)
            let share = (Self.maxResultBytes - bare.text.utf8.count - 64) / rows
            if share >= 16 {
                var shared = full; shared.start = (min(share, Self.mailDenseStart.0), min(share, Self.mailDenseStart.1))
                let candidate = build(shared)
                if candidate.text.utf8.count <= Self.maxResultBytes { return candidate }
            }
            // Variable headers are too wide for a full page: reserve identity and a non-empty text start per row, then
            // clip subject, sender, mailbox and account label to share what remains.
            var fixedCaps = MailRowCaps(subject: (0, 0), from: (0, 0), mailbox: (20, 24), account: (32, 48), start: (0, 0), accountsBytes: 900)
            var fixed = build(fixedCaps)
            if Self.maxResultBytes - fixed.text.utf8.count - 64 < rows * 36 {
                fixedCaps = MailRowCaps(subject: (0, 0), from: (0, 0), mailbox: (12, 16), account: (18, 24), start: (0, 0), accountsBytes: 500)
                fixed = build(fixedCaps)
            }
            func packed(_ perRow: Int) -> (text: String, headers: [MailHeader], notRead: [String], gone: Int, isError: Bool) {
                let startBytes = min(Self.mailDenseStart.1, max(12, perRow * 24 / 100))
                let fromBytes = min(Self.mailFieldLimits.from.1, max(12, perRow * 30 / 100))
                let subjectBytes = min(Self.mailFieldLimits.subject.1, max(12, perRow - startBytes - fromBytes))
                var caps = fixedCaps
                caps.subject = (min(Self.mailFieldLimits.subject.0, subjectBytes), subjectBytes)
                caps.from = (min(Self.mailFieldLimits.from.0, fromBytes), fromBytes)
                caps.start = (min(Self.mailDenseStart.0, startBytes), startBytes)
                return build(caps)
            }
            let perRow = (Self.maxResultBytes - fixed.text.utf8.count - 64) / rows
            guard perRow >= 36 else { return share >= 8 ? build({ var c = full; c.start = (min(share, Self.mailDenseStart.0), min(share, Self.mailDenseStart.1)); return c }()) : bare }
            let candidate = packed(perRow)
            guard candidate.text.utf8.count > Self.maxResultBytes else { return candidate }
            let trim = (candidate.text.utf8.count - Self.maxResultBytes + rows - 1) / rows + 4
            return perRow - trim >= 36 ? packed(perRow - trim) : fixed
        }
        var count = resolved.count
        var built = sized(count)
        while built.text.utf8.count > Self.maxResultBytes, count > 0 {
            count = resolved.prefix(count).lastIndex { $0.row != nil } ?? 0
            built = sized(count)
        }
        guard built.text.utf8.count <= Self.maxResultBytes, count > 0 || resolved.isEmpty else {
            giveBack(hold.granted)
            return Self.notRead("too_large", "Mail's next email is too large to show here. Nothing more was read. Search one account with account, or a narrower query.")
        }
        // `structuredContent` (codemode scripts) keeps every row of the page, with the full field limits, up to
        // `structuredMaxResultBytes`; it ends at or after the text and has its own cursor, paired with the text's.
        let structuredToken = MailPageStore.token("c")
        func large(_ rows: Int) -> (text: String, headers: [MailHeader], notRead: [String], gone: Int, isError: Bool) {
            let caps = limit > Self.mailDenseLimit
                ? MailRowCaps(subject: Self.mailFieldLimits.subject, from: Self.mailFieldLimits.from, mailbox: (0, 0), account: (60, 160), start: (0, 0),
                              accountsBytes: 16_000, headerOnly: true)
                : MailRowCaps(subject: Self.mailFieldLimits.subject, from: Self.mailFieldLimits.from, mailbox: Self.mailFieldLimits.mailbox,
                              account: (60, 160), start: Self.mailFieldLimits.start, accountsBytes: 16_000)
            return render(snapshot, offset: offset, resolved: resolved, tokens: tokens, refs: refs, count: rows, pageProblems: pageProblems,
                          left: hold.left + hold.granted - resolved.prefix(rows).filter { $0.row != nil }.count,
                          cursor: offset + rows < snapshot.entries.count ? (rows == count ? nextToken : structuredToken) : nil, caps: caps)
        }
        var structuredCount = resolved.count
        var structured = large(structuredCount)
        while structured.text.utf8.count > Self.structuredMaxResultBytes, structuredCount > count {
            structuredCount = max(count, resolved.prefix(structuredCount).lastIndex { $0.row != nil } ?? 0)
            structured = large(structuredCount)
        }
        if structured.text.utf8.count > Self.structuredMaxResultBytes { structuredCount = count; structured = built }

        let delivered = Array(zip(tokens, resolved).prefix(count))
        let end = offset + count
        let rowsShown = delivered.filter { $0.1.row != nil }.count
        let structuredRows = resolved.prefix(structuredCount).filter { $0.row != nil }.count
        let shownRefs = refs.filter { token, _ in zip(tokens, resolved).prefix(structuredCount).contains { $0.0 == token && $0.1.row != nil } }
        let structuredEnd = offset + structuredCount
        let structuredCursor = structuredCount > count && structuredEnd < snapshot.entries.count
            ? (token: structuredToken, offset: structuredEnd, owed: structuredRows - rowsShown, gone: structured.gone - built.gone) : nil
        guard stillOwns(turn) else { giveBack(hold.granted); return Self.mailCancelled }
        guard store.settle(snapshot: snapshot.id, held: hold.granted, rows: rowsShown, refs: shownRefs, gone: built.gone, problems: pageProblems,
                           cursor: end < snapshot.entries.count ? (nextToken, end) : nil, structured: structuredCursor,
                           turn: owner, live: { mailTurnIsLive(turn) }) else { giveBack(hold.granted); return Self.mailCancelled }
        var result = PippaMCPToolResult(text: built.text, isError: built.isError)
        result.structured = structured.text
        if !built.headers.isEmpty {
            result.card = .mail(MailCard(query: snapshot.query, unread: snapshot.readStatus == .unread, mails: built.headers, total: snapshot.entries.count, calendar: host.calendar,
                                         first: offset + 1, last: end, notRead: built.notRead))
        }
        return result
    }

    private struct MailRowCaps {
        var subject: (Int, Int)
        var from: (Int, Int)
        var mailbox: (Int, Int)
        var account: (Int, Int)
        var start: (Int, Int)
        var accountsBytes: Int
        /// ref, sender, subject and date (and the account when the search covers several).
        var headerOnly = false
    }

    private func render(_ snapshot: MailSnapshot, offset: Int, resolved: [(entry: MailPageEntry, row: MailSearchRow?, skipped: Bool)], tokens: [String],
                        refs: [String: MailRef], count: Int, pageProblems: [MailAccountInfo: MailAccountCoverage.Status], left: Int, cursor: String?,
                        caps: MailRowCaps) -> (text: String, headers: [MailHeader], notRead: [String], gone: Int, isError: Bool) {
        func field(_ value: String, _ limit: (Int, Int)) -> String {
            guard limit.0 > 0, limit.1 > 0 else { return "" }
            return Self.jsonClipped(Self.clip(value, limit.0, bytes: limit.1), bytes: limit.1)
        }
        var mails: [[String: Any]] = []
        var headers: [MailHeader] = []
        var gone = 0, unopenable = 0, skipped = 0
        for (index, item) in resolved.prefix(count).enumerated() {
            guard let row = item.row else {
                if item.skipped { skipped += 1 } else { gone += 1 }
                continue
            }
            var m = row.header
            m.account = item.entry.label
            var value: [String: Any] = ["subject": field(m.subject, caps.subject),
                                        "from": field(m.sender, caps.from),
                                        "mailbox": field(m.mailbox, caps.mailbox),
                                        "start": field(Self.compact(m.preview), caps.start),
                                        "unread": m.unread, "replied": m.replied, "forwarded": m.forwarded, "flagged": m.flagged,
                                        "account": field(item.entry.label, caps.account)]
            if caps.headerOnly {
                value = ["subject": field(m.subject, caps.subject), "from": field(m.sender, caps.from)]
                if snapshot.coverage.count > 1 { value["account"] = field(item.entry.label, caps.account) }
            }
            if refs[tokens[index]] != nil { value["mail_ref"] = tokens[index] } else { unopenable += 1 }
            m.messageID = nil
            m.subject = value["subject"] as? String ?? ""
            m.sender = value["from"] as? String ?? ""
            m.preview = value["start"] as? String ?? ""
            if let date = m.date { value["date"] = Self.dateLabel(date, time: true, calendar: host.calendar) }
            mails.append(value)
            headers.append(m)
        }
        let shownRows = mails.count
        let end = offset + count
        let goneTotal = snapshot.gone + gone
        var coverage = snapshot.coverage
        for i in coverage.indices { if let problem = pageProblems[coverage[i].account] { coverage[i].status = problem } }
        let notRead = coverage.filter { $0.status != .ok }
        let accounts: [[String: Any]] = coverage.map { c in
            var a: [String: Any] = ["account": c.label, "account_id": Self.clip(c.account.id, 200, bytes: Self.mailAccountIDBytes), "status": c.status.rawValue]
            if let total = c.total { a["total"] = total }
            return a
        }
        let more = end < snapshot.entries.count
        var data: [String: Any] = ["query": snapshot.query, "unread": snapshot.readStatus == .unread, "read_status": snapshot.readStatus.rawValue,
                                   "mailbox": snapshot.mailbox.rawValue, "mails": mails, "shown": shownRows,
                                   "total": snapshot.entries.count, "first": offset + 1, "truncated": more,
                                   "complete": notRead.isEmpty && !more && goneTotal == 0, "status": notRead.isEmpty ? "ok" : "partial",
                                   "accounts": accounts, "preview_rows_left": max(0, left),
                                   "order": snapshot.balanced ? "newest_per_account" : "newest", "read_depth": caps.headerOnly ? "header_only" : "header_and_start"]
        Self.trimMailList("accounts", in: &data, bytes: caps.accountsBytes)
        if skipped > 0 { data["skipped"] = skipped }
        if !notRead.isEmpty { data["retry"] = "fresh_search" }
        if let account = snapshot.account { data["account"] = Self.clip(account, 200, bytes: 400) }
        if let cursor { data["cursor"] = cursor }
        if gone > 0 { data["gone"] = gone }
        if goneTotal > 0 { data["gone_total"] = goneTotal }
        var next = caps.headerOnly
            ? "If mails is not empty, the person sees them as a card under your answer: do not list them again. You see only sender, subject and date: for the whole email call mail_read with its mail_ref; to sort, pass mail_refs to mail_move."
            : "If mails is not empty, the person sees them as a card under your answer: do not list them again; answer in one or two sentences. Each mail names its account. You see only the header and the start of each email: for the whole email call mail_read with its mail_ref."
        if snapshot.balanced {
            next += " Mails are mixed so each account shows up: they are the newest of each account, not the newest overall; say so."
        }
        if unopenable > 0 { next += " A mail without mail_ref cannot be opened by Pippa: Mail did not say exactly where it is." }
        if more {
            next += cursor != nil && left > 0
                ? " More matching mails remain (total counts all of them): for the next ones call mail_search with only cursor; never guess other search words for them."
                : " More matching mails remain. Preview slots are currently unavailable; use the results shown or retry the cursor after other Mail calls finish."
        }
        if data["accountsOmitted"] != nil { next += " The accounts list is shortened; accountsOmitted counts the omitted entries." }
        if !notRead.isEmpty {
            next += " " + Self.partialSentence
            next += " This cursor skips accounts whose previews failed. Start a fresh search without cursor to retry them."
        } else if mails.isEmpty && goneTotal == 0 && offset == 0 {
            next += " No email in the \(Self.boxWord(snapshot.mailbox)) of the searched accounts matches."
        }
        if goneTotal > 0 { next += " \(goneTotal) mails changed or left the \(Self.boxWord(snapshot.mailbox)) since this search began; they are not shown, so this search is not complete." }
        if offset == 0, snapshot.query.isEmpty, snapshot.mailbox == .inbox, !Self.mailTriageHint.isEmpty { next += " " + Self.mailTriageHint }
        let nothingRead = mails.isEmpty && gone == 0 && skipped > 0
        let source = snapshot.account == nil ? "Mail on this Mac (\(Self.boxWord(snapshot.mailbox)) of all accounts)" : "Mail on this Mac (\(Self.boxWord(snapshot.mailbox)) of one account)"
        var envelope: [String: Any] = ["read": !nothingRead, "source": source,
                              "untrusted": true,
                              "rule": Self.untrustedRule,
                              "data": data, "next": next]
        if nothingRead {
            envelope["status"] = "account_unavailable"
            envelope["retry"] = cursor == nil ? "fresh_search" : "continue_cursor"
            envelope["error"] = "Mail did not return the requested previews for \(notRead.prefix(3).map(\.label).joined(separator: ", ")). Continue with cursor if present, or start a fresh search to retry failed accounts."
        }
        let notices = notRead.prefix(20).map { "\($0.label) (\(Self.statusWord($0.status)))" }
        return (Self.json(envelope), headers, notices + (notRead.count > notices.count ? ["…"] : []), gone, nothingRead)
    }

    /// The searched container in the model's words.
    static func boxWord(_ kind: MailBoxKind) -> String {
        switch kind {
        case .inbox: "inbox"
        case .sent: "sent mailbox"
        case .drafts: "drafts mailbox"
        }
    }

    /// Why an account is missing from the card, in the app language.
    static func statusWord(_ status: MailAccountCoverage.Status) -> String {
        switch status {
        case .ok: ""
        case .timeout: L("Mail account timed out", table: "MCP")
        case .denied: L("no access", table: "MCP")
        case .failed, .duplicate_candidates: L("couldn’t be read", table: "MCP")
        case .cancelled: L("stopped", table: "MCP")
        }
    }

    // MARK: mail_read by mail_ref

    func mailReadRef(_ token: String, turn: PippaMCPTurn?) async -> PippaMCPToolResult {
        guard MailPageStore.isToken(token, prefix: "m") else { return invalid("mail_ref must be the mail_ref from mail_search.") }
        // Never another mail with a similar subject: an unknown or old reference reads nothing.
        guard let reader = host.mailAccounts, mailTurnIsLive(turn), let ref = host.mailPages.ref(token, turn: MailReadScope.current?.owner) else {
            return Self.notRead("stale_ref", "This mail_ref is not from a mail_search in this answer. Nothing was read. Search again and use a mail_ref from that result.")
        }
        if case .blocked(let reply) = await ensure(.mail, openMail: true,
                                                   closed: L("Open %@ first. Then ask again.", table: "MCP", Integration.mail.appName)) {
            return reply
        }
        guard mailTurnIsLive(turn) else { return Self.mailCancelled }
        do {
            guard let found = try await Self.resolve(ref, reader: reader) else {
                guard mailTurnIsLive(turn) else { return Self.mailCancelled }
                return Self.notRead("stale", "This email changed or left the \(Self.boxWord(ref.mailbox)) of \(ref.label) since the search. Nothing was read; do not use another email instead.")
            }
            guard mailTurnIsLive(turn) else { return Self.mailCancelled }
            var extra: [String: Any] = [:]
            if ref.mailbox == .inbox {
                // Sent and Drafts of the same account, with their own short timeout: a failure there leaves the mail intact.
                let activity: MailThreadActivity?
                do {
                    activity = try await reader.threadActivity(account: ref.account.id, messageID: ref.messageID, subject: found.message.subject, since: ref.date)
                } catch {
                    activity = nil
                    extra["thread_activity_complete"] = false
                }
                guard mailTurnIsLive(turn) else { return Self.mailCancelled }
                if let activity {
                    extra["thread_checked"] = activity.isComplete
                    if !activity.isComplete { extra["thread_activity_complete"] = false }
                    if activity.sentReply { extra["sent_replied"] = true }
                    else if activity.sentComplete { extra["sent_replied"] = false }
                    if activity.draft { extra["has_draft"] = true }
                    else if activity.draftsComplete { extra["has_draft"] = false }
                } else {
                    extra["thread_checked"] = false
                    extra["thread_activity_complete"] = false
                }
            }
            let origin = MailFiling.FiledOrigin(
                mailbox: ref.mailbox,
                locator: MailLocator(account: ref.account.name, path: ref.path, mailID: ref.mailID, accountID: ref.account.id, strict: true),
                requiresStrictLocator: true
            )
            return mailResult(found.message, source: "Mail on this Mac (email from the \(Self.boxWord(ref.mailbox)) of one account)", account: ref.label,
                              filingScope: [ref.account.id, String(ref.mailID)] + ref.path, origin: origin, extra: extra)
        } catch {
            return mailTurnIsLive(turn) ? failure(error, .mail) : Self.mailCancelled
        }
    }

    /// The message a reference names, only when the whole locator still matches: account id, every mailbox in the path,
    /// Mail id, Message-ID and date. `nil`: it changed or is gone.
    static func resolve(_ ref: MailRef, reader: any MailAccountReading) async throws -> MailInboxMessage? {
        let message = try await reader.message(account: ref.account.id, mailID: ref.mailID, messageID: ref.messageID, path: ref.path, mailbox: ref.mailbox)
        guard let found = message, found.accountID == ref.account.id, found.path == ref.path,
              found.message.messageID.flatMap(MailReplySource.canonicalMessageID) == ref.messageID,
              MailAccountFlow.sameDate(found.message.date, ref.date) else { return nil }
        return found
    }

    /// Nothing was read, with the reason for the model (no sentence for the person: these are the model's own mistakes or Mail's state).
    static func notRead(_ status: String, _ why: String) -> PippaMCPToolResult {
        PippaMCPToolResult(text: json(["read": false, "status": status, "error": why]), isError: true)
    }

    /// At most `limit` characters and `bytes` UTF-8 bytes, cut at a whole character and marked with "…". Control
    /// characters become spaces, so JSON escaping cannot grow the text. A single character larger than the limit is left out.
    public static func clip(_ text: String, _ limit: Int, bytes: Int = .max) -> String {
        let clean = String(String.UnicodeScalarView(text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
        return byteClipped(clean, characters: limit, bytes: bytes)
    }

    private static func unique(_ accounts: [MailAccountInfo]) -> [MailAccountInfo] {
        var seen = Set<MailAccountInfo>()
        return accounts.filter { seen.insert($0).inserted }
    }

    /// How to sort the inbox when the person asks for it (runtime/pippa-skills/posteingang-sichten); comes with a search for the newest mails.
    public static let mailTriageHint: String = PippaSkill.instructions(named: "posteingang-sichten") ?? ""
}
