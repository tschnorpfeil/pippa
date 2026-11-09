import AppKit
import PippaCore
import SwiftUI

/// What Pippa may use on this Mac, as macOS keeps it. Only read here, never asked: Pippa asks when she first needs it.
enum MacPermission: CaseIterable {
    case calendar, reminders, mail, photos, files

    var name: String {
        switch self {
        case .calendar: Integration.calendar.appName
        case .reminders: Integration.reminders.appName
        case .mail: Integration.mail.appName
        case .photos: PhotosLibrary.appName
        case .files: T("Files & Folders", table: "Settings")
        }
    }

    var symbol: String {
        switch self {
        case .calendar: "calendar"
        case .reminders: "checklist"
        case .mail: "envelope"
        case .photos: "photo.on.rectangle"
        case .files: "folder"
        }
    }

    /// The matching area in System Settings → Privacy & Security.
    var settingsURL: URL {
        switch self {
        case .calendar: Integration.calendar.settingsURL
        case .reminders: Integration.reminders.settingsURL
        case .mail: Integration.mail.settingsURL
        case .photos: PhotosLibrary.settingsURL
        case .files: PermissionRepairTarget.filesAndFolders.settingsURL
        }
    }

    /// The state without a system prompt. Calendar and Reminders: EventKit's authorization status. Mail: the Apple
    /// Events check with `ask: false`, only while Mail runs. Photos: PhotoKit's authorization status (it neither asks nor
    /// starts Photos). Files & Folders has no such check: nil.
    func read() async -> IntegrationAccess? {
        switch self {
        case .calendar: await SystemIntegrations().access(.calendar)
        case .reminders: await SystemIntegrations().access(.reminders)
        case .mail: await SystemIntegrations().access(.mail)
        case .photos: await PhotosLibrary.libraryAccess(ask: false)
        case .files: nil
        }
    }
}

@MainActor
final class PermissionStatus: ObservableObject {
    static let shared = PermissionStatus()
    @Published private(set) var access: [MacPermission: IntegrationAccess] = [:]
    /// False for snapshots: they show fixed states.
    private let live: Bool
    private var reading: Task<Void, Never>?

    init() { live = true }

    init(sample: [MacPermission: IntegrationAccess]) {
        live = false
        access = sample
    }

    /// Reads every state again; Mail last, it can take a few seconds.
    func refresh() {
        guard live else { return }
        reading?.cancel()
        reading = Task {
            for permission in [MacPermission.calendar, .reminders, .photos, .mail] {
                let value = await permission.read()
                guard !Task.isCancelled else { return }
                access[permission] = value
            }
        }
    }
}

/// Permissions: one row per kind of data, its state in words and a sign, and the way to change it.
struct PermissionSettings: View {
    @ObservedObject var status: PermissionStatus

    var body: some View {
        Form {
            Section {
                ForEach(MacPermission.allCases, id: \.self) { permission in
                    PermissionRow(permission: permission, access: status.access[permission])
                }
            } header: {
                Text(T("What Pippa may use on this Mac", table: "Settings"))
            } footer: {
                Text(T("Pippa only reads what you ask about. You can change this at any time in System Settings.", table: "Settings"))
                    .font(Typo.footnote).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { status.refresh() }
        // Back from System Settings: read again, but only while the window is open (a closed one keeps its pages).
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if SettingsWindow.shared.isVisible { status.refresh() }
        }
    }
}

private struct PermissionRow: View {
    var permission: MacPermission
    var access: IntegrationAccess?

    var body: some View {
        HStack(spacing: Space.l) {
            HStack(spacing: Space.l) {
                Image(systemName: permission.symbol)
                    .font(Typo.callout.weight(.medium)).foregroundStyle(Theme.accent)
                    .frame(width: 28, height: 28)
                    .background(Theme.accentTint, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(permission.name).font(Typo.callout)
                    state.font(Typo.footnote)
                }
            }
            .accessibilityElement(children: .combine)
            .layoutPriority(1)
            Spacer(minLength: Space.m)
            if permission == .files {
                Button(T("Open Files & Folders…", table: "Settings")) { NSWorkspace.shared.open(permission.settingsURL) }
            } else if access == .denied {
                Button(T("Allow in System Settings…", table: "Settings")) { NSWorkspace.shared.open(permission.settingsURL) }
            }
        }
        .padding(.vertical, Space.xxs)
    }

    @ViewBuilder private var state: some View {
        if permission == .files {
            sign("questionmark.circle", Theme.ink3, T("Pippa asks when she first needs a folder", table: "Settings"))
        } else {
            switch access {
            case nil:
                HStack(spacing: Space.xs) {
                    ProgressView().controlSize(.mini)
                    Text(T("Checking…", table: "Settings")).foregroundStyle(Theme.ink2)
                }
            case .granted?:
                sign("checkmark.circle.fill", Theme.ok, T("Allowed", table: "Settings"))
            case .notDetermined?:
                sign("questionmark.circle", Theme.ink3, T("Not asked yet – Pippa asks when she first needs it", table: "Settings"))
            case .denied?:
                sign("xmark.circle.fill", Theme.bad, T("Not allowed", table: "Settings"))
            case .unavailable?:
                sign("minus.circle", Theme.ink3, T("Pippa can check this while %@ is open", table: "Settings", permission.name))
            }
        }
    }

    /// A sign and the words for it: the color is never the only signal.
    private func sign(_ symbol: String, _ color: Color, _ text: String) -> some View {
        HStack(spacing: Space.xs) {
            Image(systemName: symbol).foregroundStyle(color).accessibilityHidden(true)
            Text(text).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}
