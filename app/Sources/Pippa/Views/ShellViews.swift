import PippaCore
import SwiftUI

// Shell surfaces. Building blocks in Theme.swift.

/// Root of the shell: content in the current form.
struct ShellRootView: View {
    @ObservedObject var model: AppModel
    var frozen: ShellMode? = nil

    var body: some View {
        ShellContentView(model: model, measuring: false, frozen: frozen)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    private var alignment: Alignment {
        switch (frozen ?? model.mode).shape {
        case .pill, .target: .leading
        case .sheet, .input, .panel: .topLeading
        }
    }
}

/// The content per form. `measuring` = measuring pass for the target size (no focus, no animation).
struct ShellContentView: View {
    @ObservedObject var model: AppModel
    var measuring: Bool
    var frozen: ShellMode? = nil

    var body: some View {
        let mode = measuring ? model.mode : (frozen ?? model.mode)
        if mode.isConversation {
            ConversationWorkspace(model: model, chat: model.conversations, mode: mode, measuring: measuring)
        } else {
            WorkflowContentView(model: model, measuring: measuring, frozen: mode)
        }
    }
}

/// Existing previews are content in the chat, not further kinds of window.
struct WorkflowContentView: View {
    @ObservedObject var model: AppModel
    var measuring: Bool
    /// On a change: the old content until it has faded out.
    var frozen: ShellMode? = nil

    private var mode: ShellMode { measuring ? model.mode : (frozen ?? model.mode) }

    var body: some View {
        content
            .id(mode.key)
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .pill:
            // The living pill: the real phase of the answer (cold start with measured progress included), or how the
            // last answer ended while nobody was looking (PillStatus.swift).
            PillContent(status: model.pillStatus)
        case .target(let hot):
            TargetContent(hot: hot)
        case .input:
            EmptyView()
        case .line:
            LineContent(model: model, tray: model.tray, measuring: measuring)
        case .resume:
            ResumeConversationContent(model: model, chat: model.conversations, measuring: measuring)
        case .working(let title, _, let writes):
            WorkingContent(model: model, title: title, writes: writes)
        case .onboarding:
            OnboardingContent(model: model)
        case .overview(let overview):
            OverviewContent(model: model, overview: overview)
        case .sortSheet:
            SortSheet(model: model)
        case .deadlines:
            DeadlinesContent(model: model)
        case .entryPreview:
            EntryPreviewContent(model: model)
        case .permission(let integration, let denied):
            PermissionContent(model: model, integration: integration, denied: denied)
        case .notice(let title, let detail, let buttons):
            NoticeContent(model: model, title: title, detail: detail, buttons: buttons)
        case .message(let title, let body, let isError):
            if isError {
                ErrorContent(model: model, message: body)
            } else {
                MessageContent(model: model, title: title, message: body)
            }
        }
    }
}

/// Completion and undo in the same place as preview and execution.
struct NoticeContent: View {
    @ObservedObject var model: AppModel
    var title: String
    var detail: String
    var buttons: [ToastButton]

