import AppKit
import PippaCore
import ServiceManagement
import SwiftUI

/// General: the shortcut, opening at login, Pippa Island, moving to Applications.
struct GeneralSettings: View {
    @ObservedObject var island = Island.shared
    @ObservedObject private var hotkeys = HotkeyCenter.shared
    private let hotkeyState = State(initialValue: Hotkey.current)
    private let opensAtLoginState = State(initialValue: SMAppService.mainApp.status == .enabled)
    /// Asked once: where the app lies does not change while it runs.
    private static let outsideApplications = Bundle.main.bundleURL.pathExtension == "app" && !AppLocation.isInApplications()

    var body: some View {
        SettingsScroll {
            SettingsSection {
                SettingsRow(title: T("Shortcut", table: "App")) {
                    Picker(T("Shortcut", table: "App"), selection: hotkeyState.projectedValue) {
                        ForEach(Hotkey.allCases) { Text($0.display).tag($0) }
                    }
                    .labelsHidden()
                    .onChange(of: hotkeyState.wrappedValue) { _, value in Hotkey.current = value; HotkeyCenter.shared.apply(value) }
                }
                if hotkeys.mainTaken {
                    Text(HotkeyCenter.takenText)
                        .font(Typo.footnote).foregroundStyle(Theme.need)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Space.xl).padding(.bottom, Space.ml)
                }
                SettingsDivider()
                SettingsRow(title: T("Open at login", table: "App")) {
                    Toggle(T("Open at login", table: "App"), isOn: opensAtLoginState.projectedValue).labelsHidden().toggleStyle(.switch)
                        .onChange(of: opensAtLoginState.wrappedValue) { _, on in
                            if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                            opensAtLoginState.wrappedValue = SMAppService.mainApp.status == .enabled
                        }
                }
            }
            SettingsSection {
                SettingsRow(title: T("Show Pippa Island", table: "Settings"),
                            detail: T("Sits at the top of the screen, shows what Pippa is doing and takes a quick question.", table: "Settings")) {
                    Toggle(T("Show Pippa Island", table: "Settings"), isOn: $island.isShown).labelsHidden().toggleStyle(.switch)
                }
            }
            CalmNoticeSettings()
            if Self.outsideApplications {
                SettingsSection {
                    SettingsRow(title: T("Pippa isn’t in Applications", table: "App"),
                                detail: T("From there she stays up to date by herself and can open at login.", table: "App")) {
                        Button(T("Move to Applications…", table: "App")) { AppMover.moveNow() }.pippa(.secondary)
                    }
                }
            }
        }
    }
}

/// Calm notices (opt-in proactivity): off by default; switched on, the morning brief, one watched folder and quiet
/// hours. Everything below the switch shows only while it is on.
struct CalmNoticeSettings: View {
    @ObservedObject private var coordinator = ProactivityCoordinator.shared

    var body: some View {
        let settings = coordinator.settings
        SettingsSection(title: T("Calm notices", table: "Settings"),
                        footer: T("Off unless you turn it on. At most two a day, shown quietly in Pippa Island, never on top of your work. Pippa never wakes her local AI in the background and waits during quiet hours, a Focus and while the screen is locked.", table: "Settings")) {
            SettingsRow(title: T("Calm notices", table: "Settings"),
                        detail: T("Pippa prepares things for you and waits until you open the island.", table: "Settings")) {
                Toggle(T("Calm notices", table: "Settings"), isOn: Binding(get: { settings.enabled }, set: { coordinator.setEnabled($0) }))
                    .labelsHidden().toggleStyle(.switch)
            }
            if settings.enabled {
                SettingsDivider()
                morningBrief(settings)
                SettingsDivider()
                watchedFolder
                SettingsDivider()
                quietHours(settings)
                if !settings.mutedKinds.isEmpty {
                    SettingsDivider()
                    SettingsRow(title: T("Muted kinds: %lld", table: "Settings", settings.mutedKinds.count),
                                detail: T("Notices you muted from the island.", table: "Settings")) {
                        Button(T("Reset muted", table: "Settings")) { coordinator.resetMuted() }.pippa(.quiet)
                    }
                }
            }
        }
        .onAppear { coordinator.refreshFocusAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            coordinator.refreshFocusAuthorization()
        }
    }

