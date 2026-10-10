import AppKit
import PippaCore
import SwiftUI

// "What Pippa may": one row per macOS permission with its own Allow button, in onboarding and in Settings
// ("Permissions"). No chain of dialogs: each one is asked only when the person presses its button, because a dialog
// that was declined never comes back by itself. Full Disk Access is left out on purpose (no dialog for it, and Pippa's
// shell would inherit it).

@MainActor
final class PermissionsModel: ObservableObject {
    let desk: any PermissionDesk
    @Published private(set) var rows: [MacPermission] = []
    @Published private(set) var states: [MacPermission: PermissionState] = [:]
    @Published private(set) var asking: MacPermission?
    /// The onboarding page is still to come (once, after "Load"). Never in recordings unless they ask for it.
    @Published var onboardingPending: Bool

    private static let doneKey = "onboarding.permissions.done"

    init(desk: any PermissionDesk) {
        self.desk = desk
        // Known right away (no dialog, no waiting), so the page has its final height when the panel measures it.
        rows = MacPermission.allCases.filter { desk.applies($0) }
        onboardingPending = DevSnapshot.directory == nil && !UserDefaults.standard.bool(forKey: Self.doneKey)
    }

    func rows(in group: MacPermission.Group) -> [MacPermission] { rows.filter { $0.group == group } }

    /// Reads every state without showing a dialog.
    func refresh() async {
        let shown = MacPermission.allCases.filter { desk.applies($0) }
        var found: [MacPermission: PermissionState] = [:]
        for permission in shown { found[permission] = await desk.state(permission) }
        rows = shown
        // A row being asked right now keeps its spinner; its answer arrives with `allow`.
        if let asking { found[asking] = states[asking] }
        states = found
    }

    /// The person pressed this row's Allow: its dialog(s) only, nothing else.
    func allow(_ permission: MacPermission) {
        guard asking == nil else { return }
        if states[permission] == .denied { return openSettings(permission) }
        asking = permission
        Task {
            let result = await desk.request(permission)
            states[permission] = result
            asking = nil
            NSApp.activate()
            await refresh()
        }
    }

    func openSettings(_ permission: MacPermission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        onboardingPending = false
    }
}

extension AppModel {
    private static var permissionsModel: PermissionsModel?

    /// Shared by onboarding and Settings. PIPPA_DEMO=1 answers with fixed states and never touches the real Mac.
    var permissions: PermissionsModel {
        if let existing = Self.permissionsModel { return existing }
        let engine = self.engine
        let desk: any PermissionDesk = engine is StubEngine
            ? DemoPermissions()
            : SystemPermissions(access: { await engine.integrationAccess($0) }, request: { await engine.requestIntegrationAccess($0) })
        let made = PermissionsModel(desk: desk)
        Self.permissionsModel = made
        return made
    }
}

// MARK: - Rows

extension MacPermission {
    var title: String {
        switch self {
        case .folders: T("Desktop, Documents and Downloads", table: "Settings")
        case .iCloudDrive: T("iCloud Drive", table: "Settings")
        case .oneDrive: "OneDrive"
        case .dropbox: "Dropbox"
        case .googleDrive: "Google Drive"
        case .externalDrives: T("External drives", table: "Settings")
        case .calendar: T("Calendar", table: "Settings")
        case .reminders: T("Reminders", table: "Settings")
        case .contacts: T("Contacts", table: "Settings")
        case .photos: T("Photos", table: "Settings")
        case .mail: T("Mail", table: "Settings")
        case .notes: T("Notes", table: "Settings")
        case .excel: T("Excel", table: "Settings")
        }
    }

