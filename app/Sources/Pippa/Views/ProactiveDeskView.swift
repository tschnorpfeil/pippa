import AppKit
import PippaCore
import SwiftUI

/// "For You": what Pippa prepared quietly, the routines that prepare it, and a sentence field to add one. Nothing here
/// sends or changes anything by itself; every result waits for the person.
struct ProactiveDeskView: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var setup: SetupModel
    @ObservedObject private var coordinator = ProactivityCoordinator.shared
    @Environment(\.openRoutineEditor) private var openEditor
    private let queryState = State(initialValue: "")
    private let snoozedOpen = State(initialValue: false)
    private let activityOpen = State(initialValue: false)
    @FocusState private var queryFocused: Bool

    private var query: String { queryState.wrappedValue }
    private var settings: ProactivitySettings { coordinator.settings }
    private var showsStarters: Bool { !settings.enabled || coordinator.routines.isEmpty }

    var body: some View {
        let draft = RoutineUI.parse(query)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.x3) {
                header
                quickAdd(draft)
                if showsStarters { starters.transition(.opacity) }
                if settings.enabled { readySection.transition(.opacity) }
                if !coordinator.routines.isEmpty { routinesSection }
                if !coordinator.recentRuns.isEmpty { activitySection }
            }
            .animation(Theme.arrive, value: draft != nil)
            .animation(Theme.arrive, value: settings.enabled)
            .animation(Theme.arrive, value: coordinator.openMatters.map(\.id))
            .frame(maxWidth: Layout.column, alignment: .leading)
            .padding(.horizontal, Layout.gutter)
            .padding(.vertical, Space.x4)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
        .background(Color(nsColor: Theme.chatTint))
    }

    // MARK: Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Space.l) {
                titleBlock
                Spacer(minLength: Space.m)
                headerActions
            }
            VStack(alignment: .leading, spacing: Space.l) {
                titleBlock
                headerActions
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(T("For You", table: "Views"))
                .font(Typo.title).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            pulse
        }
    }

    /// Whether Pippa is watching right now, in one line.
    private var pulse: some View {
        let next = coordinator.nextScheduledSummary
        let (color, text): (Color, String) = {
            if !settings.enabled { return (Theme.ink3, T("Off — turn on a routine below to start", table: "Views")) }
            if coordinator.isFocusActiveNow {
                let base = T("Waiting during Focus", table: "Views")
                return (Theme.need, next.map { base + " · " + $0 } ?? base)
            }
            let base = T("Watching quietly", table: "Views")
            return (Theme.ok, next.map { base + " · " + $0 } ?? base)
        }()
        return HStack(spacing: Space.s) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(text).font(Typo.footnote).foregroundStyle(Theme.ink2).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var headerActions: some View {
        HStack(spacing: Space.s) {
            if settings.enabled {
                GhostButton(title: T("Pause", table: "Views"), symbol: "pause") { coordinator.setEnabled(false) }
            } else if !coordinator.routines.isEmpty {
                GhostButton(title: T("Resume", table: "Views"), symbol: "play") { coordinator.setEnabled(true) }
            }
            ActionPill(title: T("New Routine…", table: "Views"), primary: true) { openEditor(.blank) }
        }
    }

    // MARK: Quick add

    private func quickAdd(_ draft: ParsedRoutineDraft?) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.ml) {
                Image(systemName: "repeat").font(Typo.callout.weight(.medium)).foregroundStyle(Theme.ink3)
                    .accessibilityHidden(true)
                TextField(T("Tell Pippa what to watch or check regularly…", table: "Views"), text: queryState.projectedValue)
                    .textFieldStyle(.plain).font(Typo.body)
                    .focused($queryFocused)
                    .onSubmit { add(draft) }
                if !query.isEmpty {
                    Button { queryState.wrappedValue = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(Typo.callout).foregroundStyle(Theme.ink3)
                            .frame(width: 20, height: 20).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(T("Clear", table: "Views"))
                    .accessibilityLabel(T("Clear", table: "Views"))
                }
            }
            .padding(.horizontal, Space.card).frame(minHeight: 44)
            .raised(Radius.card, lifted: queryFocused)
            .animation(Theme.quick, value: queryFocused)
            if let draft {
                draftStrip(draft).transition(.opacity.combined(with: .move(edge: .top)))
            } else if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(T("Say when, for example “every weekday at 8” or “when a new file arrives”.", table: "Views"))
                    .font(Typo.footnote).foregroundStyle(Theme.ink3)
                    .padding(.horizontal, Space.card)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func draftStrip(_ draft: ParsedRoutineDraft) -> some View {
        let summary = HStack(spacing: Space.m) {
            Label(draft.humanSummary, systemImage: "clock")
                .font(Typo.caption.weight(.medium)).foregroundStyle(Theme.accent).monospacedDigit()
                .padding(.horizontal, Space.m).frame(height: 22)
                .background(Theme.accentTint, in: Capsule())
                .lineLimit(1).fixedSize()
            Text(draft.title).font(Typo.callout.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(1)
        }
        let actions = HStack(spacing: Space.s) {
            ActionPill(title: T("Customize…", table: "Views")) { openEditor(.fromText(query)) }
            ActionPill(title: T("Add", table: "Views"), primary: true) { add(draft) }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.m) { summary; Spacer(minLength: Space.m); actions }
            VStack(alignment: .leading, spacing: Space.m) { summary; actions }
        }
        .padding(.horizontal, Space.card).padding(.vertical, Space.ml)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func add(_ draft: ParsedRoutineDraft?) {
        guard draft != nil else { return }
        if coordinator.createRoutineFromText(query) != nil {
            withAnimation(Theme.leave) { queryState.wrappedValue = "" }
        }
    }

    // MARK: Starter packs

    private static let starterTemplates: [ProactiveRoutineTemplate] = [
        .morningBrief, .eveningPreview, .meetingPrep, .calendarRadar, .reminderRadar, .folderWatch,
    ]

    private var starters: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text(T("Pippa prepares things quietly on your Mac and places them here. She never sends or changes anything without you.", table: "Views"))
                .font(Typo.callout).foregroundStyle(Theme.ink2).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Space.l)], spacing: Space.l) {
                ForEach(Self.starterTemplates, id: \.self) { template in
                    StarterCard(template: template,
                                ready: coordinator.suggestedTemplates.contains(template),
                                on: settings.enabled && coordinator.routines.contains { $0.template == template && $0.enabled }) {
                        coordinator.activateStarterPack(template)
                    }
                }
            }
        }
    }

    // MARK: Ready for you

    private var readySection: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            sectionTitle(T("Ready for you", table: "Views"))
            if coordinator.openMatters.isEmpty {
                HStack(spacing: Space.m) {
                    Image(systemName: "checkmark.circle").foregroundStyle(Theme.ok).accessibilityHidden(true)
                    Text(T("All caught up. New items will appear here quietly.", table: "Views"))
                        .foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(Typo.callout)
                .padding(.horizontal, Space.card).padding(.vertical, Space.l)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            } else {
                ForEach(coordinator.openMatters) { matter in
                    MatterCard(matter: matter, coordinator: coordinator,
                               canRun: setup.canAnswer && !chat.isAnswering)
                        .transition(.opacity)
                }
            }
            if !coordinator.snoozedMatters.isEmpty { snoozed }
        }
    }

    private var snoozed: some View {
        DisclosureGroup(isExpanded: snoozedOpen.projectedValue) {
            VStack(spacing: 0) {
                ForEach(Array(coordinator.snoozedMatters.enumerated()), id: \.element.id) { index, matter in
                    if index > 0 { SettingsDivider() }
                    HStack(spacing: Space.ml) {
                        Image(systemName: "moon.zzz").font(Typo.footnote).foregroundStyle(Theme.ink3).frame(width: 18)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text(matter.title).font(Typo.callout).foregroundStyle(Theme.ink).lineLimit(1)
                            if let until = matter.snoozedUntil {
                                Text(T("Back %@", table: "Views", RoutineUI.dayAndTime(until)))
                                    .font(Typo.caption).foregroundStyle(Theme.ink3).monospacedDigit()
                            }
                        }
                        Spacer(minLength: Space.m)
                        GhostButton(title: T("Open in Chat", table: "Views"), symbol: "bubble.left") {
                            coordinator.openInChat(matter, autoSend: false, surface: .panel)
                        }
                        GhostButton(title: T("Done", table: "Views"), symbol: "checkmark") {
                            coordinator.markDone(matter, surface: .panel)
                        }
                    }
                    .padding(.horizontal, Space.card).padding(.vertical, Space.ml)
                }
            }
            .raised(Radius.card)
            .padding(.top, Space.m)
        } label: {
            Text(T("Snoozed (%lld)", table: "Views", coordinator.snoozedMatters.count))
                .font(Typo.callout.weight(.medium)).foregroundStyle(Theme.ink2).monospacedDigit()
        }
    }

    // MARK: Your routines

    private var routinesSection: some View {
        let unused = coordinator.suggestedTemplates.filter { template in
            !coordinator.routines.contains { $0.template == template && $0.enabled }
        }
        return VStack(alignment: .leading, spacing: Space.l) {
            sectionTitle(T("Your routines", table: "Views"))
            VStack(spacing: 0) {
                ForEach(Array(coordinator.routines.enumerated()), id: \.element.id) { index, routine in
                    if index > 0 { SettingsDivider() }
                    RoutineRow(routine: routine, coordinator: coordinator,
                               running: coordinator.runningRoutineIDs.contains(routine.id),
                               edit: { openEditor(.edit(routine)) })
                }
            }
            .raised(Radius.card)
            if !unused.isEmpty {
                FlowRow(spacing: Space.s, maxItemWidth: 260) {
                    ForEach(unused, id: \.self) { template in
                        AddStarterChip(template: template) { coordinator.activateStarterPack(template) }
                    }
                }
            }
        }
    }

    // MARK: Recent activity

    private var activitySection: some View {
        DisclosureGroup(isExpanded: activityOpen.projectedValue) {
            VStack(spacing: 0) {
                ForEach(Array(coordinator.recentRuns.enumerated()), id: \.element.id) { index, run in
                    if index > 0 { SettingsDivider() }
                    HStack(spacing: Space.ml) {
                        Text(run.routineTitle).font(Typo.callout).foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer(minLength: Space.m)
                        Text(RoutineUI.outcomeLabel(run.outcome)).font(Typo.footnote).foregroundStyle(Theme.ink2)
                        Text(RoutineUI.relative(run.finishedAt)).font(Typo.caption).foregroundStyle(Theme.ink3)
                            .monospacedDigit().frame(minWidth: 70, alignment: .trailing)
                    }
                    .padding(.horizontal, Space.card).padding(.vertical, Space.m)
                    .accessibilityElement(children: .combine)
                }
            }
            .raised(Radius.card)
            .padding(.top, Space.m)
        } label: {
            Text(T("Recent activity", table: "Views")).font(Typo.callout.weight(.medium)).foregroundStyle(Theme.ink2)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(Typo.headline).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Pieces

/// One starter routine: what it does, when, and one click to turn it on.
private struct StarterCard: View {
    var template: ProactiveRoutineTemplate
    var ready: Bool
    var on: Bool
    var activate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.ml) {
            HStack(alignment: .top, spacing: Space.ml) {
                RoutineIcon(template: template)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(RoutineUI.title(template)).font(Typo.headline).foregroundStyle(Theme.ink)
                    Text(RoutineUI.explanation(template)).font(Typo.callout).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            HStack(spacing: Space.s) {
                Label(RoutineUI.cadence(template), systemImage: "clock")
                    .font(Typo.caption).foregroundStyle(Theme.ink3).monospacedDigit().lineLimit(1)
                if ready && !on {
                    Text(verbatim: "·").font(Typo.caption).foregroundStyle(Theme.ink3).accessibilityHidden(true)
                    Text(T("Ready", table: "Views")).font(Typo.caption.weight(.medium)).foregroundStyle(Theme.ok)
                }
                Spacer(minLength: Space.s)
                if on {
                    Label(T("On", table: "Views"), systemImage: "checkmark")
                        .font(Typo.footnote.weight(.medium)).foregroundStyle(Theme.ok)
                } else {
                    ActionPill(title: T("Turn on", table: "Views"), action: activate)
                        .accessibilityLabel(T("Turn on %@", table: "Views", RoutineUI.title(template)))
                }
            }
        }
        .padding(Space.card)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .raised(Radius.card)
    }
}

/// A routine's symbol in a quiet well.
struct RoutineIcon: View {
    var template: ProactiveRoutineTemplate
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: RoutineUI.icon(template))
            .font(Typo.callout.weight(.medium)).foregroundStyle(Theme.accent)
            .frame(width: size, height: size)
            .background(Theme.accentTint, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A starter not on yet, under the routines: one click adds it.
private struct AddStarterChip: View {
    var template: ProactiveRoutineTemplate
    var action: () -> Void
    private let hoverState = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            Label(RoutineUI.title(template), systemImage: "plus")
                .font(Typo.footnote.weight(.medium)).foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .padding(.horizontal, Space.ml).frame(height: 26)
                .background(hoverState.wrappedValue ? Theme.fill3 : Theme.fill2, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering } }
        .help(RoutineUI.explanation(template))
    }
}

