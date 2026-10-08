import PippaCore
import SwiftUI

// Sheets (organizing and table).

// MARK: - 6 Ordnen

struct SortSheet: View {
    @Environment(\.embeddedWorkflow) private var embedded
    @ObservedObject var model: AppModel
    /// Row with keyboard focus: the space bar toggles it on or off.
    @FocusState private var focusedRow: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Row: Identifiable {
        var id: UUID
        var op: PlanOp
        var new: String
        /// Old name, only if the step renames the file.
        var old: String?
        /// The file as it lies now (for the thumbnail).
        var source: URL?
        var reason: String
        var unsure: Bool
    }

    struct Group: Identifiable {
        var id: String { key }
        var key: String
        var subs: [String]
        var rows: [Row]
        var isNew: Bool
        /// Identical copies that go to the Trash (with undo); always shown last.
        var isTrash = false
    }

    struct Stay: Identifiable {
        var id: String
        var name: String
        var why: String
        var url: URL?
    }

    private func analyze(_ plan: Plan) -> (groups: [Group], stay: [Stay]) {
        let scope = plan.scope.standardizedFileURL.path
        func components(_ url: URL) -> [String] {
            let p = url.deletingLastPathComponent().standardizedFileURL.path
            guard p.hasPrefix(scope) else { return [url.deletingLastPathComponent().lastPathComponent] }
            return p.dropFirst(scope.count).split(separator: "/").map(String.init)
        }
        let made = Set(plan.ops.filter { $0.kind == .mkdir }.compactMap { components($0.target.appendingPathComponent("x")).first })
        var order: [String] = []
        var byKey: [String: Group] = [:]
        var stay: [Stay] = []
        var trash = Group(key: T("Move to Trash · duplicates", table: "Views"), subs: [], rows: [], isNew: false, isTrash: true)
        for op in plan.ops where op.kind != .mkdir {
            if op.kind == .trash, op.certainty != .unreadable {
                trash.rows.append(Row(id: op.id, op: op, new: op.target.lastPathComponent, old: nil, source: op.source, reason: op.reason, unsure: false))
                continue
            }
            if op.certainty == .unreadable {
                stay.append(Stay(id: op.id.uuidString, name: op.source?.lastPathComponent ?? op.target.lastPathComponent, why: op.reason, url: op.source))
                continue
            }
            let comps = components(op.target)
            let key = comps.first ?? T("Here", table: "Views")
            let sub = comps.dropFirst().joined(separator: "/")
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = Group(key: key, subs: [], rows: [], isNew: made.contains(key))
            }
            if !sub.isEmpty, !(byKey[key]!.subs.contains(sub)) { byKey[key]!.subs.append(sub) }
            byKey[key]!.rows.append(Row(id: op.id, op: op, new: op.target.lastPathComponent, old: op.previousName,
                                        source: op.source, reason: op.reason, unsure: op.certainty == .unsure))
        }
        stay += plan.skipped.enumerated().map { Stay(id: "skip-\($0.offset)", name: $0.element.url.lastPathComponent, why: $0.element.why, url: $0.element.url) }
        let groups = (order.compactMap { byKey[$0] } + (trash.rows.isEmpty ? [] : [trash])).map { g -> Group in
            var g = g
            g.rows.sort { $0.new.localizedStandardCompare($1.new) == .orderedAscending }
            return g
        }
        return (groups, stay)
    }

    var body: some View {
        if let plan = model.plan {
            let (groups, stay) = analyze(plan)
            let all = groups.flatMap(\.rows)
            let chosen = all.filter { !model.excluded.contains($0.id) }.count
            let newFolders = groups.filter(\.isNew).count
            VStack(spacing: 0) {
                PanelHead(title: T("Organize %@", table: "Views", plan.scope.lastPathComponent),
                          meta: T("%lld files get a place · %lld new folders · nothing is deleted", table: "Views", chosen, newFolders),
                          markSize: 36, sheet: true, onClose: { model.escape() })
                AdaptiveScroll {
                    VStack(spacing: 0) {
                        BeforeAfter(total: all.count + stay.count + plan.pending.count + plan.later.count, groups: groups.filter { !$0.isTrash })
                            .padding(.horizontal, 20)
                            .padding(.top, 14)
                            .stagger(4)
                        if !plan.pending.isEmpty || !plan.remaining.isEmpty || !plan.later.isEmpty { comingNext(plan, placed: all.count + stay.count + plan.later.count) }
                        // While files are still being looked at, the count would only grow under the person's eyes.
                        if all.count > 1 && !model.sortFilling { selectionBar(chosen: chosen, all: all) }
                        VStack(spacing: 0) {
                            ForEach(Array(groups.enumerated()), id: \.element.id) { index, g in
                                groupView(g, index: index)
                                // "Stays where it is" right after the open group: visible at first glance.
                                if index == 0 && !stay.isEmpty { stayBox(stay) }
                                if index < groups.count - 1 { Theme.hair.frame(height: 0.5) }
                            }
                            if groups.isEmpty && !stay.isEmpty { stayBox(stay) }
                        }
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                    }
                }
                if !embedded {
                    SortActions(model: model)
                    TrustSill(left: T("Only moved and renamed · nothing deleted", table: "Views"), leftIcon: "lock")
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            Color.clear
        }
    }

    /// What is still to come, in plain words: one progress line while Pippa is still looking at files (the groups fill in
    /// meanwhile, organizing waits until every file has its place), documents for later, and the rest of a very full folder.
    private func comingNext(_ plan: Plan, placed: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !plan.pending.isEmpty {
                let total = placed + plan.pending.count
                VStack(alignment: .leading, spacing: 6) {
                    Text(T("Looking at %lld files… %lld of %lld", table: "Views", total, placed, total))
                        .monospacedDigit()
                    ProgressView(value: Double(placed), total: Double(max(total, 1)))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                        .tint(Theme.accent)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: placed)
                }
            }
            if !plan.later.isEmpty && plan.pending.isEmpty {
                Text(laterText(plan.later.count))
            }
            if !plan.remaining.isEmpty {
                Text(T("This folder is very full. I’m starting with the newest %lld files; the other %lld come afterward.", table: "Views",
                       placed + plan.pending.count, plan.remaining.count))
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(Theme.ink3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
    }

    /// Documents for later: how many, when, and that they stay where they are until then.
    private func laterText(_ count: Int) -> String {
        let what = AppModel.laterCount(count)
        if count == 1 {
            return T("I’ll take a calm look at %@ later, %@. Until then, it stays where it is.", table: "Views", what, model.laterPhrase)
        }
        return T("I’ll take a calm look at %@ later, %@. Until then, they stay where they are.", table: "Views", what, model.laterPhrase)
    }

    /// "All" / "None" for the whole preview; single rows are toggled by their checkbox (or the space bar).
    private func selectionBar(chosen: Int, all: [Row]) -> some View {
        HStack(spacing: 14) {
            Text(T("%lld of %lld selected", table: "Views", chosen, all.count))
                .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.ink3)
            Spacer(minLength: 6)
            LinkButton(title: T("All", table: "Views"), icon: nil) { model.excluded.subtract(all.map(\.id)) }
                .disabled(chosen == all.count)
                .accessibilityLabel(T("Select All Files", table: "Views"))
            LinkButton(title: T("None", table: "Views"), icon: nil) { model.excluded.formUnion(all.map(\.id)) }
                .disabled(chosen == 0)
                .accessibilityLabel(T("Select No Files", table: "Views"))
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
    }

    private func toggle(_ row: Row) {
        if model.excluded.contains(row.id) { model.excluded.remove(row.id) } else { model.excluded.insert(row.id) }
    }

    private func isOpen(_ g: Group, index: Int) -> Bool { model.openGroups.contains(g.key) != (index == 0) }

    @ViewBuilder
    private func groupView(_ g: Group, index: Int) -> some View {
        let included = g.rows.filter { !model.excluded.contains($0.id) }.count
        let open = isOpen(g, index: index)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                CheckBox(state: included == g.rows.count ? .on : included == 0 ? .off : .mixed) {
                    let ids = g.rows.map(\.id)
                    if included == g.rows.count { model.excluded.formUnion(ids) } else { model.excluded.subtract(ids) }
                }
                .accessibilityLabel(T("All in %@", table: "Views", g.key))
                if g.isTrash {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .frame(width: 26)
                        .accessibilityHidden(true)
                } else {
                    FolderArt(width: 26)
                }
                (Text(g.key).foregroundStyle(Theme.ink)
                 + Text(g.subs.isEmpty ? "" : "  › " + g.subs.sorted().joined(separator: ", ")).foregroundStyle(Theme.ink3).fontWeight(.medium))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                if g.isNew {
                    Text(T("NEW", table: "Views"))
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.2)
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.accentTint))
                }
                Spacer(minLength: 6)
                Text(included == g.rows.count ? "\(g.rows.count)" : T("%lld of %lld", table: "Views", included, g.rows.count))
                    .font(.system(size: 12.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.ink3)
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.ink3)
                    .frame(width: 14)
            }
            .padding(.horizontal, 22)
            .frame(height: 48)
            .contentShape(Rectangle())
            .onTapGesture {
                if model.openGroups.contains(g.key) { model.openGroups.remove(g.key) } else { model.openGroups.insert(g.key) }
            }
            .stagger(5 + index)
            if open {
                let full = model.fullGroups.contains(g.key)
                let shown = full ? g.rows : Array(g.rows.prefix(4))
                ForEach(shown) { row in fileRow(row) }
                if g.rows.count > shown.count {
                    HStack {
                        LinkButton(title: T("and %lld more following the same pattern", table: "Views", g.rows.count - shown.count), icon: nil) { model.fullGroups.insert(g.key) }
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
                        Spacer()
                    }
                    .padding(.leading, 80)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func fileRow(_ row: Row) -> some View {
        let on = !model.excluded.contains(row.id)
        return HStack(alignment: .center, spacing: 12) {
            CheckBox(state: on ? .on : .off) { toggle(row) }
            .accessibilityLabel(T("Include %@", table: "Views", row.new))
            FileThumbnail(url: row.source ?? row.op.target, width: 20).opacity(on ? 1 : 0.38)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // The full name with extension: "Bild.png", not "Bild" (several files may differ only there).
                    Text(row.new)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .strikethrough(!on, color: Theme.fill3)
                        .lineLimit(1).truncationMode(.middle)
                    if row.unsure { Chip(text: T("unsure", table: "Views"), kind: .need) }
                }
                // Copies for the Trash always say which file stays.
                if model.showReasons || row.unsure || row.op.kind == .trash {
                    Text(row.reason)
                        .font(.system(size: 11.5))
                        .foregroundStyle(row.unsure ? Theme.need : Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let old = row.old {
                    Text(T("was: %@", table: "Views", old))
                        .font(Fonts.mono(11.5))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .opacity(on ? 1 : 0.38)
            Spacer(minLength: 0)
        }
        .padding(.leading, 51)
        .padding(.trailing, 22)
        .padding(.vertical, 5)
        .frame(minHeight: 46)
        .animation(.easeOut(duration: 0.25), value: on)
        .help(row.reason)
        .focusable()
        .focused($focusedRow, equals: row.id)
        .onKeyPress(.space) { toggle(row); return .handled }
        .accessibilityElement(children: .combine)
        .accessibilityAction { toggle(row) }
    }

    private func stayBox(_ stay: [Stay]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Circle().fill(Theme.needDot).frame(width: 7, height: 7)
                Text(T("Stays where it is", table: "Views")).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Text("\(stay.count)").font(.system(size: 12.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, 22)
            .frame(height: 40)
            ForEach(stay) { s in
                HStack(spacing: 12) {
                    FileThumbnail(url: s.url, width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                        Text(s.why).font(.system(size: 11.5)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 5)
                .frame(minHeight: 46)
            }
        }
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.needTint))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

/// Vorher (Zettelhaufen) → Nachher (Ordner).
struct BeforeAfter: View {
    var total: Int
    var groups: [SortSheet.Group]

    var body: some View {
        Well(padding: 0) {
            ViewThatFits(in: .horizontal) {
                wideLayout.frame(minWidth: 530)
                compactLayout
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(T("%lld files go into %lld folders", table: "Views", total, groups.count))
    }

    private var wideLayout: some View {
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        SheetArt().frame(width: 34, height: 44).rotationEffect(.degrees(-14)).offset(x: 6, y: 12)
                        PhotoArt(variant: 1).frame(width: 32, height: 38).rotationEffect(.degrees(9)).offset(x: 34, y: 4)
                        EnvelopeArt().frame(width: 48, height: 32).rotationEffect(.degrees(-5)).offset(x: 56, y: 28)
                        SheetArt().frame(width: 30, height: 40).rotationEffect(.degrees(16)).offset(x: 92, y: 8)
                        PhotoArt(variant: 0).frame(width: 28, height: 32).rotationEffect(.degrees(-4)).offset(x: 20, y: 34)
                    }
                    .frame(width: 130, height: 70, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(T("Now", table: "Views")).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text(T("%lld loose files", table: "Views", total)).font(.system(size: 12.5)).foregroundStyle(Theme.ink3)
                    }
                    .padding(.top, 8)
                }
                .frame(width: 150, alignment: .leading)
                Image(systemName: "arrow.right").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.ink3).frame(width: 40)
                HStack(alignment: .top, spacing: 10) {
                    ForEach(groups.prefix(4)) { g in
                        VStack(spacing: 4) {
                            FolderArt()
                            Text(g.key).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink).multilineTextAlignment(.center).lineLimit(2)
                            Text(detail(g)).font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(T("%lld loose files → %lld folders", table: "Views", total, groups.count), systemImage: "folder")
                .font(Fonts.body).foregroundStyle(Theme.ink2)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                ForEach(groups.prefix(4)) { group in
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.key).font(Fonts.head).fixedSize(horizontal: false, vertical: true)
                            Text(detail(group)).font(Fonts.hint).foregroundStyle(Theme.ink3)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }.padding(16)
    }

    private func detail(_ g: SortSheet.Group) -> String {
        let years = g.subs.allSatisfy { $0.count == 4 && Int($0) != nil }
        if !g.subs.isEmpty && years { return T("%lld · by year", table: "Views", g.rows.count) }
        return "\(g.rows.count)"
    }
}

// MARK: - 7 Tabelle

struct InvoiceSheet: View {
    @Environment(\.embeddedWorkflow) private var embedded
    @ObservedObject var model: AppModel

    static let money: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.numberStyle = .currency
        return f
    }()

    static func amount(_ value: Decimal?, currency: String = "EUR") -> String {
        guard let a = value else { return "–" }
        let f = money
        f.currencyCode = currency
        return f.string(from: a as NSDecimalNumber) ?? "\(a) \(currency)"
    }

    static func amount(_ row: InvoiceRow) -> String { amount(row.amount, currency: row.currency) }

    private let visible = 6

    var body: some View {
        let rows = model.invoices.sorted { Self.dateKey($0.date) < Self.dateKey($1.date) }
        let unsure = rows.filter { $0.certainty != .sure }
        let withAmount = rows.filter { $0.amount != nil }.count
        let sum = rows.compactMap(\.amount).reduce(Decimal(0), +)
        let sumUnsure = !unsure.isEmpty || withAmount < rows.count
        let folder = model.context?.folder?.lastPathComponent ?? "Downloads"
        let n = Self.count(rows.count)
        VStack(spacing: 0) {
            PanelHead(title: T("Invoices from %@", table: "Views", model.context?.name ?? folder),
                      meta: Self.meta(count: n, unsure: unsure.count),
                      markSize: 36, sheet: true, onClose: { model.escape() })
            AdaptiveScroll {
                VStack(alignment: .leading, spacing: 0) {
                    ResultTitle(text: headline(sum: sum, unsure: !unsure.isEmpty, withAmount: withAmount, total: rows.count))
                    Well(padding: 14) {
                        Spreadsheet(rows: rows, visible: visible, sum: sum, sumUnsure: sumUnsure,
                                    fileName: "Rechnungen.\(model.exportFormat.rawValue)", folder: folder)
                    }
                    .padding(.top, 16)
                    .stagger(4)
                    if let first = unsure.first {
                        HStack(alignment: .top, spacing: 12) {
                            Circle().fill(Theme.needDot).frame(width: 7, height: 7).padding(.top, 6)
                            VStack(alignment: .leading, spacing: 8) {
                                (Text(T("Needs you: ", table: "Views")).fontWeight(.semibold).foregroundStyle(Theme.need)
                                 + Text(needText(first, more: unsure.count - 1)).foregroundStyle(Theme.ink))
                                    .font(.system(size: 13))
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                                SourceChip(name: first.source.lastPathComponent, location: nil, url: first.source) {
                                    model.openSource(Answer(text: "", source: first.source, location: nil, quote: first.evidence, found: true))
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.needTint))
                        .padding(.top, 12)
                        .stagger(6)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)
            }
            if !embedded {
                InvoiceActions(model: model)
                TrustSill(left: T("A new file; your invoices stay untouched", table: "Views"))
            }
        }
        .frame(maxWidth: .infinity)
    }

    static func count(_ n: Int) -> String { n == 1 ? T("1 invoice", table: "Views") : T("%lld invoices", table: "Views", n) }

    /// Header line: "6 Rechnungen", with uncertain ones "6 Rechnungen · 2 brauchen dich".
    static func meta(count: String, unsure: Int) -> String {
        if unsure == 0 { return count }
        if unsure == 1 { return T("%@ · %lld needs you", table: "Views", count, unsure) }
        return T("%@ · %lld need you", table: "Views", count, unsure)
    }

    /// DD.MM.YYYY -> sortable; without a date, to the end.
    static func dateKey(_ d: String?) -> String {
        guard let d, d.count == 10 else { return "9999" }
        let p = d.split(separator: ".")
        return p.count == 3 ? "\(p[2])\(p[1])\(p[0])" : "9999"
    }

    /// "About 801.91 EUR in 6 Rechnungen", "... in 5 of 6 Rechnungen".
    private func headline(sum: Decimal, unsure: Bool, withAmount: Int, total: Int) -> String {
        let amount = Self.amount(sum)
        let tail = withAmount < total ? T("in %lld of %@", table: "Views", withAmount, Self.count(total)) : T("in %@", table: "Views", Self.count(total))
        if unsure { return T("About %@ %@", table: "Views", amount, tail) }
        return amount + " " + tail
    }

    private func needText(_ row: InvoiceRow, more: Int) -> String {
        var s = "\(row.sender ?? FileName.display(row.source.lastPathComponent)): "
        if row.amount != nil {
            s += T("I’m not sure about %@. Please take a quick look.", table: "Views", Self.amount(row))
        } else {
            s += T("I can’t read the amount clearly. Please take a quick look.", table: "Views")
        }
        if more > 0 { s += " " + T("Plus %lld more.", table: "Views", more) }
        return s
    }
}

/// Spreadsheet on paper: column letters, row numbers, tabs.
struct Spreadsheet: View {
    var rows: [InvoiceRow]
    var visible: Int
    var sum: Decimal
    var sumUnsure = false
    var fileName: String
    var folder: String

    private let widths: [CGFloat] = [30, 104, 0, 124, 120, 112]   // 0 = remainder

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullTable.frame(minWidth: 580, idealWidth: 580, maxWidth: .infinity)
            compactTable
        }
    }

    private var compactTable: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(fileName).font(Fonts.head).padding(12)
            ForEach(rows.prefix(visible)) { row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.sender ?? T("Unknown sender", table: "Views"))
                            .font(Fonts.body).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Text(InvoiceSheet.amount(row)).font(Fonts.body).monospacedDigit().fixedSize()
                            .foregroundStyle(row.certainty == .sure ? Theme.paperInk : Theme.need)
                    }
                    Text(row.date ?? T("Date unknown", table: "Views")).font(Fonts.hint).foregroundStyle(Theme.ink3)
                    Link(destination: row.source) {
                        Label(row.source.lastPathComponent, systemImage: "doc")
                            .font(Fonts.hint).lineLimit(2).multilineTextAlignment(.leading)
                    }.help(row.evidence.map { T("Source: “%@”", table: "Views", $0) } ?? row.source.lastPathComponent)
                    if row.certainty != .sure {
                        Label(T("Please Check", table: "Views"), systemImage: "exclamationmark.circle").font(Fonts.hint).foregroundStyle(Theme.need)
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(row.certainty == .sure ? Color.clear : Theme.needTint)
                .overlay(alignment: .top) { Theme.hair.frame(height: 0.5) }
            }
            if rows.count > visible {
                Text(T("and %lld more rows", table: "Views", rows.count - visible)).font(Fonts.hint).foregroundStyle(Theme.ink3).padding(12)
            }
            HStack {
                Text(T("Total", table: "Views"))
                Spacer(minLength: 0)
                Text(InvoiceSheet.amount(sum) + (sumUnsure ? " ?" : "")).monospacedDigit()
            }.font(Fonts.head).padding(12)
                .foregroundStyle(sumUnsure ? Theme.need : Theme.paperInk)
                .overlay(alignment: .top) { Theme.hair.frame(height: 0.5) }
        }.frame(maxWidth: .infinity, alignment: .leading).paper()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(T("Spreadsheet Preview", table: "Views"))
    }

    private var fullTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "tablecells").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ok)
                Text(fileName).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.paperInk)
                Spacer()
                Text(T("new, in %@", table: "Views", folder)).font(.system(size: 12.5)).foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .overlay(alignment: .bottom) { Theme.hair.frame(height: 0.5) }
            line(["", "A", "B", "C", "D", "E"], header: true)
            // Header line, check note and sheet name show the file's content: same texts as InvoiceExport (table "Analysis").
            line(["1"] + InvoiceExport.previewHeaders, bold: true)
            ForEach(Array(rows.prefix(visible).enumerated()), id: \.element.id) { i, r in
                let unsure = r.certainty != .sure
                line(["\(i + 2)", r.date ?? "–", r.sender ?? "–", InvoiceSheet.amount(r) + (unsure ? " ?" : ""), FileName.display(r.source.lastPathComponent),
                      InvoiceExport.check(r)], need: unsure)
                    .help(r.evidence.map { T("Source: “%@”", table: "Views", $0) } ?? "")
            }
            if rows.count > visible {
                HStack(spacing: 0) {
                    cellRN("⋮")
                    Text(T("and %lld more rows", table: "Views", rows.count - visible)).italic().foregroundStyle(Theme.ink3).padding(.leading, 10)
                    Spacer()
                }
                .frame(height: 24)
                .overlay(alignment: .bottom) { Theme.hair.frame(height: 0.5) }
            }
            line(["\(min(rows.count, visible) + 2 + (rows.count > visible ? 1 : 0))", totalLabel, "", InvoiceSheet.amount(sum) + (sumUnsure ? " ?" : ""), "", ""],
                 bold: true, sum: true, sumNeed: sumUnsure)
            HStack(spacing: 2) {
                // Name of the sheet in the file (InvoiceExport.sheetName).
                Text(InvoiceExport.sheetName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.paperInk)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6).fill(Theme.paper))
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 26, alignment: .top)
            .background(Theme.paper2)
            .overlay(alignment: .top) { Theme.hair.frame(height: 0.5) }
        }
        .font(.system(size: 12.5).monospacedDigit())
        .foregroundStyle(Theme.paperInk)
        .paper()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(T("Spreadsheet Preview", table: "Views"))
    }

    /// A line of its own keeps the expression in `line([...])` small for the type checker.
    private var totalLabel: String { T("Total", table: "Views") }

    private func cellRN(_ t: String) -> some View {
        Text(t).font(.system(size: 10.5)).foregroundStyle(Theme.ink3)
            .frame(width: 30).frame(maxHeight: .infinity).background(Theme.paper2)
            .overlay(alignment: .trailing) { Theme.hair.frame(width: 0.5) }
    }

    private func line(_ cells: [String], header: Bool = false, bold: Bool = false, need: Bool = false, sum: Bool = false, sumNeed: Bool = false) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<cells.count, id: \.self) { i in
                let w = widths[i]
                let numeric = i == 3
                Group {
                    if i == 0 {
                        cellRN(cells[i])
                    } else {
                        Text(cells[i])
                            .font(header ? .system(size: 10.5, weight: .medium) : .system(size: 12.5, weight: bold || (need && numeric) ? .bold : .regular).monospacedDigit())
                            .foregroundStyle(header ? Theme.ink3 : (need && (numeric || i == 5)) || (sumNeed && numeric) ? Theme.need : (i == 4 ? Theme.ink3 : Theme.paperInk))
                            .lineLimit(1).truncationMode(.tail)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: w == 0 ? .infinity : w, maxHeight: .infinity,
                                   alignment: header ? .center : (numeric ? .trailing : .leading))
                            .frame(width: w == 0 ? nil : w)
                            .background(header ? Theme.paper2 : (need ? Theme.needTint : .clear))
                            .overlay(alignment: .topTrailing) {
                                if need && numeric {
                                    Triangle().fill(Theme.needDot).frame(width: 7, height: 7)
                                }
                            }
                            .overlay(alignment: .trailing) { Theme.hair.frame(width: 0.5) }
                    }
                }
            }
        }
        .frame(height: header ? 20 : 28)
        .overlay(alignment: .bottom) { Theme.hair.frame(height: 0.5) }
        .overlay(alignment: .top) { if sum { Theme.ink3.frame(height: 1.5) } }
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// The chat surface owns the scroll area; embedded cards deliver full height.
struct AdaptiveScroll<Content: View>: View {
    @Environment(\.embeddedWorkflow) private var embedded
    @ViewBuilder var content: Content
    var body: some View {
        if embedded {
            content.fixedSize(horizontal: false, vertical: true)
        } else {
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }
                    .scrollIndicators(.automatic)
                    .contentMargins(.vertical, 6, for: .scrollIndicators)
                    .contentMargins(.trailing, 4, for: .scrollIndicators)
            }
        }
    }
}