    var body: some View {
        VStack(spacing: 0) {
            PanelHead(title: model.context?.name ?? "Pippa", onClose: { model.collapse() })
            VStack(alignment: .leading, spacing: 12) {
                ResultTitle(text: title, large: false)
                if !detail.isEmpty {
                    Text(detail)
                        .font(Fonts.body)
                        .foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 14)
            ActionBar {
                if buttons.isEmpty {
                    Button(T("Close", table: "Views")) { model.collapse() }.pippa(.quiet)
                } else {
                    ForEach(buttons) { button in
                        Button(button.title) { button.action() }
                            .pippa(button.title.hasPrefix(T("Undo", table: "App")) ? .tinted : button.primary ? .primary : .quiet)
                    }
                }
            }
            TrustSill(right: .none)
        }
        .workflowWidth(Theme.inputWidth)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 1 Pille

struct PillContent: View {
    var status: PillStatus
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        HStack(spacing: 8) {
            MarkSlot(size: 28)
            // A finished answer is written by hand, like the speech bubbles on the website: Pippa's small happy moment.
            ShimmerText(text: status.label, active: status.tone == .working, color: ink,
                        font: status.tone == .done ? HandFont.font() : nil)
                .contentTransition(.opacity)
            if let symbol {
                Image(systemName: symbol)
                    .font(.scaled(size: 12, weight: .bold))
                    .foregroundStyle(tint)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, symbol == nil ? 20 : 16)
        .frame(height: ShellTokens.pillHeight)
        .fixedSize()
        .background {
            // Done, a question, a problem: a soft wash of the tone, so the pill reads at a glance from across the screen.
            if status.tone != .rest && status.tone != .working {
                Capsule().fill(wash).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if let progress = status.progress {
                WakeBar(progress: progress, reduceMotion: reduceMotion, height: 2)
                    .padding(.horizontal, 22).padding(.bottom, 5)
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            if status.tone != .rest {
                Capsule()
                    .strokeBorder(tint.opacity(status.tone == .working ? 0.45 : 0.6), lineWidth: 1)
                    .shadow(color: (status.tone == .working ? Theme.accentFill : tint).opacity(0.6), radius: 8)
                    .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: status)
    }

    private var reduceMotion: Bool { systemReduceMotion || MarkHub.shared.reduced }

    private var tint: Color {
        switch status.tone {
        case .rest, .working, .needsYou: Theme.accent
        case .done: Theme.ok
        case .failed: Theme.need
        }
    }

    private var wash: Color {
        switch status.tone {
        case .done: Theme.okTint
        case .failed: Theme.needTint
        default: Theme.accentTint
        }
    }

    private var ink: Color {
        switch status.tone {
        case .needsYou: Theme.accent
        default: Theme.ink
        }
    }

    /// A small sign after the words, so the state does not depend on colour alone.
    private var symbol: String? {
        switch status.tone {
        case .rest, .working: nil
        case .needsYou: "questionmark"
        case .done: "checkmark"
        case .failed: "exclamationmark"
        }
    }
}

/// Name with shimmer while Pippa is working.
struct ShimmerText: View {
    var text: String
    var active: Bool
    var color: Color = Theme.ink
    /// `nil`: the pill's usual rounded semibold.
    var font: Font? = nil
    private let phaseState = State<CGFloat>(initialValue: -1)
    private var phase: CGFloat { get { phaseState.wrappedValue } nonmutating set { phaseState.wrappedValue = newValue } }

    var body: some View {
        let label = Text(text).font(font ?? .scaled(size: 15, weight: .semibold, design: .rounded))
        label
            .foregroundStyle(color)
            .lineLimit(1)
            .overlay {
                if active && !MarkHub.shared.reduced {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, Theme.accent, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.7)
                            .offset(x: geo.size.width * phase)
                    }
                    .mask(label)
                    .onAppear {
                        phase = -0.7
                        withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { phase = 1.0 }
                    }
                }
            }
    }
}

/// Noticed while dragging ("Drop here", dashed inner line) or over it ("Release", ring).
struct TargetContent: View {
    var hot: Bool
    var body: some View {
        HStack(spacing: 8) {
            MarkSlot(size: hot ? 34 : 28)
            Text(hot ? T("Let Go", table: "Views") : T("Drop Here", table: "Views"))
                .font(.scaled(size: hot ? 16.5 : 15, weight: .semibold, design: .rounded))
                .foregroundStyle(hot ? Theme.accent : Theme.ink)
        }
        .padding(.leading, 10)
        .padding(.trailing, hot ? 24 : 22)
        .frame(height: hot ? ShellTokens.hotHeight : ShellTokens.pillHeight)
        .fixedSize()
        .overlay {
            if hot {
                Capsule().strokeBorder(Theme.accentFill, lineWidth: 3.5)
            } else {
                Capsule().strokeBorder(Theme.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])).padding(5)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(hot ? T("Let go to drop", table: "Views") : T("Drop Here", table: "Views"))
    }
}

// MARK: - 2 Eingabe

/// Attachment chip in the field: 28 high, symbol in accent, × to remove.
struct ScopeChip: View {
    var name: String
    var icon: String
    var clear: () -> Void
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.scaled(size: 12, weight: .medium)).foregroundStyle(Theme.accent)
            Text(name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 150, alignment: .leading).fixedSize()
            Button(action: clear) {
                Image(systemName: "xmark").font(.scaled(size: 7.5, weight: .heavy)).foregroundStyle(Theme.ink3)
                    .frame(width: 16, height: 16).background(Circle().fill(Theme.fill2))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(T("Remove Attachment", table: "Views"))
        }
        .font(.scaled(size: 12.5, weight: .medium))
        .foregroundStyle(Theme.ink)
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .frame(height: 28)
        .background(Capsule().fill(Theme.accentTint))
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(T("Attached: %@", table: "Views", name))
    }
}

// MARK: - 3 Arbeiten

struct WorkingContent: View {
    @ObservedObject var model: AppModel
    var title: String
    /// Base sentence when the step changes something; `nil` = read only.
    var writes: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.context?.name ?? "Pippa")
                        .font(Fonts.hint).foregroundStyle(Theme.ink3)
                    Text(title)
                        .font(.scaled(size: 16, weight: .medium)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if writes == nil {
                    Button(T("Stop", table: "Views")) { model.stop() }.pippa(.quiet)
                }
            }
            ThinProgress(value: progressFraction, height: 6)
            if let p = model.workProgress, p.total > 0 {
                HStack(spacing: 12) {
                    if let name = p.current {
                        HStack(spacing: 6) {
                            DocIcon(kind: DocIcon.kind(for: URL(fileURLWithPath: name)), width: 11)
                            Text(FileName.display(name)).lineLimit(1).truncationMode(.middle)
                        }
                        .font(Fonts.hint).foregroundStyle(Theme.ink3)
                    }
                    Spacer(minLength: 0)
                    Text(T("%lld of %lld", table: "Views", min(p.done, p.total), p.total))
                        .font(.scaled(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.ink2).fixedSize()
                }
            }
        }
        .padding(20)
        .workflowWidth(Theme.workWidth)
        .accessibilityElement(children: .contain)
    }