/// The look of `ActionPill` for a menu's label ("Later", "⋯").
private struct PillLabel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .font(Typo.footnote.weight(.medium)).foregroundStyle(Theme.ink)
            .lineLimit(1)
            .padding(.horizontal, Space.ml).frame(height: 26)
            .background(Theme.fill2, in: Capsule())
            .contentShape(Capsule())
    }
}

/// One prepared item: what it is, the summary, its files and the person's answers.
private struct MatterCard: View {
    var matter: ProactiveMatter
    var coordinator: ProactivityCoordinator
    var canRun: Bool
    private let expandedState = State(initialValue: false)

    private var isLong: Bool {
        matter.summary.count > 360 || matter.summary.filter { $0 == "\n" }.count >= 6
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Label(RoutineUI.kindLabel(matter.kind), systemImage: RoutineUI.kindIcon(matter.kind))
                    .font(Typo.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                Spacer(minLength: Space.m)
                Text(RoutineUI.relative(matter.updatedAt)).font(Typo.caption).foregroundStyle(Theme.ink3).monospacedDigit()
            }
            Text(matter.title).font(Typo.headline).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if !matter.summary.isEmpty {
                Text(matter.summary)
                    .font(Typo.callout).foregroundStyle(Theme.ink2).lineSpacing(2)
                    .lineLimit(expandedState.wrappedValue ? nil : 6)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if isLong {
                    Button(expandedState.wrappedValue ? T("Show less", table: "Views") : T("Show more", table: "Views")) {
                        withAnimation(Theme.arrive) { expandedState.wrappedValue.toggle() }
                    }
                    .pippa(.quiet).font(Typo.footnote)
                }
            }
            if !matter.preparedFiles.isEmpty { files }
            actions.padding(.top, Space.xs)
        }
        .padding(Space.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .raised(Radius.card)
    }

