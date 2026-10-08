import Foundation

/// Habits from the task log. Pure functions over `TaskRecord` rows,
/// no model, no storage: the same rows give the same order.
public enum Habits {
    /// Until when a choice counts as "new" (double weight).
    public static let recentWindow: TimeInterval = 30 * 86_400
    /// Offered this often and never chosen, an action recedes for this kind.
    public static let fadeAfter = 5
    /// Keeping the same target this many times in a row gives "as always".
    public static let usualRun = 3
    /// At most this many actions after Give, Call or Show.
    public static let maxActions = 3

    /// Weight of a choice: undone −1, otherwise new ×2 (2), older 1.
    /// If the row comes from the same source, it counts double.
    public static func weight(of record: TaskRecord, source: String?, now: Date) -> Int {
        guard record.chosen != nil else { return 0 }
        if record.outcome == .undone { return -1 }
        var w = now.timeIntervalSince(record.at) <= recentWindow ? 2 : 1
        if let source, record.sourceLabel == source { w *= 2 }
        return w
    }

    /// Weighted count per action for this kind (and source).
    public static func scores(kind: TaskKind, source: String? = nil, in records: [TaskRecord], now: Date = Date()) -> [String: Int] {
        var scores: [String: Int] = [:]
        for r in records where r.kind == kind {
            guard let chosen = r.chosen else { continue }
            scores[chosen, default: 0] += weight(of: r, source: source, now: now)
        }
        return scores
    }

    /// Most chosen first; ties keep the order from `actions` (the type order).
    public static func order(_ actions: [String], kind: TaskKind, source: String? = nil, in records: [TaskRecord], now: Date = Date()) -> [String] {
        let s = scores(kind: kind, source: source, in: records, now: now)
        return actions.enumerated()
            .sorted { a, b in
                let (sa, sb) = (s[a.element] ?? 0, s[b.element] ?? 0)
                return sa != sb ? sa > sb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// Actions offered at least `fadeAfter` times for this kind and never chosen.
    public static func faded(kind: TaskKind, in records: [TaskRecord]) -> Set<String> {
        var offered: [String: Int] = [:]
        var chosen = Set<String>()
        for r in records where r.kind == kind {
            for a in Set(r.offered) { offered[a, default: 0] += 1 }
            if let c = r.chosen { chosen.insert(c) }
        }
        return Set(offered.filter { $0.value >= fadeAfter && !chosen.contains($0.key) }.keys)
    }

    /// What is offered: faded ones removed, ordered, at most `maxActions`.
    /// If nothing remains after hiding, the type order applies (better an offer than none).
    public static func arrange(_ actions: [String], kind: TaskKind, source: String? = nil, in records: [TaskRecord], now: Date = Date()) -> [String] {
        let hidden = faded(kind: kind, in: records)
        let visible = actions.filter { !hidden.contains($0) }
        return Array(order(visible.isEmpty ? actions : visible, kind: kind, source: source, in: records, now: now).prefix(maxActions))
    }

    /// "As always": the last `usualRun` chosen actions of this kind and source had the same action and the same
    /// named target and were all kept. Then the action carries the target ("In *Rechnungen 2026*, wie immer").
    /// Rows with "Nicht merken" don't count; `records` newest first or unordered.
    public static func asUsual(kind: TaskKind, source: String?, in records: [TaskRecord]) -> (action: String, target: TaskTarget)? {
        let recent = records
            .filter { $0.kind == kind && !$0.isPrivate && $0.sourceLabel == source && $0.chosen != nil }
            .sorted { $0.at != $1.at ? $0.at > $1.at : ($0.id ?? 0) > ($1.id ?? 0) }
            .prefix(usualRun)
        guard recent.count == usualRun, let first = recent.first, let action = first.chosen,
              let target = first.target, target.label != nil else { return nil }
        let same = recent.allSatisfy { $0.chosen == action && $0.target == target && $0.outcome == .kept }
        return same ? (action, target) : nil
    }
}