    private var progressFraction: Double? {
        guard let p = model.workProgress, p.total > 0 else { return nil }
        return Double(p.done) / Double(p.total)
    }
}

// MARK: - 4/5/11 Overview

struct OverviewContent: View {
    @ObservedObject var model: AppModel
    var overview: Overview

    var body: some View {
        if overview.kind == .folder || overview.kind == .mixed {
            FolderOverview(model: model, overview: overview)
        } else {
            DocumentOverview(model: model, overview: overview)
        }
    }
}

/// Tasks from the actions of an overview (the first preselected).
struct OverviewTasks: View {
    @ObservedObject var model: AppModel
    var overview: Overview

    var body: some View {
        let actions = model.overviewActions(overview)
        VStack(spacing: 8) {
            ForEach(Array(actions.enumerated()), id: \.offset) { index, entry in
                TaskButton(icon: Self.icon(entry.action), title: title(entry.action),
                           subtitle: entry.enabled ? subtitle(entry.action) : waitHint,
                           preselected: index == model.selection, enabled: entry.enabled, order: 5 + index) {
                    model.run(entry.action)
                }
                .onHover { if $0 { model.selection = index } }
            }
        }
    }

    private var waitHint: String {
        if let p = model.progressValue { return T("Almost ready · %lld%%", table: "Views", Int(p * 100)) }
        return T("Almost ready", table: "Views")
    }

    static func icon(_ a: Action) -> String {
        switch a {
        case .sort: "folder.badge.gearshape"
        case .invoiceTable: "tablecells"
        case .ask: "magnifyingglass"
        case .deadlines: "calendar.badge.plus"
        }
    }

