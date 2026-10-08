import PippaCore
import SwiftUI

// Previews of the integrations (deadline handling) and the one sentence before
// the system prompt. The preview looks like the thing itself; nothing is written until "Add".

// MARK: - Editable spot

/// No field border, 1.5 pt underline in accentTint2; hover/focus: accentTint fill, accent underline.
struct EditableText: View {
    var placeholder: String
    @Binding var text: String
    var font: Font
    var color: Color = Theme.paperInk
    @FocusState private var focused: Bool
    private let hoverState = State(initialValue: false)

    var body: some View {
        let active = focused || hoverState.wrappedValue
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Theme.ink3), axis: .vertical)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(color)
            .focused($focused)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(active ? Theme.accentTint : .clear))
            .overlay(alignment: .bottom) {
                (active ? Theme.accent : Theme.accentTint2).frame(height: 1.5)
            }
            .onHover { hoverState.wrappedValue = $0 }
            .accessibilityLabel(placeholder)
    }
}

/// Date as an editable spot: a click opens a small calendar.
struct EditableDate: View {
    var date: DayDate
    var set: (Date) -> Void
    private let showState = State(initialValue: false)

    var body: some View {
        Button { showState.wrappedValue = true } label: {
            Text(GermanDate.short(date))
                .padding(.horizontal, 2)
                .overlay(alignment: .bottom) { Theme.accentTint2.frame(height: 1.5) }
        }
        .buttonStyle(.plain)
        .popover(isPresented: showState.projectedValue, arrowEdge: .bottom) {
            DatePicker("", selection: Binding(get: { GermanDate.date(date) }, set: { set($0); showState.wrappedValue = false }),
                       displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(10)
        }
        .accessibilityLabel(T("Change date (%@)", table: "Settings", GermanDate.long(date)))
    }
}

// MARK: - Fristen

struct DeadlinesContent: View {
    @Environment(\.embeddedWorkflow) private var embedded
    @ObservedObject var model: AppModel

    var body: some View {
        let items = model.deadlines
        VStack(alignment: .leading, spacing: 0) {
            PanelHead(title: T("Deadlines", table: "Settings"), meta: items.first?.source?.lastPathComponent, onClose: { model.collapse() })
            VStack(alignment: .leading, spacing: 0) {
                ResultTitle(text: Self.foundTitle(items.count))
                Well(padding: 12) {
                    AdaptiveScroll {
                        VStack(spacing: 10) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, d in
                                DeadlineCard(deadline: d) { model.prepareEntry(d, target: model.preferredEntryTarget) }
                                    .stagger(4 + i)
                            }
                        }
                        .padding(2)
                    }
                    .frame(maxHeight: embedded ? nil : 420)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 16)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            ActionBar {
                Button(T("Close", table: "Settings")) { model.collapse() }.pippa(.quiet)
            }
            TrustSill.readOnly
        }
        .workflowWidth(Theme.panelWidth)
    }

    private static func foundTitle(_ count: Int) -> String {
        if count == 1 { return T("Found one deadline.", table: "Settings") }
        return T("Found %lld deadlines.", table: "Settings", count)
    }
}

struct DeadlineCard: View {
    var deadline: Deadline
    var choose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if let date = deadline.date { DateTile(date: date) }
            VStack(alignment: .leading, spacing: 6) {
                Text(deadline.title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Theme.paperInk)
                    .fixedSize(horizontal: false, vertical: true)
                if deadline.certainty != .sure || deadline.date == nil {
                    Chip(text: chipText, kind: .need)
                }
                Text(T("“%@”", table: "Settings", deadline.quote))
                    .font(Fonts.serif(13))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Button { choose() } label: { Label(T("Add…", table: "Settings"), systemImage: "calendar.badge.plus") }
                    .pippa(.secondary)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper()
        .accessibilityElement(children: .contain)
    }

    private var chipText: String {
        if deadline.date == nil { return T("Date missing", table: "Settings") }
        return T("calculated, please check", table: "Settings")
    }
}

// MARK: - 9 Frist eintragen