    @ViewBuilder private func morningBrief(_ settings: ProactivitySettings) -> some View {
        SettingsRow(title: T("Morning brief", table: "Settings"),
                    detail: T("Today’s appointments and reminders, put together without AI. Reads only Calendar and Reminders you already allowed. Nothing on an empty day.", table: "Settings")) {
            Toggle(T("Morning brief", table: "Settings"),
                   isOn: Binding(get: { settings.morningBriefEnabled }, set: { coordinator.setMorningBrief(enabled: $0) }))
                .labelsHidden().toggleStyle(.switch)
        }
        if settings.morningBriefEnabled {
            SettingsRow(title: T("From", table: "Settings")) {
                Picker(T("From", table: "Settings"), selection: Binding(
                    get: { min(max(settings.morningBriefHour, ProactivityCoordinator.morningBriefHours.lowerBound),
                               ProactivityCoordinator.morningBriefHours.upperBound) },
                    set: { coordinator.setMorningBrief(hour: $0) })) {
                    ForEach(Array(ProactivityCoordinator.morningBriefHours), id: \.self) { hour in
                        Text(verbatim: String(format: "%02d:00", hour)).tag(hour)
                    }
                }
                .labelsHidden().fixedSize()
            }
            SettingsRow(title: T("Preview today’s brief", table: "Settings"), detail: coordinator.previewText) {
                Button(T("Preview now", table: "Settings")) { coordinator.previewMorningBriefNow() }
                    .pippa(.secondary)
                    .disabled(coordinator.isPreviewing)
            }
        }
    }

    private var watchedFolder: some View {
        SettingsRow(title: T("Watched folder", table: "Settings"),
                    detail: coordinator.watchedFolderName
                        ?? T("None. New documents in a folder you choose get a short look by the AI built into macOS, one level deep.", table: "Settings")) {
            HStack(spacing: Space.s) {
                if coordinator.watchedFolderName != nil {
                    Button(T("Remove", table: "Settings")) { coordinator.removeFolder() }.pippa(.quiet)
                }
                Button(T("Choose…", table: "Settings")) { coordinator.chooseFolder() }.pippa(.secondary)
            }
        }
    }

    @ViewBuilder private func quietHours(_ settings: ProactivitySettings) -> some View {
        SettingsRow(title: T("Quiet hours", table: "Settings"), detail: T("No notices from 22:00 to 08:00.", table: "Settings")) {
            Toggle(T("Quiet hours", table: "Settings"),
                   isOn: Binding(get: { settings.quietHoursEnabled }, set: { coordinator.setQuietHours(enabled: $0) }))
                .labelsHidden().toggleStyle(.switch)
        }
        SettingsNote(coordinator.focusAuthorization == .authorized
                     ? T("Pippa also waits while a Focus is on.", table: "Settings")
                     : T("Pippa can’t see your Focus yet, so she waits only during quiet hours and while the screen is locked. You can allow Focus status in System Settings › Privacy & Security › Focus.", table: "Settings"))
            .padding(.bottom, Space.ml)
    }
}

/// AI: the AI on this Mac (or its setup), then the online AI.
struct AISettings: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var setup: SetupModel

    var body: some View {
        SettingsScroll {
            if setup.isReady {
                SettingsSection(title: T("On this Mac", table: "App")) {
                    SettingsRow(title: SettingsView.localModelName,
                                detail: T("Your conversations stay on this Mac.", table: "Settings")) {
                        SettingsStatus(symbol: "checkmark.circle.fill", color: Theme.ok, text: T("Ready", table: "App"))
                    }
                }
            } else {
                // The setup card is a surface itself: it sits on the page, not in a group.
                VStack(alignment: .leading, spacing: Space.m) {
                    Text(T("On this Mac", table: "App")).font(Typo.callout.weight(.semibold)).foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    SetupCard(setup: setup, showsOnlineOption: false)
                }
            }
            PiProviderSettings(settings: settings)
            // Keep existing Keychain connections usable until the person chooses a Pi provider.
            if settings.inferenceSettings.activePiModel == nil, settings.inferenceSettings.connection != nil {
                ModelConnectionSettings(model: settings)
            }
            SharingSettings(settings: settings)
            OptionalCapabilitySettings(settings: settings)
        }
    }
}

/// What may go to an online AI, per source: "Ask before sharing" (Pippa shows the provider and the excerpt first) or
/// "Only on this Mac". "Allow Mac access" for the online AI in use (issue #196), and the online AI that single questions
/// go to while conversations stay on this Mac.
struct SharingSettings: View {
    @ObservedObject var settings: SettingsModel
    private let failureState = State<String?>(initialValue: nil)
    /// The online AI in use with its effective recipient, read off the main thread; `nil` on this Mac or while reading.
    private let activeState = State<ShareDestination?>(initialValue: nil)
    private let expandedState = State(initialValue: false)

