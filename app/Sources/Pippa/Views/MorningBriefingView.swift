import PippaCore
import SwiftUI

struct MorningBriefingLatestView: View {
    @ObservedObject var controller: MorningBriefingController
    var body: some View {
        ScrollView {
            if let result = controller.latest {
                MorningBriefingResultView(result: result, controller: controller).padding()
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Label(T("Morning overview", table: "MorningBriefing"), systemImage: "sun.horizon").font(.title2)
                    Text(T("Your next overview will appear here after the scheduled check. You can choose sources and times in Settings.", table: "MorningBriefing"))
                        .foregroundStyle(.secondary)
                    if let error = controller.errorText { Text(error).foregroundStyle(Theme.need) }
                }.padding(20)
            }
        }.frame(minWidth: 360, idealWidth: 440, minHeight: 220, idealHeight: 520)
    }
}

struct MorningBriefingSettingsView: View {
    @ObservedObject var controller: MorningBriefingController
    private let draftState = State(initialValue: MorningBriefingConfiguration())
    private let choosingState = State(initialValue: false)
    private let showResultState = State(initialValue: false)
    private var draft: MorningBriefingConfiguration {
        get { draftState.wrappedValue }
        nonmutating set { draftState.wrappedValue = newValue }
    }
    private var choosing: Bool {
        get { choosingState.wrappedValue }
        nonmutating set { choosingState.wrappedValue = newValue }
    }
    private var showResult: Bool {
        get { showResultState.wrappedValue }
        nonmutating set { showResultState.wrappedValue = newValue }
    }

