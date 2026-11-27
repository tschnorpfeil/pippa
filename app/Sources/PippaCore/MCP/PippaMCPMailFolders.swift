import Foundation

// `mail_folders`: the folder tree per account, with counts and two sample mails per folder, read only. Sorting into
// existing folders needs them (docs/pippa-1.0.md "Tools in 1.0"). Fits `maxResultBytes` (`structuredMaxResultBytes` for
// `structuredContent`): samples go first, then folders from the end, and the result says what was left out. A mailbox
// Mail did not answer for in time (`MailFolderListing`) is listed without count or samples, and the result says so.

extension PippaMCPTools {
    static let folderSamples = 2

    func mailFolders(_ input: ToolInput) async -> PippaMCPToolResult {
        guard let reader = host.mailAccounts else {
            return Self.notRead("unsupported", "Pippa cannot list Mail folders here. Nothing was read.")
        }
        let wanted = input.account?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let wanted, !(1...200).contains(wanted.count) || wanted.utf8.count > 400 {
            return invalid("account must be an account or account_id from accounts, or omitted for all accounts.")
        }
        if case .blocked(let reply) = await ensure(.mail, openMail: true,
                                                   closed: L("Open %@ first. Then ask again.", table: "MCP", Integration.mail.appName)) {
            return reply
        }
        let live = { MailReadScope.current?.live != false && !Task.isCancelled }
        let accounts: [MailAccountInfo]
        do { accounts = try await reader.inboxAccounts() } catch { return live() ? failure(error, .mail) : Self.mailCancelled }
        guard live() else { return Self.mailCancelled }
        var scope = Array(zip(accounts, MailAccountFlow.labels(accounts)))
        if let wanted {
            let match = Self.matchAccount(wanted, scope)
            guard match.count == 1 else {
                return PippaMCPToolResult(text: Self.json([
                    "read": false, "status": match.isEmpty ? "unknown_account" : "ambiguous_account",
                    "accounts": scope.map { ["account": $0.1, "account_id": Self.clip($0.0.id, 200, bytes: Self.mailAccountIDBytes)] },
                    "error": match.isEmpty ? "No Mail account is called that. Nothing was read. Use account or account_id from accounts, or omit account."
                        : "Several Mail accounts have this name. Nothing was read. Pass its account_id from accounts.",
                ]), isError: true)
            }
            scope = match
        }
        guard !scope.isEmpty else { return Self.notRead("no_accounts", "Mail lists no account with an inbox. Nothing was read.") }
        var lists: [FolderAccount] = []
        for (account, label) in scope {
            guard live() else { lists.append((label, account.id, .cancelled, MailFolderList(folders: []))); continue }
            guard !account.id.isEmpty, account.id.utf8.count <= Self.mailAccountIDBytes else {
                lists.append((label, account.id, .failed, MailFolderList(folders: []))); continue
            }
            do {
                var list = try await reader.folders(account: account.id, samples: Self.folderSamples)
                list.folders = list.folders.filter { !$0.path.isEmpty && !$0.path.contains(where: \.isEmpty) }
                lists.append((label, account.id, .ok, list))
            } catch {
                lists.append((label, account.id, MailAccountFlow.status(error), MailFolderList(folders: [])))
            }
        }
        guard live() else { return Self.mailCancelled }
        if lists.allSatisfy({ $0.status != .ok }) {
            return PippaMCPToolResult(text: Self.json([
                "read": false, "status": "not_read",
                "accounts": lists.map { ["account": $0.label, "account_id": Self.clip($0.id, 200, bytes: Self.mailAccountIDBytes), "status": $0.status.rawValue] },
                "error": "No account's folders could be read (see accounts and status). Nothing was read. Tell the person which accounts could not be read.",
            ]), isError: true)
        }
        return Self.renderFolders(lists)
    }

    /// An account by exact id, else by its label or name (case-insensitive).
    static func matchAccount(_ wanted: String, _ scope: [(MailAccountInfo, String)]) -> [(MailAccountInfo, String)] {
        let byID = scope.filter { !$0.0.id.isEmpty && $0.0.id == wanted }
        if !byID.isEmpty { return byID }
        return scope.filter {
            $0.1.compare(wanted, options: [.caseInsensitive]) == .orderedSame
                || $0.0.name.trimmingCharacters(in: .whitespacesAndNewlines).compare(wanted, options: [.caseInsensitive]) == .orderedSame
        }
    }

    /// The largest result that fits: every folder with samples, then samples only for the first folders, then folders
    /// from the end. What was left out is counted, never silent.
    typealias FolderAccount = (label: String, id: String, status: MailAccountCoverage.Status, list: MailFolderList)