    private func title(_ a: Action) -> String {
        switch a {
        case .sort: T("Organize by Type and Month", table: "Views")
        case .invoiceTable: T("Invoices as a Spreadsheet", table: "Views")
        case .ask: T("Find Something Inside…", table: "Views")
        case .deadlines: overview.deadlines.count == 1 ? T("Add Deadline", table: "Views") : T("Add Deadlines", table: "Views")
        }
    }

    private func subtitle(_ a: Action) -> String? {
        switch a {
        case .sort: T("Give files clear names and put them in place", table: "Views")
        case .invoiceTable: T("One row per invoice: date, sender, amount", table: "Views")
        case .ask: nil
        case .deadlines: T("To Reminders or Calendar", table: "Views")
        }
    }
}

struct FolderOverview: View {
    @ObservedObject var model: AppModel
    var overview: Overview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHead(title: overview.title, meta: meta, onClose: { model.collapse() })
            VStack(alignment: .leading, spacing: 0) {
                ResultTitle(text: resultLine)
                if !overview.categories.isEmpty {
                    Well(padding: 0) {
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(Array(overview.categories.prefix(4).enumerated()), id: \.offset) { i, c in
                                Pile(name: c.name, count: c.count, index: i)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.top, 14)
                        .padding(.bottom, 12)
                    }
                    .padding(.top, 16)
                    .stagger(4)
                }
                OverviewTasks(model: model, overview: overview).padding(.top, 16)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            Color.clear.frame(height: 20)
            TrustSill(right: .text(T("Nothing changed yet", table: "Views"), icon: "eye"))
        }
        .workflowWidth(Theme.panelWidth)
    }

    private var meta: String? {
        overview.facts.first { $0.label.lowercased().contains("zeitraum") || $0.label.lowercased().contains("period") }?.value
    }

    /// "47 files from 3½ years": number large, time span human.
    private var resultLine: String {
        let base = overview.subtitle.isEmpty ? overview.title : overview.subtitle
        guard let m = meta, let span = Span.human(m), Self.endsWithFiles(base) else { return base }
        return T("%@ over %@", table: "Views", base, span)
    }

    /// Does the row end in "Dateien"? The subtitle comes from PippaCore, German or English.
    private static func endsWithFiles(_ text: String) -> Bool {
        ["Dateien", "Datei", "files", "file"].contains { text.hasSuffix($0) }
    }
}

/// Stapel: Illustration, Zahl, Name.
struct Pile: View {
    var name: String
    var count: Int
    var index: Int

