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
        Form {
            Section {
                Picker(T("Shortcut", table: "App"), selection: hotkeyState.projectedValue) {
                    ForEach(Hotkey.allCases) { Text($0.display).tag($0) }
                }
                .onChange(of: hotkeyState.wrappedValue) { _, value in Hotkey.current = value; HotkeyCenter.shared.apply(value) }
                Toggle(T("Open at login", table: "App"), isOn: opensAtLoginState.projectedValue)
                    .onChange(of: opensAtLoginState.wrappedValue) { _, on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                        opensAtLoginState.wrappedValue = SMAppService.mainApp.status == .enabled
                    }
            }
            Section {
                Toggle(isOn: $island.isShown) {
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(T("Show Pippa Island", table: "Settings")).font(Typo.callout)
                        Text(T("Sits at the top of the screen, shows what Pippa is doing and takes a quick question.", table: "Settings"))
                            .font(Typo.footnote).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if Self.outsideApplications {
                Section {
                    SettingsRow(title: T("Pippa isn’t in Applications", table: "App"),
                                detail: T("From there she stays up to date by herself and can open at login.", table: "App")) {
                        Button(T("Move to Applications…", table: "App")) { AppMover.moveNow() }
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
        Form {
            Section(T("On this Mac", table: "App")) {
                if setup.isReady {
                    SettingsRow(title: SettingsView.localModelName,
                                detail: T("Your conversations stay on this Mac.", table: "Settings")) {
                        HStack(spacing: Space.s) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok).accessibilityHidden(true)
                            Text(T("Ready", table: "App")).foregroundStyle(Theme.ink2)
                        }
                        .font(Typo.callout)
                        .accessibilityElement(children: .combine)
                    }
                } else {
                    SetupCard(setup: setup, showsOnlineOption: false)
                }
            }
            Section {
                PiProviderSettings(settings: settings)
                // Keep existing Keychain connections usable until the person chooses a Pi provider.
                if settings.inferenceSettings.activePiModel == nil, settings.inferenceSettings.connection != nil {
                    ModelConnectionSettings(model: settings)
                }
            }
        }
    }
}

/// Updates: the version and checking by hand.
struct UpdateSettings: View {
    var body: some View {
        Form {
            Section {
                SettingsRow(title: T("Version", table: "App"), detail: AppVersion.label) {
                    Button(T("Check for Updates…", table: "App")) { Updates.shared.checkNow() }
                }
            }
        }
    }
}