struct EntryPreviewContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let entry = model.entryDraft {
            let reminder = entry.target == .reminder
            VStack(alignment: .leading, spacing: 0) {
                PanelHead(title: T("Add Deadline", table: "Settings"), meta: model.entryDeadline?.source?.deletingPathExtension().lastPathComponent, onClose: { model.escape() })
                VStack(alignment: .leading, spacing: 0) {
                    Segment(options: [(CalendarEntry.Target.reminder, T("Reminder", table: "Settings"), "bell"), (CalendarEntry.Target.calendar, T("Calendar", table: "Settings"), "calendar")],
                            selection: Binding(get: { entry.target }, set: { model.switchEntryTarget($0) }))
                        .stagger(0)
                    Well(padding: 12) {
                        if reminder { reminderPaper(entry) } else { calendarPaper(entry) }
                    }
                    .padding(.top, 14)
                    .stagger(4)
                    if let d = model.entryDeadline, d.date == nil || d.certainty != .sure {
                        HStack(spacing: 6) {
                            Chip(text: T("please check", table: "Settings"), kind: .need)
                            Text(Self.hint(for: d))
                                .font(Fonts.hint).foregroundStyle(Theme.need).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 10)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 14)
                ActionBar {
                    Button(T("No Thanks", table: "Settings")) { model.escape() }.pippa(.quiet)
                    Button { model.applyEntry() } label: { ApprovalLabel(title: T("Add", table: "Settings"), icon: reminder ? "bell" : "calendar") }
                        .pippa(.primary)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!model.canConfirmPreview)
                }
                TrustSill()
            }
            .workflowWidth(Theme.panelWidth)
        } else {
            Color.clear.frame(height: 10).workflowWidth(Theme.panelWidth)
        }
    }

    /// Note under the chip: missing date or how it was calculated.
    private static func hint(for deadline: Deadline) -> String {
        if deadline.date == nil { return T("There’s no date in the text. Choose one yourself.", table: "Settings") }
        return calcNote(deadline.note)
    }

    /// How it was calculated, without "Please check" (the chip says that).
    static func calcNote(_ note: String?) -> String {
        guard var n = note, !n.isEmpty else { return T("I calculated this date.", table: "Settings") }
        // German tails from the analysis and Pi, English ones with an English UI.
        for tail in [" Bitte prüfen.", " Bitte kurz prüfen.", "Bitte prüfen.", " Please check.", "Please check."] { n = n.replacingOccurrences(of: tail, with: "") }
        // "vor dem Vertragsende 31.12.2027" -> "vor Vertragsende (31.12.2027)"
        if let r = n.range(of: #"vor dem Vertragsende (\d{2}\.\d{2}\.\d{4})"#, options: .regularExpression) {
            let date = n[r].suffix(10)
            n.replaceSubrange(r, with: "vor Vertragsende (\(date))")
        }
        return n.trimmingCharacters(in: .whitespaces)
    }

    private var titleBinding: Binding<String> {
        Binding(get: { model.entryDraft?.title ?? "" }, set: { model.entryDraft?.title = $0 })
    }

    private func reminderPaper(_ e: CalendarEntry) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Circle().strokeBorder(Theme.fill3, lineWidth: 1.6).frame(width: 20, height: 20).padding(.top, 1)
                VStack(alignment: .leading, spacing: 6) {
                    EditableText(placeholder: T("Title", table: "Settings"), text: titleBinding, font: .system(size: 15, weight: .semibold))
                    HStack(spacing: 14) {
                        HStack(spacing: 5) {
                            Image(systemName: "calendar").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                            EditableDate(date: e.date) { model.setEntryDate($0) }
                        }
                        HStack(spacing: 5) {
                            Image(systemName: "bell").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                            Text(T("%@ at 9:00", table: "Settings", GermanDate.compact(e.alertDay)))
                        }
                    }
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink2)
                    if let q = model.entryDeadline?.quote, !q.isEmpty {
                        Text(T("“%@”", table: "Settings", q))
                            .font(Fonts.serif(13))
                            .foregroundStyle(Theme.ink2)
                            .lineSpacing(3)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)
            HStack {
                HStack(spacing: 6) { Circle().fill(Theme.accentFill).frame(width: 9, height: 9); Text(T("Reminders", table: "Settings")) }
                Spacer()
                if let src = model.entryDeadline?.source {
                    HStack(spacing: 6) { DocIcon(kind: DocIcon.kind(for: src), width: 13); Text(src.lastPathComponent).lineLimit(1).truncationMode(.middle) }
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.ink3)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Theme.hair.frame(height: 0.5) }
        }
        .paper()
    }

    private func calendarPaper(_ e: CalendarEntry) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: "\(e.date.day)").font(.system(size: 30, weight: .heavy, design: .rounded).monospacedDigit()).foregroundStyle(Theme.accent)
                Text(GermanDate.weekdays[GermanDate.weekday(e.date)]).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.paperInk)
                Spacer()
                EditableDate(date: e.date) { model.setEntryDate($0) }
                    .font(.system(size: 12)).foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            HStack(spacing: 10) {
                Text(T("all-\nday", table: "Settings")).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.ink3).frame(width: 40, alignment: .leading)
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(Theme.accentFill).frame(width: 7, height: 7).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        EditableText(placeholder: T("Title", table: "Settings"), text: titleBinding, font: .system(size: 13, weight: .semibold), color: Theme.accent)
                        Text(T("Alert: %@ at 9:00", table: "Settings", GermanDate.compact(e.alertDay))).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent.opacity(0.8))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.accentTint2))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .overlay(alignment: .top) { Theme.hair.frame(height: 0.5) }
            .overlay(alignment: .bottom) { Theme.hair.frame(height: 0.5) }
            VStack(spacing: 0) {
                ForEach(["9:00", "10:00", "11:00"], id: \.self) { h in
                    HStack(spacing: 0) {
                        Text(h).font(.system(size: 10.5)).foregroundStyle(Theme.ink3).frame(width: 50, alignment: .leading)
                        Theme.hair.frame(height: 0.5)
                    }
                    .frame(height: 26)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .paper()
    }
}