    static func renderFolders(_ accountsRead: [FolderAccount]) -> PippaMCPToolResult {
        let lists = accountsRead.map { (label: $0.label, id: $0.id, status: $0.status, folders: $0.list.folders, list: $0.list) }
        let total = lists.reduce(0) { $0 + $1.folders.count }
        func build(folders: Int, samples: Int) -> String {
            var index = 0
            var accounts: [[String: Any]] = []
            for list in lists {
                var account: [String: Any] = ["account": clip(list.label, 60, bytes: 160), "account_id": clip(list.id, 200, bytes: mailAccountIDBytes),
                                              "status": list.status.rawValue]
                var rows: [[String: Any]] = []
                for folder in list.folders {
                    defer { index += 1 }
                    guard index < folders else { continue }
                    var row: [String: Any] = ["path": jsonClipped(clip(folder.display, 160, bytes: 300), bytes: 300)]
                    if let count = folder.count { row["count"] = count }
                    if let role = MailFolderRole.of(folder) { row["role"] = role.rawValue }
                    if let gap = folder.gap { row["incomplete"] = gap.rawValue }
                    if index < samples, !folder.samples.isEmpty {
                        row["samples"] = folder.samples.prefix(folderSamples).map {
                            ["from": jsonClipped(clip($0.sender, 60, bytes: 100), bytes: 100), "subject": jsonClipped(clip($0.subject, 80, bytes: 140), bytes: 140)]
                        }
                    }
                    rows.append(row)
                }
                if list.status == .ok {
                    account["folders"] = rows
                    if list.list.unnamed > 0 { account["folders_not_listed"] = list.list.unnamed }
                    if list.list.unexpanded > 0 { account["subfolders_not_listed"] = list.list.unexpanded }
                }
                accounts.append(account)
            }
            var data: [String: Any] = ["accounts": accounts, "folders": total]
            var next = "Move mails only into a folder listed here, of the same account: pass its path as to in mail_move. Never into a folder with a role."
            let shownSamples = min(samples, folders)
            let withSamples = lists.flatMap(\.folders).prefix(folders).enumerated().filter { $0.offset < shownSamples && !$0.element.samples.isEmpty }.count
            let couldHave = lists.flatMap(\.folders).prefix(folders).filter { !$0.samples.isEmpty }.count
            if withSamples < couldHave {
                data["samples_omitted"] = couldHave - withSamples
                next += " Samples are left out for \(couldHave - withSamples) folders to fit."
            }
            if folders < total {
                data["folders_omitted"] = total - folders
                next += " \(total - folders) folders at the end are left out to fit: call mail_folders with account for one account."
            }
            let shown = lists.flatMap(\.folders).prefix(folders)
            let slow = shown.filter { $0.gap == .slow }.count, pathOnly = shown.filter { $0.gap == .pathOnly }.count
            if slow + pathOnly > 0 {
                data["folders_incomplete"] = slow + pathOnly
                var why: [String] = []
                if slow > 0 { why.append("Mail did not answer in time for \(slow) (incomplete: slow)") }
                if pathOnly > 0 { why.append("the listing ran out of time before \(pathOnly) more were counted (incomplete: path_only)") }
                next += " Counts and samples are missing for \(slow + pathOnly) folders: \(why.joined(separator: ", and ")). Never say such a folder is empty;"
                    + " tell the person their counts are unknown."
            }
            let unlisted = lists.filter { $0.status == .ok && !$0.list.allListed }
            if !unlisted.isEmpty {
                next += " Mail did not list every folder in time (see folders_not_listed and subfolders_not_listed): more folders may exist."
                    + " Never say a folder does not exist; say the list is incomplete."
            }
            let notRead = lists.filter { $0.status != .ok }
            if !notRead.isEmpty { next += " Not every account was read (see status); never say a folder is missing there." }
            return json(["read": true, "source": "Mail on this Mac (folders)", "untrusted": true, "rule": untrustedRule, "data": data, "next": next])
        }
        func largest(_ bytes: Int) -> String {
            func fits(_ text: String) -> Bool { text.utf8.count <= bytes }
            let full = build(folders: total, samples: total)
            if fits(full) { return full }
            // Largest number of folders that keep their samples, then largest number of folders without samples.
            var low = 0, high = total
            while low < high {
                let mid = (low + high + 1) / 2
                if fits(build(folders: total, samples: mid)) { low = mid } else { high = mid - 1 }
            }
            if fits(build(folders: total, samples: low)) { return build(folders: total, samples: low) }
            low = 0; high = total
            while low < high {
                let mid = (low + high + 1) / 2
                if fits(build(folders: mid, samples: 0)) { low = mid } else { high = mid - 1 }
            }
            return build(folders: low, samples: 0)
        }
        // The same cuts at the larger cap for `structuredContent` (codemode scripts).
        var result = PippaMCPToolResult(text: largest(maxResultBytes), isError: false)
        result.structured = largest(structuredMaxResultBytes)
        return result
    }
}