    /// What it is for, in one plain sentence.
    var purpose: String {
        switch self {
        case .folders: T("So Pippa can find, read and tidy your files when you ask.", table: "Settings")
        case .iCloudDrive: T("For the files you keep in iCloud.", table: "Settings")
        case .oneDrive, .dropbox, .googleDrive: T("For the files you keep in %@.", table: "Settings", title)
        case .externalDrives: T("For USB sticks and external disks.", table: "Settings")
        case .calendar: T("So Pippa can read your appointments and add deadlines.", table: "Settings")
        case .reminders: T("So Pippa can add deadlines as reminders.", table: "Settings")
        case .contacts: T("So Pippa can find addresses and phone numbers when you ask.", table: "Settings")
        case .photos: T("So Pippa can find your photos when you ask, like “photos of my bike”.", table: "Settings")
        case .mail: T("So Pippa can read the selected mail and prepare a reply. Nothing is sent.", table: "Settings")
        case .notes: T("So Pippa can find and add notes when you ask.", table: "Settings")
        case .excel: T("So Pippa can read the table you’re looking at.", table: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .folders: "folder.fill"
        case .iCloudDrive: "icloud.fill"
        case .oneDrive, .dropbox, .googleDrive: "cloud.fill"
        case .externalDrives: "externaldrive.fill"
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .contacts: "person.crop.circle.fill"
        case .photos: "photo.fill"
        case .mail: "envelope.fill"
        case .notes: "note.text"
        case .excel: "tablecells.fill"
        }
    }

    var tint: Color {
        switch self {
        case .folders: .blue
        case .iCloudDrive: .cyan
        case .oneDrive: .blue
        case .dropbox: .indigo
        case .googleDrive: .green
        case .externalDrives: .gray
        case .calendar: .red
        case .reminders: .orange
        case .contacts: .brown
        case .photos: .pink
        case .mail: .blue
        case .notes: .yellow
        case .excel: .green
        }
    }
}

/// One row: picture, name, what for, and on the right the state or its own Allow button.
struct PermissionRow: View {
    @ObservedObject var permissions: PermissionsModel
    var permission: MacPermission
    var divider: Bool

    var body: some View {
        let state = permissions.states[permission]
        SettingsRow(title: permission.title, detail: detail(state), icon: permission.symbol, tint: permission.tint, divider: divider) {
            trailing(state).fixedSize()
        }
        .accessibilityElement(children: .contain)
    }

    /// The state or the button, never squeezed by a long explanation.
    @ViewBuilder private func trailing(_ state: PermissionState?) -> some View {
            if permissions.asking == permission {
                ProgressView().controlSize(.small).frame(width: 34, height: 34)
                    .accessibilityLabel(T("Your Mac is asking you", table: "Settings"))
            } else {
                switch state {
                case .granted?:
                    StatusBadge(text: T("Allowed", table: "Settings"), symbol: "checkmark", ink: Theme.ok, fill: Theme.okTint)
                case .denied?:
                    Button(T("Allow…", table: "Settings")) { permissions.openSettings(permission) }
                        .pippa(.secondary)
                        .accessibilityHint(T("Opens System Settings.", table: "Settings"))
                case .unavailable(_)?:
                    StatusBadge(text: T("Will ask", table: "Settings"), symbol: nil, ink: Theme.ink2, fill: Theme.fill2)
                case .notAsked?:
                    Button(T("Allow", table: "Settings")) { permissions.allow(permission) }
                        .pippa(.secondary)
                        .disabled(permissions.asking != nil)
                        .accessibilityLabel(T("Allow %@", table: "Settings", permission.title))
                case nil:
                    EmptyView()
                }
            }
    }

    private func detail(_ state: PermissionState?) -> String {
        switch state {
        case .denied?: T("You said no. “Allow…” opens System Settings, where you can turn it on.", table: "Settings")
        case .unavailable(let why)?: why
        default: permission.purpose
        }
    }
}

/// The rows of one group (or all of them), each with its own button.
struct PermissionRows: View {
    @ObservedObject var permissions: PermissionsModel
    var group: MacPermission.Group?