    private var files: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s) {
                ForEach(matter.preparedFiles, id: \.self) { path in
                    let url = URL(fileURLWithPath: path)
                    NativeFilePreviewButton(url: url) {
                        HStack(spacing: Space.s) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                                .resizable().frame(width: 16, height: 16)
                                .accessibilityHidden(true)
                            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: 180, alignment: .leading)
                        }
                        .font(Typo.footnote).foregroundStyle(Theme.ink)
                        .padding(.horizontal, Space.m).frame(height: 28)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                        .contentShape(Rectangle())
                    }
                }
            }
        }
    }

    private var actions: some View {
        let primary = HStack(spacing: Space.s) {
            ActionPill(title: T("Open in Chat", table: "Views"), primary: true) {
                coordinator.openInChat(matter, autoSend: false, surface: .panel)
            }
            if canRun {
                ActionPill(title: T("Run in Chat", table: "Views")) { coordinator.openInChat(matter, autoSend: true, surface: .panel) }
                    .help(T("Opens a new conversation and asks right away", table: "Views"))
            }
        }
        let secondary = HStack(spacing: Space.s) {
            ActionPill(title: T("Done", table: "Views")) { coordinator.markDone(matter, surface: .panel) }
            Menu {
                Button(T("In 3 hours", table: "Views")) { coordinator.snooze(matter, hours: 3, surface: .panel) }
                Button(T("Tomorrow at 08:00", table: "Views")) { coordinator.snoozeUntilTomorrowMorning(matter, surface: .panel) }
            } label: {
                PillLabel { Text(T("Later", table: "Views")) }
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(T("Later", table: "Views"))
            Menu {
                Button(T("Dismiss", table: "Views")) { coordinator.dismissMatter(matter, surface: .panel) }
                Button(T("Mute this kind", table: "Views")) { coordinator.muteKind(matter.kind, dismissing: matter, surface: .panel) }
            } label: {
                PillLabel { Image(systemName: "ellipsis") }
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help(T("More", table: "Views"))
            .accessibilityLabel(T("More", table: "Views"))
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.s) { primary; secondary; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: Space.s) { primary; secondary }
        }
    }
}