    var body: some View {
        SettingsGroup {
            SettingsRow(title: T("Morning overview", table: "MorningBriefing"),
                        detail: T("Your chosen calendars and lists, in one quiet overview. Everything stays on this Mac.", table: "MorningBriefing"),
                        icon: "sun.horizon.fill", tint: Theme.accent, divider: false) {
                Toggle(T("Morning overview", table: "MorningBriefing"), isOn: Binding(get: { draft.enabled }, set: { enabled in
                    draft.enabled = enabled
                    if !enabled, controller.configuration.enabled { controller.pause() }
                })).labelsHidden()
            }
            if draft.enabled || !controller.configuration.sources.isEmpty || controller.errorText != nil {
              VStack(alignment: .leading, spacing: 12) {
                DatePicker(T("At", table: "MorningBriefing"), selection: Binding(get: {
                    Calendar.current.date(from: DateComponents(hour: draft.hour, minute: draft.minute)) ?? Date()
                }, set: { value in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: value)
                    draft.hour = parts.hour ?? 8; draft.minute = parts.minute ?? 0
                }), displayedComponents: .hourAndMinute)
                HStack(spacing: 4) {
                    ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                        Button {
                            if draft.weekdays.contains(day) { draft.weekdays.remove(day) } else { draft.weekdays.insert(day) }
                        } label: {
                            Text(Calendar.current.shortStandaloneWeekdaySymbols[day - 1]).font(.caption)
                                .padding(.horizontal, 6).padding(.vertical, 5)
                                .background(draft.weekdays.contains(day) ? Color.accentColor.opacity(0.18) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(draft.weekdays.contains(day) ? [.isSelected] : [])
                    }
                }
                Button { choosing = true; Task { await controller.loadSources() } } label: {
                    Label(draft.sources.isEmpty ? T("Choose calendars and lists", table: "MorningBriefing")
                          : T("Selected sources: %lld", table: "MorningBriefing", draft.sources.count), systemImage: "checklist")
                }
                if choosing { sourceChooser }
                Toggle(T("Let me know when it’s ready", table: "MorningBriefing"), isOn: Binding(get: { draft.notify }, set: { notify in
                    draft.notify = notify
                    if !notify, controller.configuration.notify {
                        var saved = controller.configuration; saved.notify = false; controller.save(saved)
                    }
                }))
                if draft.notify {
                    Button(T("Allow a quiet notification", table: "MorningBriefing")) { Task { await controller.requestNotifications() } }
                    if let note = controller.notificationNote { Text(note).font(.caption).foregroundStyle(.secondary) }
                }
            Text(T("Uses this Mac’s local time. Pippa checks while she is open and catches up once within four hours. No work happens while the Mac is off. Overdue tasks cover the past 30 days.", table: "MorningBriefing"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = controller.errorText { Text(error).font(.callout).foregroundStyle(Theme.need) }
            HStack {
                if draft != controller.configuration || controller.errorText != nil {
                    Button(T("Save", table: "MorningBriefing")) { controller.save(draft) }
                        .disabled(!controller.storageAvailable || (draft.enabled && !draft.isValid))
                }
                if controller.configuration.enabled {
                    Button(T("Pause", table: "MorningBriefing")) { controller.pause(); draft = controller.configuration }
                }
                if controller.latest != nil {
                    Button(T("Show overview", table: "MorningBriefing")) { showResult.toggle() }
                }
                Spacer(minLength: 0)
                if !controller.configuration.sources.isEmpty || controller.latest != nil {
                    Button(T("Remove", table: "MorningBriefing"), role: .destructive) { controller.delete(); draft = controller.configuration }
                }
            }
            if controller.running { ProgressView(T("Checking your selected sources…", table: "MorningBriefing")).controlSize(.small) }
            if showResult, let result = controller.latest { MorningBriefingResultView(result: result, controller: controller) }
              }.padding(.horizontal, 14).padding(.bottom, 14)
            }
        }
        .onAppear { draft = controller.configuration }
    }

    private var sourceChooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(T("Only selected sources are read. New calendars and lists stay unselected.", table: "MorningBriefing"))
                .font(.caption).foregroundStyle(.secondary)
            if controller.discovering { ProgressView().controlSize(.small) }
            ForEach(MorningBriefingSource.Kind.allCases, id: \.self) { kind in
                Text(kind == .calendar ? T("Calendars", table: "MorningBriefing") : T("Reminder lists", table: "MorningBriefing"))
                    .font(.subheadline.bold())
                if let failure = controller.sourceFailures[kind] {
                    Text(T("I couldn’t check this source. That doesn’t mean it’s empty.", table: "MorningBriefing"))
                        .font(.caption).foregroundStyle(.secondary)
                    if failure == .needsAccess || failure == .denied {
                        Button(failure == .denied ? T("Open privacy settings", table: "MorningBriefing") : T("Allow access", table: "MorningBriefing")) {
                            Task { await controller.requestAccess(kind) }
                        }
                    }
                }
                ForEach(controller.availableSources.filter { $0.kind == kind }) { source in
                    Toggle(source.title, isOn: Binding(get: { draft.sources.contains { $0.id == source.id } }, set: { selected in
                        draft.sources.removeAll { $0.id == source.id }
                        if selected { draft.sources.append(source) }
                    })).font(.callout)
                }
                let unavailable = draft.sources.filter { source in
                    source.kind == kind && !controller.availableSources.contains { $0.id == source.id }
                }
                ForEach(unavailable) { source in
                    HStack {
                        Text(T("%@ — currently unavailable", table: "MorningBriefing", source.title)).font(.caption)
                        Button(T("Remove", table: "MorningBriefing")) { draft.sources.removeAll { $0.id == source.id } }
                    }
                }
            }
            Button(T("Refresh sources", table: "MorningBriefing")) { Task { await controller.loadSources() } }
        }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct MorningBriefingResultView: View {
    let result: MorningBriefingResult
    @ObservedObject var controller: MorningBriefingController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(T("Your morning overview", table: "MorningBriefing"), systemImage: "sun.horizon")
                .font(.headline).accessibilityAddTraits(.isHeader)
            Text(formatted(result.occurrence.day.start, date: .full, time: .none)).font(.subheadline)
            if result.entries.isEmpty, result.issues.isEmpty {
                Text(T("No appointments today or due tasks in your selected sources.", table: "MorningBriefing"))
            }
            ForEach(Array(result.entries.enumerated()), id: \.offset) { _, entry in
                Button { controller.openSource(entry) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: entry.source.kind == .calendar ? "calendar" : "checklist")
                            .foregroundStyle(.secondary).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title.isEmpty ? T("Untitled", table: "MorningBriefing") : entry.title)
                                .font(.callout).multilineTextAlignment(.leading)
                            Text(label(entry) + " · " + entry.source.title).font(.caption).foregroundStyle(.secondary)
                            if entry.overlaps {
                                Text(T("Overlaps another appointment", table: "MorningBriefing")).font(.caption).foregroundStyle(Theme.need)
                            }
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                .help(entry.source.kind == .calendar ? T("Open in Calendar", table: "MorningBriefing") : T("Open Reminders", table: "MorningBriefing"))
            }
            ForEach(Array(result.issues.enumerated()), id: \.offset) { _, issue in
                VStack(alignment: .leading, spacing: 4) {
                    Text(issue.reason == .interrupted
                         ? T("This check was interrupted. Pippa will try again at the next scheduled time.", table: "MorningBriefing")
                         : T("Could not check: %@. This source may still have appointments or tasks.", table: "MorningBriefing", issue.source?.title ?? ""))
                        .font(.callout).foregroundStyle(Theme.need)
                    if let source = issue.source, issue.reason == .denied || issue.reason == .needsAccess {
                        Button(T("Review access", table: "MorningBriefing")) {
                            Task { await controller.loadSources(); await controller.requestAccess(source.kind) }
                        }
                    }
                }
            }
            if result.truncated { Text(T("Showing the first 100 items, with up to 60 from each source. Open the source app for the rest.", table: "MorningBriefing")).font(.caption) }
            Text(T("Checked at %@ · %@", table: "MorningBriefing", formatted(result.readAt, date: .none, time: .short), result.occurrence.timeZone))
                .font(.caption).foregroundStyle(.secondary)
            if !result.checkedSources.isEmpty {
                Text(result.checkedSources.map(\.title).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(14).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    private func label(_ entry: MorningBriefingEntry) -> String {
        if entry.source.kind == .reminders, entry.start < result.occurrence.day.start {
            return T("Overdue since %@", table: "MorningBriefing", formatted(entry.start, date: .medium, time: .none))
        }
        if entry.allDay {
            return entry.source.kind == .reminders ? T("Due today", table: "MorningBriefing") : T("All day", table: "MorningBriefing")
        }
        let start = formatted(entry.start, date: .none, time: .short)
        if let end = entry.end { return start + "–" + formatted(end, date: .none, time: .short) }
        return start
    }

    /// A saved overview continues to show its original local day and time after timezone travel.
    func formatted(_ value: Date, date: DateFormatter.Style, time: DateFormatter.Style) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = TimeZone(identifier: result.occurrence.timeZone) ?? TimeZone(secondsFromGMT: 0)!
        formatter.dateStyle = date; formatter.timeStyle = time
        return formatter.string(from: value)
    }
}
