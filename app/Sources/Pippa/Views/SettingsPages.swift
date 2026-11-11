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
        }
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
