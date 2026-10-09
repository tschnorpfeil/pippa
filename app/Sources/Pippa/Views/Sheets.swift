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
        .font(.scaled(size: 12.5))
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
                .font(.scaled(size: 12.5, weight: .medium).monospacedDigit())
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
                        .font(.scaled(size: 16, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .frame(width: 26)
                        .accessibilityHidden(true)
                } else {
                    FolderArt(width: 26)
                }
                (Text(g.key).foregroundStyle(Theme.ink)
                 + Text(g.subs.isEmpty ? "" : "  › " + g.subs.sorted().joined(separator: ", ")).foregroundStyle(Theme.ink3).fontWeight(.medium))
                    .font(.scaled(size: 14, weight: .semibold))
                    .lineLimit(1)
                if g.isNew {
                    Text(T("NEW", table: "Views"))
                        .font(.scaled(size: 10, weight: .bold))
                        .tracking(0.2)
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.accentTint))
                }
                Spacer(minLength: 6)
                Text(included == g.rows.count ? "\(g.rows.count)" : T("%lld of %lld", table: "Views", included, g.rows.count))
                    .font(.scaled(size: 12.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.ink3)
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.scaled(size: 11, weight: .semibold))
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
                        Image(systemName: "chevron.down").font(.scaled(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
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
                        .font(.scaled(size: 13.5, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .strikethrough(!on, color: Theme.fill3)
                        .lineLimit(1).truncationMode(.middle)
                    if row.unsure { Chip(text: T("unsure", table: "Views"), kind: .need) }
                }
                // Copies for the Trash always say which file stays.
                if model.showReasons || row.unsure || row.op.kind == .trash {
                    Text(row.reason)
                        .font(.scaled(size: 11.5))
                        .foregroundStyle(row.unsure ? Theme.need : Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let old = row.old {
                    // Plain grey words, no typewriter font (UI-FIXPLAN 1.4).
                    Text(T("was: %@", table: "Views", old))
                        .font(.scaled(size: 11.5))
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
                Text(T("Stays where it is", table: "Views")).font(.scaled(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Text("\(stay.count)").font(.scaled(size: 12.5, weight: .medium).monospacedDigit()).foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, 22)
            .frame(height: 40)
            ForEach(stay) { s in
                HStack(spacing: 12) {
                    FileThumbnail(url: s.url, width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.name).font(.scaled(size: 13.5, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                        Text(s.why).font(.scaled(size: 11.5)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
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
                        Text(T("Now", table: "Views")).font(.scaled(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text(T("%lld loose files", table: "Views", total)).font(.scaled(size: 12.5)).foregroundStyle(Theme.ink3)
                    }
                    .padding(.top, 8)
                }
                .frame(width: 150, alignment: .leading)
                Image(systemName: "arrow.right").font(.scaled(size: 15, weight: .medium)).foregroundStyle(Theme.ink3).frame(width: 40)
                HStack(alignment: .top, spacing: 10) {
                    ForEach(groups.prefix(4)) { g in
                        VStack(spacing: 4) {
                            FolderArt()
                            Text(g.key).font(.scaled(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink).multilineTextAlignment(.center).lineLimit(2)
                            Text(detail(g)).font(.scaled(size: 11.5)).foregroundStyle(Theme.ink3)
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