    var body: some View {
        let rows = group.map { permissions.rows(in: $0) } ?? permissions.rows
        ForEach(Array(rows.enumerated()), id: \.element) { index, permission in
            PermissionRow(permissions: permissions, permission: permission, divider: index > 0)
        }
    }
}

/// Refreshes the states when shown and when the person comes back from System Settings.
private struct PermissionRefresh: ViewModifier {
    @ObservedObject var permissions: PermissionsModel
    func body(content: Content) -> some View {
        content
            .task { await permissions.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await permissions.refresh() }
            }
    }
}

/// Settings: one group "Permissions" with every row.
struct PermissionSettingsGroup: View {
    @ObservedObject var permissions: PermissionsModel
    var body: some View {
        SettingsGroup(title: T("Permissions", table: "Settings"),
                      note: T("Your Mac asks you once for each. You can change it later in System Settings.", table: "Settings")) {
            PermissionRows(permissions: permissions, group: nil)
        }
        .modifier(PermissionRefresh(permissions: permissions))
    }
}

/// Onboarding: files and apps in two groups.
struct PermissionGroups: View {
    @ObservedObject var permissions: PermissionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !permissions.rows(in: .files).isEmpty {
                SettingsGroup(title: T("Your files", table: "Settings")) { PermissionRows(permissions: permissions, group: .files) }
            }
            if !permissions.rows(in: .apps).isEmpty {
                SettingsGroup(title: T("Your apps", table: "Settings")) { PermissionRows(permissions: permissions, group: .apps) }
            }
        }
        .modifier(PermissionRefresh(permissions: permissions))
    }
}

// MARK: - Onboarding

/// Once, right after "Load": while the AI loads, the person decides what Pippa may. "Continue" goes on to the loading
/// view (or straight to "I'm ready").
struct PermissionsOnboardingPage: View {
    @ObservedObject var permissions: PermissionsModel
    @ObservedObject var setup: PiSetupController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                MarkSlot(size: 32)
                Text(T("What Pippa may do", table: "Settings"))
                    .font(Fonts.resultL)
                    .foregroundStyle(Theme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            .padding(.top, 22)
            .padding(.horizontal, 24)
            .stagger(0)
            Text(subtitle)
                .font(Fonts.hint)
                .foregroundStyle(Theme.ink2)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
                .padding(.horizontal, 24)
                .stagger(1)
            // Only the rows scroll: the heading and "Continue" always stay in view, also on a small screen.
            ScrollView(.vertical) {
                PermissionGroups(permissions: permissions)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
            .scrollIndicators(.automatic)
            .frame(height: Self.listHeight(rows: permissions.rows.count))
            .overlay(alignment: .top) { Theme.hair.frame(height: 0.5) }
            .overlay(alignment: .bottom) { Theme.hair.frame(height: 0.5) }
            .stagger(2)
            ActionBar {
                Button(T("Continue", table: "Settings")) { permissions.finishOnboarding() }
                    .pippa(.primary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .workflowWidth(Theme.wideWidth)
        .overlay(alignment: .topTrailing) {
            CloseButton { setup.later() }.padding(12)
        }
    }

    private var subtitle: String {
        var text = T("Your Mac asks you once for each. You can change it later in Settings.", table: "Settings")
        if case .downloading(let progress, _) = setup.state {
            text += "\n" + T("Pippa keeps loading her AI meanwhile · %lld %%", table: "Settings", Int((progress * 100).rounded()))
        }
        return text
    }

    /// All rows if they fit, otherwise what the panel has room for (heading, subtitle and "Continue" take about 230 pt).
    static func listHeight(rows: Int) -> CGFloat {
        let wanted = CGFloat(max(rows, 1)) * 58 + 92
        return max(140, min(wanted, ShellController.panelRoom - 230))
    }

    /// After "Load" (or with the AI already here), as long as the page has not been finished once.
    static func shows(_ permissions: PermissionsModel, _ setup: PiSetupController) -> Bool {
        guard permissions.onboardingPending else { return false }
        switch setup.state {
        case .downloading, .ready: return true
        default: return false
        }
    }
}