    var body: some View {
        VStack(spacing: 2) {
            art.frame(width: 60, height: 52).padding(.bottom, 6)
            Text("\(count)").font(.scaled(size: 20, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.ink)
            Text(name).font(.scaled(size: 11.5, weight: .medium)).foregroundStyle(Theme.ink2).multilineTextAlignment(.center).lineLimit(2)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var art: some View {
        let n = name.lowercased()
        ZStack {
            // Category names come from PippaCore, German or English.
            if n.contains("rechnung") || n.contains("beleg") || n.contains("invoice") || n.contains("receipt") {
                SheetArt().frame(width: 30, height: 40).rotationEffect(.degrees(-8)).offset(x: -1, y: 0)
                SheetArt().frame(width: 30, height: 40).rotationEffect(.degrees(4)).offset(x: 3, y: -2)
                SheetArt(euro: true).frame(width: 30, height: 40).offset(x: 1, y: 2)
            } else if n.contains("brief") || n.contains("vertr") || n.contains("mail") || n.contains("letter") || n.contains("contract") {
                EnvelopeArt().frame(width: 42, height: 28).rotationEffect(.degrees(-6)).offset(x: -2, y: 4)
                EnvelopeArt().frame(width: 42, height: 28).rotationEffect(.degrees(5)).offset(x: 2, y: 0)
            } else if n.contains("foto") || n.contains("bild") || n.contains("photo") || n.contains("image") {
                PhotoArt(variant: 0).frame(width: 26, height: 30).rotationEffect(.degrees(-12)).offset(x: -11, y: 2)
                PhotoArt(variant: 1).frame(width: 26, height: 30).rotationEffect(.degrees(3)).offset(x: 1, y: -2)
                PhotoArt(variant: 2).frame(width: 26, height: 30).rotationEffect(.degrees(14)).offset(x: 13, y: 4)
            } else {
                SheetArt(lines: false).frame(width: 24, height: 32).rotationEffect(.degrees(-10)).offset(x: -8, y: 2)
                SheetArt().frame(width: 28, height: 22).rotationEffect(.degrees(8)).offset(x: 8, y: -6)
                SheetArt(lines: false).frame(width: 26, height: 20).rotationEffect(.degrees(-2)).offset(x: 3, y: 10)
            }
        }
    }
}

/// Letter or mail: who writes, what to do in large type, deadline as a calendar leaf, sentence verbatim.
struct DocumentOverview: View {
    @ObservedObject var model: AppModel
    var overview: Overview

    private var isMail: Bool { overview.kind == .mail }
    private var deadline: Deadline? { overview.deadlines.first }

    private var headTitle: String {
        if isMail { return T("What does this email want from me?", table: "Views") }
        switch overview.kind {
        case .link: return T("A Link", table: "Views")
        case .text: return T("Some Text", table: "Views")
        default: return T("What does this letter want?", table: "Views")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHead(title: headTitle, meta: nil, onClose: { model.collapse() })
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    SenderMark(name: overview.sender ?? overview.title, round: isMail)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(overview.sender ?? overview.title).font(.scaled(size: 14.5, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                        Text(overview.subtitle).font(Fonts.hint.monospacedDigit()).foregroundStyle(Theme.ink3).lineLimit(1)
                    }
                }
                .stagger(0)
                ResultTitle(text: deadline?.title ?? overview.title).padding(.top, 18)
                if let d = deadline, let date = d.date {
                    Well(padding: 0) {
                        HStack(spacing: 16) {
                            DateTile(date: date)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(T("no later than", table: "Views")).font(.scaled(size: 12, weight: .medium)).foregroundStyle(Theme.ink3)
                                Text(GermanDate.long(date)).font(.scaled(size: 18, weight: .bold, design: .rounded)).foregroundStyle(Theme.ink)
                                    .padding(.top, 3).padding(.bottom, 4)
                                HStack(spacing: 6) {
                                    Chip(text: GermanDate.relative(date), icon: "clock")
                                    if d.certainty != .sure { Chip(text: T("please check", table: "Views"), kind: .need) }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    .padding(.top, 16)
                    .stagger(4)
                } else if !overview.facts.isEmpty {
                    Well(padding: 14) {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                            ForEach(Array(overview.facts.prefix(5).enumerated()), id: \.offset) { _, f in
                                GridRow {
                                    Image(systemName: Self.factIcon(f.label)).font(.scaled(size: 13)).foregroundStyle(Theme.accent)
                                    (Text(f.label + " ").fontWeight(.semibold) + Text(f.value))
                                        .font(.scaled(size: 13.5).monospacedDigit())
                                        .foregroundStyle(Theme.ink)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    .padding(.top, 16)
                    .stagger(4)
                }
                if let d = deadline, !d.quote.isEmpty {
                    QuoteCard(quote: d.quote, mark: nil, section: nil, source: d.source ?? model.context?.items.first,
                              location: d.location, mail: isMail) { model.openDeadlineSource(d) }
                        .padding(.top, 10)
                        .stagger(5)
                }
                if deadline == nil {
                    OverviewTasks(model: model, overview: overview).padding(.top, 16)
                }
                // What Pippa can do with the document (buttons live in the skills) (text in the conversation).
                if let place = PippaSkill.place(for: overview.kind, fileExtension: model.context?.items.first?.pathExtension) {
                    SkillActions(model: model, place: place).padding(.top, 14)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            if deadline != nil {
                ActionBar {
                    Button { model.startDeadlines() } label: { Label(isMail ? T("Add to Calendar", table: "Views") : T("Add Deadline", table: "Views"), systemImage: "calendar") }
                        .pippa(.primary)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Color.clear.frame(height: 20)
            }
            TrustSill(left: isMail ? T("I read it and can draft a reply; you send it", table: "Views") : T("Runs on your Mac", table: "Views"),
                      leftIcon: isMail ? "eye" : "lock",
                      right: .text(isMail ? T("Nothing sent", table: "Views") : T("Read only", table: "Views"), icon: isMail ? nil : "eye"))
        }
        .workflowWidth(Theme.wideWidth)
    }

    static func factIcon(_ label: String) -> String {
        // Labels come from PippaCore, German or English.
        let l = label.lowercased()
        if l.contains("termin") || l.contains("datum") || l.contains("date") || l.contains("appointment") { return "calendar" }
        if l.contains("frist") || l.contains("bis") || l.contains("fällig") || l.contains("deadline") || l.contains("due") { return "clock" }
        if l.contains("anhang") || l.contains("attachment") { return "paperclip" }
        if l.contains("betrag") || l.contains("summe") || l.contains("amount") || l.contains("total") { return "eurosign" }
        if l.contains("absender") || l.contains("von") || l.contains("sender") || l.contains("from") { return "person" }
        return "info.circle"
    }
}

/// Paper with quote (serif, highlighted passage) and source chip.
struct QuoteCard: View {
    var quote: String
    var mark: String?
    var section: String?
    var source: URL?
    var location: String?
    var name: String? = nil
    var mail = false
    var hint: String? = nil
    var open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let section {
                Text(section.uppercased())
                    .font(.scaled(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Theme.ink3)
                    .padding(.leading, 20)
                    .padding(.bottom, 8)
            }
            QuoteText(text: quote, mark: mark)
            if source != nil || name != nil {
                HStack(spacing: 8) {
                    SourceChip(name: name ?? (mail ? T("Email", table: "Views") : source?.lastPathComponent ?? ""), location: location, mail: mail, url: source, action: open)
                        .layoutPriority(1)
                    if let hint { Text(hint).font(Fonts.hint).foregroundStyle(Theme.ink3).lineLimit(1) }
                }
                .padding(.leading, 20)
                .padding(.top, 12)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper()
    }
}

// MARK: - 12 Fehler, Hinweise

struct ErrorContent: View {
    @ObservedObject var model: AppModel
    var message: String
    private let openState = State(initialValue: false)

    var body: some View {
        let partial = model.partialReceipt
        VStack(alignment: .leading, spacing: 0) {
            PanelHead(title: model.lastWorkTitle.isEmpty ? "Pippa" : model.lastWorkTitle, meta: nil, onClose: { model.collapse() })
            VStack(alignment: .leading, spacing: 8) {
                ResultTitle(text: T("That didn’t work.", table: "Views"))
                Lead(text: partial != nil ? T("Part of it is already done. One click puts everything back the way it was.", table: "Views")
                                          : T("Nothing was changed. Your files are just as they were.", table: "Views")).stagger(1)
                // The message comes from AppModel: same key from the same table ("App").
                if message != T("Nothing was changed.", table: "App") {
                    Button {
                        openState.wrappedValue.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: openState.wrappedValue ? "chevron.down" : "chevron.right").font(.scaled(size: 10, weight: .bold))
                            Text(T("What happened?", table: "Views"))
                        }
                        .font(.scaled(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                    if openState.wrappedValue {
                        Text(message).font(.scaled(size: 13)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            ActionBar {
                Button(T("Close", table: "Views")) { model.collapse() }.pippa(.quiet)
                Button(T("Report a Problem…", table: "Views")) { ProblemReport.open() }.pippa(.quiet)
                if let partial {
                    Button { model.undo(partial) } label: { Label(T("Undo", table: "Views"), systemImage: "arrow.uturn.backward") }
                        .pippa(.tinted)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button { model.retryLast() } label: { Label(T("Try Again", table: "Views"), systemImage: "arrow.clockwise") }
                        .pippa(.primary)
                        .keyboardShortcut(.defaultAction)
                }
            }
            TrustSill(right: .none)
        }
        .workflowWidth(Theme.workWidth)
    }
}

/// List "what was left behind" with reason.
struct ReasonList: View {
    var items: [FileReason]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.prefix(12).enumerated()), id: \.offset) { i, r in
                HStack(alignment: .top, spacing: 10) {
                    DocIcon(kind: DocIcon.kind(for: URL(fileURLWithPath: r.name)), width: 16).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(FileName.display(r.name)).font(.scaled(size: 13.5, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                        Text(r.why).font(.scaled(size: 12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .overlay(alignment: .top) { if i > 0 { Theme.hair.frame(height: 0.5) } }
            }
            if items.count > 12 {
                Text(T("and %lld more", table: "Views", items.count - 12)).font(Fonts.hint).foregroundStyle(Theme.ink3).padding(.top, 6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.needTint))
    }
}

/// Calm hints without errors ("Gleich bereit", "Worum geht es?" ...).
struct MessageContent: View {
    @ObservedObject var model: AppModel
    var title: String
    var message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHead(title: title, meta: nil, onClose: { model.collapse() })
            VStack(alignment: .leading, spacing: 10) {
                Lead(text: message).stagger(0)
                // Titles come from AppModel: same keys from the same table ("App").
                if title == T("Almost ready", table: "Views"), let p = model.progressValue {
                    ThinProgress(value: p).stagger(2)
                }
                if !model.messageList.isEmpty {
                    ReasonList(items: model.messageList).stagger(4)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 10)
            ActionBar {
                if title == T("What’s this about?", table: "App") {
                    Button(T("Close", table: "Views")) { model.collapse() }.pippa(.quiet)
                    Button { model.chooseFolder() } label: { Label(T("Choose Folder…", table: "Views"), systemImage: "folder") }
                        .pippa(.secondary)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(T("Close", table: "Views")) { model.collapse() }.pippa(.quiet).keyboardShortcut(.defaultAction)
                    if !model.messageList.isEmpty {
                        Button { model.revealMessageFolder() } label: { Label(T("Show in Finder", table: "Views"), systemImage: "folder") }.pippa(.secondary)
                    }
                }
            }
            TrustSill(right: .none)
        }
        .workflowWidth(Theme.workWidth)
    }
}

/// Time span like "Nov. 2025 – Aug. 2026" in human terms: "10 Monaten", "3½ Jahren".
enum Span {
    static let months = ["jan", "feb", "mär", "apr", "mai", "jun", "jul", "aug", "sep", "okt", "nov", "dez"]
    /// The same months in English, in case PippaCore writes the span in English.
    static let monthsEnglish = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    static func human(_ text: String) -> String? {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: "–-"))
        guard parts.count == 2, let a = parse(parts[0]), let b = parse(parts[1]) else { return nil }
        let n = (b.year - a.year) * 12 + (b.month - a.month) + 1
        if n <= 1 { return nil }
        if n < 18 { return T("%lld months", table: "Views", n) }
        let halves = Int((Double(n) / 6).rounded())
        let years = halves / 2
        if halves % 2 == 0 { return T("%lld years", table: "Views", years) }
        return T("%lld½ years", table: "Views", years)
    }

    private static func parse(_ s: String) -> (year: Int, month: Int)? {
        let words = s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard let y = words.compactMap({ Int($0) }).first(where: { $0 > 1900 }),
              let m = words.compactMap({ w in month(w) }).first else { return nil }
        return (y, m + 1)
    }

    private static func month(_ word: Substring) -> Int? {
        if let i = months.firstIndex(where: { word.hasPrefix($0) }) { return i }
        return monthsEnglish.firstIndex { word.hasPrefix($0) }
    }
}