    var body: some View {
        let active = settings.inferenceSettings.usesOnlineAI ? activeState.wrappedValue : nil
        let macAccess = settings.inferenceSettings.allowsMacAccess(active)
        let footer = failureState.wrappedValue
            ?? active.flatMap { macAccess ? T("%@ has Mac access. Tool results and files you attach directly go to this provider without review. The rules below apply to excerpts you choose to review, such as Selected Email in Mail.", table: "Settings", $0.provider) : nil }
            ?? T("An online AI never reads these by itself. Before anything from them is sent, Pippa shows which provider gets it and the exact text, which you can edit. What you type yourself is sent as it is.", table: "Settings")
        let handoff = ShareDestination.handoff(settings.inferenceSettings, recipients: .unresolved)
        // Nothing is shared and nothing is set up: five identical rows would only crowd the page.
        let collapsed = !settings.inferenceSettings.usesOnlineAI && handoff == nil
        SettingsSection(title: T("Sharing with online AI", table: "Settings"), footer: footer) {
            if let active {
                macAccessRow(active, allowed: macAccess)
                SettingsDivider()
            }
            if collapsed && !expandedState.wrappedValue {
                SettingsRow(title: summary) {
                    Button(T("Configure…", table: "Settings")) { expandedState.wrappedValue = true }.pippa(.quiet)
                }
            } else {
                sourceRows
                if collapsed {
                    SettingsDivider()
                    SettingsRow(title: summary) {
                        Button(T("Hide", table: "Settings")) { expandedState.wrappedValue = false }.pippa(.quiet)
                    }
                }
            }
            if let handoff {
                SettingsDivider()
                SettingsRow(title: T("Single questions", table: "Settings"),
                            detail: T("While Pippa uses this Mac, “Ask %@…” in the chat sends one checked question to %@.", table: "Settings",
                                      handoff.provider, handoff.label)) {
                    Button(T("Remove", table: "Settings")) { save(settings.inferenceSettings.sharing, removeRecipient: true) }.pippa(.quiet)
                }
            }
        }
        .task(id: settings.inferenceSettings) { await resolve() }
    }

    /// "All sources ask before sharing", or how many ask and how many stay on this Mac.
    private var summary: String {
        let asking = SharingSource.allCases.filter { settings.inferenceSettings.sharing[$0] == .ask }.count
        let total = SharingSource.allCases.count
        return asking == total
            ? T("All sources ask before sharing", table: "Settings")
            : T("Ask before sharing: %lld · Only on this Mac: %lld", table: "Settings", asking, total - asking)
    }

    private var sourceRows: some View {
        ForEach(Array(SharingSource.allCases.enumerated()), id: \.element) { index, source in
            if index > 0 { SettingsDivider() }
            SettingsRow(title: source.displayName) {
                Picker(source.displayName, selection: Binding(
                    get: { settings.inferenceSettings.sharing[source] },
                    set: { rule in
                        var sharing = settings.inferenceSettings.sharing
                        sharing[source] = rule
                        save(sharing)
                    })) {
                    Text(T("Ask before sharing", table: "Settings")).tag(SharingRule.ask)
                    Text(T("Only on this Mac", table: "Settings")).tag(SharingRule.localOnly)
                }
                .labelsHidden().fixedSize()
            }
        }
    }

    /// Off unless the person turns it on; it can only be turned on for a recipient Pippa could verify.
    private func macAccessRow(_ active: ShareDestination, allowed: Bool) -> some View {
        let title = T("Allow Mac access", table: "Settings")
        let detail = active.isVerified
            ? T("%@ can use the same Mac tools as the AI on this Mac: files, shell commands, Mail, Calendar, Reminders, Photos and the app in front. What they read, files you add and your personal notes, if they’re on, go to %@. Pippa’s existing confirmations and macOS permissions still apply. Only for this provider, model and account. Changes apply from your next question; an answer already running keeps its access until it finishes or you stop it.", table: "Settings", active.label, active.provider)
            : T("Pippa can’t confirm which account %@ uses, so it can’t get Mac access.", table: "Settings", active.label)
        return SettingsRow(title: title, detail: detail) {
            Toggle(title, isOn: Binding(get: { allowed }, set: { on in
                do { try settings.saveMacAccess(active, allowed: on); failureState.wrappedValue = nil }
                catch { failureState.wrappedValue = error.localizedDescription; Task { await resolve() } }
            }))
            .labelsHidden().toggleStyle(.switch)
            .disabled(!allowed && !active.isVerified)
        }
    }