/// One routine in the grouped list: what, when, how it went, and its switch.
private struct RoutineRow: View {
    var routine: ProactiveRoutine
    var coordinator: ProactivityCoordinator
    var running: Bool
    var edit: () -> Void
    private let hoverState = State(initialValue: false)

    var body: some View {
        HStack(spacing: Space.ml) {
            RoutineIcon(template: routine.template, size: 28)
                .opacity(routine.enabled ? 1 : 0.55)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(routine.title).font(Typo.callout.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(routine.humanTriggerSummary(language: RoutineUI.language))
                    .font(Typo.footnote).foregroundStyle(Theme.ink2).monospacedDigit().lineLimit(1)
                status
            }
            .layoutPriority(1)
            Spacer(minLength: Space.m)
            if running {
                SpinRing(size: 12, lineWidth: 1.6)
                    .accessibilityLabel(T("Running…", table: "Views"))
            }
            HStack(spacing: Space.xxs) {
                GhostButton(title: T("Run now", table: "Views"), symbol: "play.fill", compact: true) {
                    coordinator.runRoutineNow(routine.id)
                }
                .disabled(running || !coordinator.settings.enabled || !routine.enabled)
                GhostButton(title: T("Edit", table: "Views"), symbol: "slider.horizontal.3", compact: true, action: edit)
            }
            .opacity(hoverState.wrappedValue ? 1 : 0)
            .allowsHitTesting(hoverState.wrappedValue)
            Toggle(routine.title, isOn: Binding(get: { routine.enabled },
                                                set: { coordinator.toggleRoutine(routine.id, enabled: $0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }
        .padding(.horizontal, Space.card).padding(.vertical, Space.ml)
        .background(hoverState.wrappedValue ? Theme.rowHover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering } }
        .contextMenu {
            Button(T("Run now", table: "Views")) { coordinator.runRoutineNow(routine.id) }
                .disabled(running || !coordinator.settings.enabled || !routine.enabled)
            Button(T("Edit…", table: "Views"), action: edit)
            Divider()
            Button(T("Delete", table: "Views"), role: .destructive) { coordinator.deleteRoutine(routine.id) }
        }
    }

    private var status: some View {
        HStack(spacing: Space.s) {
            Text(statusText).font(Typo.caption).foregroundStyle(Theme.ink3).monospacedDigit().lineLimit(1)
            if routine.executionMode == .localAIReadOnly {
                Text(T("Local AI · read-only", table: "Views"))
                    .font(Typo.caption.weight(.medium)).foregroundStyle(Theme.ink2)
                    .padding(.horizontal, Space.s).frame(height: 18)
                    .background(Theme.fill2, in: Capsule())
                    .lineLimit(1).fixedSize()
            }
        }
    }

    private var statusText: String {
        guard routine.enabled else { return T("Off", table: "Views") }
        if running { return T("Running…", table: "Views") }
        switch routine.lastOutcome {
        case .prepared?:
            if let date = routine.lastRunAt { return T("Prepared · %@", table: "Views", RoutineUI.relative(date)) }
            return T("Prepared", table: "Views")
        case .silent?: return T("Quiet — nothing new", table: "Views")
        case .held?: return T("Waiting", table: "Views")
        case .failed?: return T("Couldn’t run", table: "Views")
        case .skipped?: return T("Skipped", table: "Views")
        case nil:
            if let next = routine.nextRunAt { return T("Next: %@", table: "Views", RoutineUI.dayAndTime(next)) }
            return T("Watching", table: "Views")
        }
    }
}

// MARK: - Words and symbols

/// Plain words and calm symbols for routines and what they prepare, shared by the desk, the editor and the welcome.
@MainActor
enum RoutineUI {
    /// The language Pippa's UI runs in.
    static var language: String {
        (Bundle.module.preferredLocalizations.first ?? "en").lowercased().hasPrefix("de") ? "de" : "en"
    }

    static var locale: Locale { Locale(identifier: language) }

    static func parse(_ text: String) -> ParsedRoutineDraft? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return RoutineNaturalLanguageParser.parse(trimmed, language: language)
    }

    static func icon(_ template: ProactiveRoutineTemplate) -> String {
        switch template {
        case .morningBrief: "sun.horizon"
        case .eveningPreview: "moon.stars"
        case .weeklyReview: "calendar"
        case .folderWatch: "folder"
        case .calendarRadar: "calendar.badge.clock"
        case .meetingPrep: "person.2"
        case .reminderRadar: "bell"
        case .followUp: "arrow.turn.down.right"
        case .customCheck: "repeat"
        }
    }

    static func title(_ template: ProactiveRoutineTemplate) -> String {
        switch template {
        case .morningBrief: T("Morning Brief", table: "Views")
        case .eveningPreview: T("Evening Preview", table: "Views")
        case .weeklyReview: T("Weekly Review", table: "Views")
        case .folderWatch: T("Watch Folder", table: "Views")
        case .calendarRadar: T("Calendar Radar", table: "Views")
        case .meetingPrep: T("Meeting Prep", table: "Views")
        case .reminderRadar: T("Reminder Radar", table: "Views")
        case .followUp: T("Follow-up", table: "Views")
        case .customCheck: T("Custom", table: "Views")
        }
    }

    static func explanation(_ template: ProactiveRoutineTemplate) -> String {
        switch template {
        case .morningBrief: T("Your day at a glance: appointments, due reminders and open items.", table: "Views")
        case .eveningPreview: T("What’s on tomorrow and what is still open today.", table: "Views")
        case .weeklyReview: T("The next seven days: busy days, overlaps and overdue reminders.", table: "Views")
        case .folderWatch: T("New files in a folder you choose, ready for a look.", table: "Views")
        case .calendarRadar: T("Speaks up when an appointment is added, moved or changes place.", table: "Views")
        case .meetingPrep: T("Time, place and matching reminders before an appointment.", table: "Views")
        case .reminderRadar: T("Speaks up when reminders become overdue or due today.", table: "Views")
        case .followUp: T("Comes back to something on a day you choose.", table: "Views")
        case .customCheck: T("Your own check, in your own words.", table: "Views")
        }
    }

    /// When a starter runs, in a few words.
    static func cadence(_ template: ProactiveRoutineTemplate) -> String {
        switch template {
        case .morningBrief: T("Every day at 08:00", table: "Views")
        case .eveningPreview: T("Every day at 18:00", table: "Views")
        case .weeklyReview: T("Sundays at 18:00", table: "Views")
        case .folderWatch: T("When new files arrive", table: "Views")
        case .calendarRadar: T("When appointments change", table: "Views")
        case .meetingPrep: T("30 min before appointments", table: "Views")
        case .reminderRadar: T("When reminders come due", table: "Views")
        case .followUp, .customCheck: T("When you choose", table: "Views")
        }
    }

    static func kindLabel(_ kind: ProactiveMatterKind) -> String {
        switch kind {
        case .morningBrief: T("Morning brief", table: "Views")
        case .watchedFile: T("New file", table: "Views")
        case .followUp: T("Follow-up", table: "Views")
        case .routine: T("Routine", table: "Views")
        case .calendarChange: T("Calendar change", table: "Views")
        case .reminderDue: T("Due reminder", table: "Views")
        }
    }

    static func kindIcon(_ kind: ProactiveMatterKind) -> String {
        switch kind {
        case .morningBrief: "sun.horizon"
        case .watchedFile: "folder"
        case .followUp: "arrow.turn.down.right"
        case .routine: "repeat"
        case .calendarChange: "calendar"
        case .reminderDue: "bell"
        }
    }

    static func outcomeLabel(_ outcome: RoutineRunOutcome) -> String {
        switch outcome {
        case .prepared: T("Prepared", table: "Views")
        case .silent: T("Nothing new", table: "Views")
        case .held: T("Waiting", table: "Views")
        case .skipped: T("Skipped", table: "Views")
        case .failed: T("Couldn’t run", table: "Views")
        }
    }

    /// "2 hours ago", "in 3 hours".
    static func relative(_ date: Date, now: Date = Date()) -> String {
        if abs(date.timeIntervalSince(now)) < 60 { return T("Just now", table: "Views") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "Thu 08:00", or "08:00" for today.
    static func dayAndTime(_ date: Date) -> String {
        // 24-hour like the routines' own sentences ("Every day at 18:00"), whatever the locale's clock.
        let parts = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: date)
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        if Calendar.autoupdatingCurrent.isDateInToday(date) { return time }
        return date.formatted(Date.FormatStyle(locale: locale).weekday(.abbreviated)) + " " + time
    }
}