/// In the chat the approvals stay reachable under the shared scroll area.
struct SortActions: View {
    @ObservedObject var model: AppModel
    private var chosen: Int {
        model.plan?.ops.filter { $0.kind != .mkdir && $0.certainty != .unreadable && !model.excluded.contains($0.id) }.count ?? 0
    }
    var body: some View {
        ResponsiveSheetActions {
            LinkButton(title: model.showReasons ? T("Hide Reasons", table: "Views") : T("Why This Way?", table: "Views"), icon: "questionmark.bubble") { model.showReasons.toggle() }
            HStack(spacing: 8) {
            Button(T("Not Now", table: "Views")) { model.escape() }.pippa(.quiet)
            Button { model.applySort() } label: {
                ApprovalLabel(title: T("Organize %lld Files", table: "Views", chosen), icon: "folder.badge.gearshape")
            }
            .pippa(.primary)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canConfirmPreview)
            }
        }
    }
}

struct InvoiceActions: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ResponsiveSheetActions {
            Segment(options: [(ExportFormat.xlsx, "Excel", nil), (ExportFormat.csv, T("Other Apps", table: "Views"), nil)], selection: $model.exportFormat)
                .accessibilityLabel(T("Format", table: "Views"))
            HStack(spacing: 8) {
            Button(T("Not Now", table: "Views")) { model.escape() }.pippa(.quiet)
            Button { model.exportInvoices() } label: { ApprovalLabel(title: T("Create Spreadsheet", table: "Views"), icon: "tablecells") }
                .pippa(.primary)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canConfirmPreview)
            }
        }
    }
}

/// Keeps approval controls visible when a single row no longer fits.
private struct ResponsiveSheetActions<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .trailing, spacing: 8) { content }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