    /// Reads the recipient behind the online AI in use as `PiSession` would (Pi's files, the Keychain without a dialog).
    private func resolve() async {
        let current = settings.inferenceSettings
        activeState.wrappedValue = await Task.detached { ShareDestination.active(current) }.value
    }

    private func save(_ sharing: SourceSharing, removeRecipient: Bool = false) {
        do { try settings.saveSharing(sharing, removeRecipient: removeRecipient); failureState.wrappedValue = nil }
        catch { failureState.wrappedValue = error.localizedDescription }
    }
}

/// Web search and personal notes, each switched separately for the AI on this Mac and the online AI. Off leaves out the
/// capability's tools, so a small local model reads fewer tool descriptions. Mac tools, the browser panel and shell
/// approvals are not optional.
struct OptionalCapabilitySettings: View {
    @ObservedObject var settings: SettingsModel
    private let failureState = State<String?>(initialValue: nil)

    var body: some View {
        SettingsSection(title: T("Optional abilities", table: "Settings"),
                        footer: failureState.wrappedValue ?? T("Only enabled tools take up space in the model’s context. Changes apply from your next question.", table: "Settings")) {
            row(T("Web search", table: "Settings"),
                detail: T("Lets Pippa search the web and fetch pages for an answer. Pippa can still open pages in her browser with your permission.", table: "Settings"),
                \.web)
            SettingsDivider()
            // Online AI never gets the notes (PippaPiLaunch.Capabilities.online), except with Mac access, which uses this
            // switch: only the one for this Mac.
            row(T("Personal notes", table: "Settings"),
                detail: T("Lets the AI on this Mac save and use personal notes across chats. An online AI gets them only with Mac access. Turning this off keeps your saved notes.", table: "Settings"),
                \.memory, online: false)
        }
    }

    private func row(_ title: String, detail: String, _ key: WritableKeyPath<OptionalCapabilities.Choice, Bool>, online: Bool = true) -> some View {
        SettingsRow(title: title, detail: detail) {
            VStack(alignment: .trailing, spacing: Space.xs) {
                toggle(T("On this Mac", table: "App"), title: title, online: false, key)
                if online { toggle(T("Online", table: "Settings"), title: title, online: true, key) }
            }
        }
    }

    private func toggle(_ label: String, title: String, online: Bool, _ key: WritableKeyPath<OptionalCapabilities.Choice, Bool>) -> some View {
        Toggle(label, isOn: Binding(
            get: { settings.inferenceSettings.capabilities[online: online][keyPath: key] },
            set: { on in
                var capabilities = settings.inferenceSettings.capabilities
                capabilities[online: online][keyPath: key] = on
                do { try settings.saveCapabilities(capabilities); failureState.wrappedValue = nil }
                catch { failureState.wrappedValue = error.localizedDescription }
            }))
        .toggleStyle(.switch).controlSize(.small)
        .accessibilityLabel("\(title), \(label)")
    }
}

/// Updates: the version and checking by hand, or installing an update that already waits.
struct UpdateSettings: View {
    @ObservedObject private var updates = Updates.shared

    var body: some View {
        SettingsScroll {
            SettingsSection {
                if let ready = updates.readyVersion {
                    SettingsRow(title: T("Version", table: "App"), detail: AppVersion.label) {
                        SettingsStatus(symbol: "arrow.down.circle.fill", color: Theme.ok,
                                       text: T("Pippa %@ is ready to install.", table: "Settings", ready))
                    }
                    SettingsDivider()
                    SettingsRow(title: T("Install the update", table: "Settings"),
                                detail: T("Pippa restarts and is back in a few seconds.", table: "Settings")) {
                        Button(T("Install and Restart", table: "App")) { updates.installReadyNow() }
                            .pippa(.primary)
                            .disabled(updates.isChecking)
                    }
                } else {
                    SettingsRow(title: T("Version", table: "App"), detail: AppVersion.label) {
                        Button(updates.isChecking ? T("Checking…", table: "Settings") : T("Check for Updates…", table: "App")) {
                            updates.checkNow()
                        }
                        .pippa(.secondary)
                        .disabled(updates.isChecking)
                    }
                }
            }
        }
    }
}