// MARK: - Erlaubnis

struct PermissionContent: View {
    @ObservedObject var model: AppModel
    var integration: Integration
    var denied: Bool

    /// Heading when access is denied.
    private var deniedTitle: String {
        switch integration {
        case .calendar: T("I’m not allowed into your calendar yet.", table: "Settings")
        case .reminders: T("I’m not allowed into your reminders yet.", table: "Settings")
        case .mail: T("I’m not allowed into Mail yet.", table: "Settings")
        }
    }

    /// One sentence before the system prompt.
    private var why: String {
        switch integration {
        case .reminders: T("To add the deadline to your reminders, I need your permission. Your Mac will ask you in a moment.", table: "Settings")
        case .calendar: T("To add the deadline to your calendar, I need your permission. Your Mac will ask you in a moment.", table: "Settings")
        case .mail: T("To read the selected mail, I need your permission. Your Mac will ask you in a moment. I read it; I send nothing without asking you.", table: "Settings")
        }
    }

    private var title: String {
        if denied { return deniedTitle }
        return T("Just a quick question.", table: "Settings")
    }

    private var lead: String {
        if denied { return T("No problem. If you like, you can allow it in System Settings under Privacy & Security.", table: "Settings") }
        return why
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHead(title: integration.appName, meta: nil, onClose: { model.collapse() })
            VStack(alignment: .leading, spacing: 8) {
                ResultTitle(text: title, large: false)
                Lead(text: lead)
                    .stagger(1)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            ActionBar {
                Button(T("Later", table: "Settings")) { model.collapse() }.pippa(.quiet)
                if denied {
                    Button(T("Open System Settings", table: "Settings")) { model.openSettings(for: integration) }
                        .pippa(.primary)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(T("Allow…", table: "Settings")) { model.requestAccess(integration) }
                        .pippa(.primary)
                        .keyboardShortcut(.defaultAction)
                }
            }
            TrustSill(right: .none)
        }
        .workflowWidth(Theme.workWidth)
    }
}
