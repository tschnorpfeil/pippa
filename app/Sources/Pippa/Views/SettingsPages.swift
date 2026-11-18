import AppKit
import PippaCore
import ServiceManagement
import SwiftUI

/// General: the shortcut, opening at login, Pippa Island, moving to Applications.
struct GeneralSettings: View {
    @ObservedObject var island = Island.shared
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
/// "Only on this Mac". And the online AI that single questions go to while conversations stay on this Mac.
struct SharingSettings: View {
    @ObservedObject var settings: SettingsModel
    private let failureState = State<String?>(initialValue: nil)

    var body: some View {
        SettingsSection(title: T("Sharing with online AI", table: "Settings"),
                        footer: failureState.wrappedValue ?? T("An online AI never reads these by itself. Before anything from them is sent, Pippa shows which provider gets it and the exact text, which you can edit. What you type yourself is sent as it is.", table: "Settings")) {
            ForEach(Array(SharingSource.allCases.enumerated()), id: \.element) { index, source in
                if index > 0 { SettingsDivider() }
                SettingsRow(title: source.displayName) {
                    Picker(source.displayName, selection: Binding(
                        get: { settings.inferenceSettings.sharing[source] },
                        set: { rule in
                            var sharing = settings.inferenceSettings.sharing
                            sharing[source] = rule
                            save(sharing, handoff: settings.inferenceSettings.handoffModel)
                        })) {
                        Text(T("Ask before sharing", table: "Settings")).tag(SharingRule.ask)
                        Text(T("Only on this Mac", table: "Settings")).tag(SharingRule.localOnly)
                    }
                    .labelsHidden().fixedSize()
                }
            }
            if let handoff = ShareDestination.handoff(settings.inferenceSettings) {
                SettingsDivider()
                SettingsRow(title: T("Single questions", table: "Settings"),
                            detail: T("While Pippa uses this Mac, “Ask %@…” in the chat sends one checked question to %@.", table: "Settings",
                                      handoff.provider, handoff.label)) {
                    Button(T("Remove", table: "Settings")) { save(settings.inferenceSettings.sharing, handoff: nil) }.pippa(.quiet)
                }
            }
        }
    }

    private func save(_ sharing: SourceSharing, handoff: PiModelSelection?) {
        do { try settings.saveSharing(sharing, handoff: handoff); failureState.wrappedValue = nil }
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
            // Online AI never gets the notes (PippaPiLaunch.Capabilities.online): only the switch for this Mac.
            row(T("Personal notes", table: "Settings"),
                detail: T("Lets the AI on this Mac save and use personal notes across chats. An online AI never gets them. Turning this off keeps your saved notes.", table: "Settings"),
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

/// Updates: the version and checking by hand.
struct UpdateSettings: View {
    var body: some View {
        SettingsScroll {
            SettingsSection {
                SettingsRow(title: T("Version", table: "App"), detail: AppVersion.label) {
                    Button(T("Check for Updates…", table: "App")) { Updates.shared.checkNow() }.pippa(.secondary)
                }
            }
        }
    }
}
