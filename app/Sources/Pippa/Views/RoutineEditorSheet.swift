import AppKit
import PippaCore
import SwiftUI

/// What the routine editor starts from: nothing, a sentence the person typed, or a routine to change.
enum RoutineEditorSeed: Identifiable, Sendable {
    case blank
    case fromText(String)
    case edit(ProactiveRoutine)

    var id: String {
        switch self {
        case .blank: "blank"
        case .fromText(let text): "text:" + text
        case .edit(let routine): "edit:" + routine.id.uuidString
        }
    }
}

/// Create or change a routine in plain sentences: what, when, how, where. Nothing is saved before "Save".
struct RoutineEditorSheet: View {
    let seed: RoutineEditorSeed
    var onDismiss: () -> Void
    @ObservedObject private var coordinator = ProactivityCoordinator.shared
    @ObservedObject private var setup = SetupModel.shared
    private let formState: State<RoutineForm>

    init(seed: RoutineEditorSeed, onDismiss: @escaping () -> Void) {
        self.seed = seed
        self.onDismiss = onDismiss
        formState = State(initialValue: RoutineForm(seed: seed))
    }

    private var form: RoutineForm { formState.wrappedValue }
    private var binding: Binding<RoutineForm> { formState.projectedValue }
    private var isEditing: Bool { form.existing != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    if !isEditing { templates }
                    whatSection
                    whenSection
                    howSection
                    whereSection
                }
                .padding(Space.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            preview
            Divider()
            footer
        }
        .font(Typo.callout)
        .foregroundStyle(Theme.ink)
        .frame(width: 540)
        .frame(minHeight: 520, idealHeight: 640)
        .background(Color(nsColor: Theme.chatTint))
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: Space.ml) {
            RoutineIcon(template: form.template)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(isEditing ? T("Edit Routine", table: "Views") : T("New Routine", table: "Views"))
                    .font(Typo.headline).foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(T("Pippa prepares it quietly and waits for you. Nothing is sent or changed by itself.", table: "Views"))
                    .font(Typo.footnote).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.xxl).padding(.vertical, Space.xl)
    }

    private static let templateChoices: [ProactiveRoutineTemplate] = [
        .customCheck, .morningBrief, .eveningPreview, .meetingPrep, .weeklyReview, .calendarRadar, .reminderRadar, .folderWatch,
    ]

    private var templates: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(T("Start from", table: "Views")).font(Typo.callout.weight(.semibold))
            FlowRow(spacing: Space.s, maxItemWidth: 220) {
                ForEach(Self.templateChoices, id: \.self) { template in
                    TemplateChip(template: template, selected: form.template == template) {
                        withAnimation(Theme.quick) { binding.wrappedValue.apply(template) }
                    }
                }
            }
        }
    }

    private var whatSection: some View {
        SettingsSection(title: T("What", table: "Views")) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(T("Name", table: "Views")).font(Typo.footnote).foregroundStyle(Theme.ink2)
                TextField(T("For example: Check my invoices", table: "Views"), text: binding.title)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(T("Name", table: "Views"))
            }
            .settingsBlock()
            if form.usesOwnWords {
                SettingsDivider()
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(T("What should Pippa check or prepare?", table: "Views")).font(Typo.footnote).foregroundStyle(Theme.ink2)
                    TextField(T("In your own words", table: "Views"), text: binding.instruction, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(3...6)
                        .accessibilityLabel(T("What should Pippa check or prepare?", table: "Views"))
                }
                .settingsBlock()
            }
        }
    }

    // MARK: When

    private var whenSection: some View {
        SettingsSection(title: T("When", table: "Views")) {
            if form.reactive { reactiveRows } else { scheduleRows }
        }
    }

    @ViewBuilder private var scheduleRows: some View {
        SettingsRow(title: T("Repeats", table: "Views")) {
            Picker(T("Repeats", table: "Views"), selection: binding.cadence) {
                ForEach(RoutineForm.Cadence.allCases, id: \.self) { cadence in Text(cadence.label).tag(cadence) }
            }
            .labelsHidden().fixedSize()
        }
        switch form.cadence {
        case .specificDays:
            SettingsDivider()
            weekdayRow
        case .monthly:
            SettingsDivider()
            SettingsRow(title: T("Day of the month", table: "Views")) {
                Picker(T("Day of the month", table: "Views"), selection: binding.dayOfMonth) {
                    ForEach(1...31, id: \.self) { day in Text(verbatim: "\(day).").tag(day) }
                }
                .labelsHidden().fixedSize()
            }
        case .interval:
            SettingsDivider()
            SettingsRow(title: T("How often", table: "Views")) {
                Picker(T("How often", table: "Views"), selection: binding.intervalMinutes) {
                    ForEach(RoutineForm.intervalChoices(including: form.intervalMinutes), id: \.self) { minutes in
                        Text(RoutineForm.durationLabel(minutes)).tag(minutes)
                    }
                }
                .labelsHidden().fixedSize()
            }
        case .once:
            SettingsDivider()
            SettingsRow(title: T("On", table: "Views")) {
                if !isEditing || form.onceDate >= Date() {
                    DatePicker(T("On", table: "Views"), selection: binding.onceDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden().datePickerStyle(.field)
                        .environment(\.locale, RoutineUI.locale)
                } else {
                    DatePicker(T("On", table: "Views"), selection: binding.onceDate, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden().datePickerStyle(.field)
                        .environment(\.locale, RoutineUI.locale)
                }
            }
        case .daily, .weekdays:
            EmptyView()
        }
        if form.cadence != .interval && form.cadence != .once {
            SettingsDivider()
            SettingsRow(title: T("At", table: "Views")) {
                DatePicker(T("At", table: "Views"), selection: binding.timeOfDay, displayedComponents: .hourAndMinute)
                    .labelsHidden().datePickerStyle(.field)
                    .environment(\.locale, RoutineUI.locale)
            }
        }
    }

    private var weekdayRow: some View {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = RoutineUI.locale
        let names = calendar.shortStandaloneWeekdaySymbols
        // Monday first, as people read a week. Calendar numbering: 1 = Sunday.
        let order = [2, 3, 4, 5, 6, 7, 1]
        return HStack(spacing: Space.xs) {
            ForEach(order, id: \.self) { day in
                let on = form.weekdays.contains(day)
                Button {
                    if on {
                        if binding.wrappedValue.weekdays.count > 1 { binding.wrappedValue.weekdays.remove(day) }
                    } else {
                        binding.wrappedValue.weekdays.insert(day)
                    }
                } label: {
                    Text(names[day - 1].trimmingCharacters(in: CharacterSet(charactersIn: ".")))
                        .font(Typo.footnote.weight(.medium))
                        .foregroundStyle(on ? Color.white : Theme.ink)
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background(on ? Theme.accentFill : Theme.fill2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(calendar.standaloneWeekdaySymbols[day - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .settingsBlock()
    }

    @ViewBuilder private var reactiveRows: some View {
        SettingsRow(title: form.event.label) { EmptyView() }
        SettingsDivider()
        switch form.event {
        case .folder:
            SettingsRow(title: T("Folder", table: "Views"),
                        detail: form.folderPath.isEmpty ? T("Choose the folder Pippa should watch.", table: "Views")
                                                        : URL(fileURLWithPath: form.folderPath).lastPathComponent) {
                Button(form.folderPath.isEmpty ? T("Choose Folder…", table: "Views") : T("Change…", table: "Views")) {
                    if let picked = coordinator.chooseFolderForRoutine() {
                        binding.wrappedValue.folderPath = picked.path
                        binding.wrappedValue.folderBookmark = picked.bookmark
                    }
                }
                .pippa(.secondary)
            }
        case .calendarChange:
            SettingsRow(title: T("Look ahead", table: "Views")) {
                Picker(T("Look ahead", table: "Views"), selection: binding.lookaheadHours) {
                    ForEach(RoutineForm.lookaheadChoices(including: form.lookaheadHours), id: \.self) { hours in
                        Text(RoutineForm.lookaheadLabel(hours)).tag(hours)
                    }
                }
                .labelsHidden().fixedSize()
            }
        case .upcomingMeeting:
            SettingsRow(title: T("How long before", table: "Views")) {
                Picker(T("How long before", table: "Views"), selection: binding.leadMinutes) {
                    ForEach(RoutineForm.leadChoices(including: form.leadMinutes), id: \.self) { minutes in
                        Text(RoutineForm.durationLabel(minutes)).tag(minutes)
                    }
                }
                .labelsHidden().fixedSize()
            }
        case .reminderDue:
            SettingsRow(title: T("Overdue reminders and ones due today", table: "Views"),
                        detail: T("Reads only the Reminders you already allowed.", table: "Views")) { EmptyView() }
        }
    }

    // MARK: How and where

    @ViewBuilder private var howSection: some View {
        if form.usesOwnWords {
            SettingsSection(title: T("How", table: "Views")) {
                ModeRow(title: T("Prepare for chat", table: "Views"),
                        detail: T("Places a ready card in For You. Runs only when you open it.", table: "Views"),
                        selected: form.executionMode != .localAIReadOnly) {
                    binding.wrappedValue.executionMode = .prepareForChat
                }
                SettingsDivider()
                ModeRow(title: T("Check quietly with local AI (read-only)", table: "Views"),
                        detail: setup.isReady
                            ? T("Uses the AI on this Mac to check files, mail, calendar or reminders. Read-only — never sends, changes files or goes online.", table: "Views")
                            : T("Set up Pippa’s local AI in Settings to use this.", table: "Views"),
                        selected: form.executionMode == .localAIReadOnly) {
                    binding.wrappedValue.executionMode = .localAIReadOnly
                }
                .disabled(!setup.isReady)
            }
        } else {
            SettingsSection(title: T("How", table: "Views")) {
                SettingsRow(title: T("Runs directly on your Mac without AI.", table: "Views")) { EmptyView() }
            }
        }
    }

    private var whereSection: some View {
        SettingsSection(title: T("Where", table: "Views")) {
            Picker(T("Where", table: "Views"), selection: binding.deliveryMode) {
                Text(T("For You & Pippa Island", table: "Views")).tag(RoutineDeliveryMode.islandAndDesk)
                Text(T("Quietly in For You only", table: "Views")).tag(RoutineDeliveryMode.deskOnly)
            }
            .pickerStyle(.radioGroup).labelsHidden()
            .settingsBlock()
            SettingsDivider()
            SettingsRow(title: T("Only when something is new", table: "Views"),
                        detail: T("Stays quiet when nothing changed since last time.", table: "Views")) {
                Toggle(T("Only when something is new", table: "Views"), isOn: binding.onlyWhenNew)
                    .labelsHidden().toggleStyle(.switch)
            }
        }
    }

    /// The routine in one sentence, as it will run.
    private var preview: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Image(systemName: "clock").font(Typo.footnote).foregroundStyle(Theme.accent).accessibilityHidden(true)
            Text(form.trigger.humanSummary(language: RoutineUI.language)
                 + " · "
                 + (form.deliveryMode == .deskOnly ? T("quietly in For You", table: "Views") : T("in For You and Pippa Island", table: "Views")))
                .font(Typo.footnote.weight(.medium)).foregroundStyle(Theme.ink2).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.xxl).padding(.vertical, Space.ml)
        .background(Theme.fill)
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack(spacing: Space.m) {
            if let existing = form.existing {
                Button(T("Delete", table: "Views"), role: .destructive) {
                    coordinator.deleteRoutine(existing.id)
                    onDismiss()
                }
                .pippa(.quiet).foregroundStyle(Theme.bad)
            }
            Spacer(minLength: 0)
            Button(T("Cancel", table: "Views")) { onDismiss() }
                .keyboardShortcut(.cancelAction)
                .pippa(.secondary)
            Button(isEditing ? T("Save", table: "Views") : T("Add Routine", table: "Views")) { save() }
                .keyboardShortcut(.defaultAction)
                .pippa(.primary)
                .disabled(!form.canSave)
        }
        .padding(.horizontal, Space.xxl).padding(.vertical, Space.l)
    }

    private func save() {
        guard form.canSave else { return }
        let routine = form.routine(language: RoutineUI.language)
        if form.existing != nil { coordinator.updateRoutine(routine) } else { coordinator.createRoutine(routine) }
        onDismiss()
    }
}

// MARK: - Pieces

private struct TemplateChip: View {
    var template: ProactiveRoutineTemplate
    var selected: Bool
    var action: () -> Void
    private let hoverState = State(initialValue: false)

    var body: some View {
        Button(action: action) {
            Label(RoutineUI.title(template), systemImage: RoutineUI.icon(template))
                .font(Typo.footnote.weight(.medium))
                .foregroundStyle(selected ? Theme.accent : Theme.ink)
                .lineLimit(1)
                .padding(.horizontal, Space.ml).frame(height: 28)
                .background(selected ? Theme.accentTint : (hoverState.wrappedValue ? Theme.fill3 : Theme.fill2), in: Capsule())
                .overlay { if selected { Capsule().strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(Theme.quick) { hoverState.wrappedValue = hovering } }
        .help(RoutineUI.explanation(template))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One of two ways a routine can run: a radio mark, its name and what it means.
private struct ModeRow: View {
    var title: String
    var detail: String
    var selected: Bool
    var choose: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: Space.ml) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(Typo.body).foregroundStyle(selected ? Theme.accent : Theme.ink3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(title).font(Typo.callout).foregroundStyle(enabled ? Theme.ink : Theme.ink3)
                    Text(detail).font(Typo.footnote).foregroundStyle(Theme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .settingsBlock()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - The form's values

/// Everything the sheet edits, turned into a `ProactiveRoutine` only on save.
struct RoutineForm {
    enum Cadence: CaseIterable, Hashable {
        case daily, weekdays, specificDays, monthly, interval, once

        @MainActor var label: String {
            switch self {
            case .daily: T("Every day", table: "Views")
            case .weekdays: T("Weekdays", table: "Views")
            case .specificDays: T("Specific days", table: "Views")
            case .monthly: T("Monthly", table: "Views")
            case .interval: T("Every few hours", table: "Views")
            case .once: T("Once", table: "Views")
            }
        }
    }

    enum Event: CaseIterable, Hashable {
        case folder, calendarChange, upcomingMeeting, reminderDue

        @MainActor var label: String {
            switch self {
            case .folder: T("New files in a folder", table: "Views")
            case .calendarChange: T("Appointments change", table: "Views")
            case .upcomingMeeting: T("Before an appointment", table: "Views")
            case .reminderDue: T("Reminders come due", table: "Views")
            }
        }
    }

    var existing: ProactiveRoutine?
    var template: ProactiveRoutineTemplate = .customCheck
    var title = ""
    var instruction = ""
    var reactive = false
    var cadence: Cadence = .daily
    var hour = 9
    var minute = 0
    var weekdays: Set<Int> = [2]
    var dayOfMonth = 1
    var intervalMinutes = 120
    var onceDate = Date().addingTimeInterval(3600)
    var event: Event = .folder
    var folderPath = ""
    var folderBookmark: Data?
    var lookaheadHours = 48
    var leadMinutes = 30
    var executionMode: RoutineExecutionMode = .prepareForChat
    var deliveryMode: RoutineDeliveryMode = .islandAndDesk
    var onlyWhenNew = true

    @MainActor init(seed: RoutineEditorSeed) {
        switch seed {
        case .blank:
            apply(.customCheck)
        case .fromText(let text):
            if let draft = RoutineUI.parse(text) {
                template = draft.template
                title = draft.title
                instruction = draft.instruction
                load(draft.trigger)
                executionMode = draft.template.isBuiltIn ? .deterministic : .prepareForChat
                deliveryMode = [.calendarRadar, .meetingPrep, .reminderRadar].contains(draft.template) ? .deskOnly : .islandAndDesk
            } else {
                apply(.customCheck)
                instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        case .edit(let routine):
            existing = routine
            template = routine.template
            title = routine.title
            instruction = routine.instruction
            load(routine.trigger)
            executionMode = routine.executionMode
            deliveryMode = routine.deliveryMode
            onlyWhenNew = routine.onlyWhenNew
        }
    }

    /// The person's own words matter only for their own routines; built-in ones have fixed builders.
    var usesOwnWords: Bool { !template.isBuiltIn }

    var canSave: Bool {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if reactive && event == .folder && folderPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if !reactive && cadence == .specificDays && weekdays.isEmpty { return false }
        return true
    }

    /// Fills sensible values for a template, like the starter routines.
    @MainActor mutating func apply(_ template: ProactiveRoutineTemplate) {
        self.template = template
        let language = RoutineUI.language
        if template == .folderWatch {
            let starter = ProactiveRoutine.watchedFolder(path: folderPath, language: language)
            title = starter.title
            instruction = starter.instruction
            reactive = true
            event = .folder
            executionMode = .deterministic
            deliveryMode = .islandAndDesk
        } else if let starter = ProactiveRoutine.starterPacks(language: language).first(where: { $0.template == template }) {
            title = starter.title
            instruction = starter.instruction
            load(starter.trigger)
            executionMode = .deterministic
            deliveryMode = starter.deliveryMode
        } else {
            title = ""
            instruction = ""
            reactive = false
            cadence = .daily
            hour = 9; minute = 0
            executionMode = .prepareForChat
            deliveryMode = .islandAndDesk
        }
    }

    private mutating func load(_ trigger: ProactiveTrigger) {
        switch trigger {
        case .schedule(let schedule):
            reactive = false
            switch schedule {
            case .daily(let h, let m): cadence = .daily; hour = h; minute = m
            case .weekdays(let h, let m): cadence = .weekdays; hour = h; minute = m
            case .weekly(let days, let h, let m):
                if days == ProactiveSchedule.workWeek { cadence = .weekdays } else if days == Array(1...7) { cadence = .daily } else { cadence = .specificDays }
                weekdays = Set(days); hour = h; minute = m
            case .monthly(let day, let h, let m): cadence = .monthly; dayOfMonth = day; hour = h; minute = m
            case .interval(let minutes): cadence = .interval; intervalMinutes = minutes
            case .once(let date): cadence = .once; onceDate = date
            }
        case .folder(let path, let bookmark):
            reactive = true; event = .folder; folderPath = path; folderBookmark = bookmark
        case .calendarChange(let hours):
            reactive = true; event = .calendarChange; lookaheadHours = hours
        case .upcomingMeeting(let minutes):
            reactive = true; event = .upcomingMeeting; leadMinutes = minutes
        case .reminderDue:
            reactive = true; event = .reminderDue
        }
    }

    var trigger: ProactiveTrigger {
        if reactive {
            switch event {
            case .folder: return .folder(path: folderPath, bookmark: folderBookmark)
            case .calendarChange: return .calendarChange(lookaheadHours: lookaheadHours)
            case .upcomingMeeting: return .upcomingMeeting(leadMinutes: leadMinutes)
            case .reminderDue: return .reminderDue
            }
        }
        switch cadence {
        case .daily: return .schedule(.daily(hour: hour, minute: minute))
        case .weekdays: return .schedule(.weekdays(hour: hour, minute: minute))
        case .specificDays: return .schedule(.weekly(weekdays: Array(weekdays).sorted(), hour: hour, minute: minute))
        case .monthly: return .schedule(.monthly(day: dayOfMonth, hour: hour, minute: minute))
        case .interval: return .schedule(.interval(minutes: intervalMinutes))
        case .once: return .schedule(.once(at: onceDate))
        }
    }

    /// The time of day as a `Date` today, for the time picker.
    var timeOfDay: Date {
        get { Calendar.autoupdatingCurrent.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date() }
        set {
            let parts = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: newValue)
            hour = parts.hour ?? hour
            minute = parts.minute ?? minute
        }
    }

    func routine(language: String) -> ProactiveRoutine {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode: RoutineExecutionMode = template.isBuiltIn ? .deterministic
            : (executionMode == .localAIReadOnly ? .localAIReadOnly : .prepareForChat)
        if var routine = existing {
            routine.title = cleanTitle
            routine.instruction = cleanInstruction.isEmpty ? routine.instruction : cleanInstruction
            routine.trigger = trigger
            routine.executionMode = mode
            routine.deliveryMode = deliveryMode
            routine.onlyWhenNew = onlyWhenNew
            return routine
        }
        return ProactiveRoutine(
            title: cleanTitle,
            instruction: cleanInstruction.isEmpty ? cleanTitle : cleanInstruction,
            template: template,
            trigger: trigger,
            executionMode: mode,
            deliveryMode: deliveryMode,
            enabled: true,
            onlyWhenNew: onlyWhenNew,
            builtInKey: nil,
            createdAt: Date()
        )
    }

    static func intervalChoices(including current: Int) -> [Int] {
        Array(Set([15, 30, 60, 120, 240, current])).sorted()
    }

    static func leadChoices(including current: Int) -> [Int] {
        Array(Set([15, 30, 60, current])).sorted()
    }

    static func lookaheadChoices(including current: Int) -> [Int] {
        Array(Set([24, 48, 168, current])).sorted()
    }

    @MainActor static func durationLabel(_ minutes: Int) -> String {
        if minutes % 60 == 0 {
            let hours = minutes / 60
            return hours == 1 ? T("1 hour", table: "Views") : T("%lld hours", table: "Views", hours)
        }
        return T("%lld min", table: "Views", minutes)
    }

    @MainActor static func lookaheadLabel(_ hours: Int) -> String {
        if hours % 24 == 0 && hours >= 72 { return T("%lld days", table: "Views", hours / 24) }
        return T("%lld h", table: "Views", hours)
    }
}

extension ProactiveRoutineTemplate {
    /// Built-in templates have their own builders on this Mac; follow-ups and custom checks use the person's words.
    var isBuiltIn: Bool { self != .customCheck && self != .followUp }
}
