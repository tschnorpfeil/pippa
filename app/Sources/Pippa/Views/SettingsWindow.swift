import AppKit
import PippaCore
import ServiceManagement
import SwiftUI

/// Where the online-AI settings save, and whether an answer is running (then they wait).
@MainActor
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()
    @Published private(set) var inferenceSettings = InferenceSettings.load(from: PiSession.settingsDirectory)
    var isActiveWork: Bool { ChatModel.shared.isAnswering }

    func saveInferenceSettings(_ settings: InferenceSettings) throws {
        guard !isActiveWork else { throw InferenceError.busy }
        try settings.save(to: PiSession.settingsDirectory)
        inferenceSettings = settings
        PiSession.shared.settingsChanged()
        SetupModel.shared.objectWillChange.send()
    }
}

/// Settings: the AI, the shortcut, opening at login, Mac permissions, updates.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = T("Pippa Settings", table: "App")
            window.isReleasedWhenClosed = false
            // Taller for the online-AI form; the width stays (the view is 560 wide).
            window.minSize = NSSize(width: 560, height: 480)
            window.contentView = NSHostingView(rootView: SettingsView(settings: .shared, setup: .shared))
            window.center()
            self.window = window
        }
        NSApp.unhide(nil)
        NSApp.activate()
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var setup: SetupModel
    @ObservedObject var pill = Pill.shared
    private let hotkeyState = State(initialValue: Hotkey.current)
    private let opensAtLoginState = State(initialValue: SMAppService.mainApp.status == .enabled)
    /// Asked once: where the app lies does not change while it runs.
    private static let outsideApplications = Bundle.main.bundleURL.pathExtension == "app" && !AppLocation.isInApplications()

    var body: some View {
        Form {
            Section(T("Pippa’s AI", table: "App")) {
                if setup.isReady {
                    SettingsRow(title: T("On this Mac", table: "App"),
                                detail: T("%@. Your conversations stay on this Mac.", table: "App", Self.localModelName)) {
                        Label(T("Ready", table: "App"), systemImage: "circle.fill")
                            .labelStyle(StatusLabelStyle())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    SetupCard(setup: setup, showsOnlineOption: false)
                }
                PiProviderSettings(settings: settings)
                // Keep existing Keychain connections usable until the person chooses a Pi provider.
                if settings.inferenceSettings.activePiModel == nil, settings.inferenceSettings.connection != nil {
                    ModelConnectionSettings(model: settings)
                }
            }
            Section(T("Everyday", table: "App")) {
                Picker(T("Shortcut", table: "App"), selection: hotkeyState.projectedValue) {
                    ForEach(Hotkey.allCases) { Text($0.display).tag($0) }
                }
                .onChange(of: hotkeyState.wrappedValue) { _, value in Hotkey.current = value; HotkeyCenter.shared.apply(value) }
                Toggle(T("Open at login", table: "App"), isOn: opensAtLoginState.projectedValue)
                    .onChange(of: opensAtLoginState.wrappedValue) { _, on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                        opensAtLoginState.wrappedValue = SMAppService.mainApp.status == .enabled
                    }
                Toggle(T("Show Pippa at the screen edge", table: "App"), isOn: Binding(get: { pill.isShown }, set: { pill.isShown = $0 }))
                if Self.outsideApplications {
                    SettingsRow(title: T("Pippa isn’t in Applications", table: "App"),
                                detail: T("From there she stays up to date by herself and can open at login.", table: "App")) {
                        Button(T("Move to Applications…", table: "App")) { AppMover.moveNow() }
                    }
                }
            }
            Section(T("Permissions", table: "App")) {
                Text(T("Pippa asks the first time she needs Calendar, Reminders, Mail, Photos or your files. You can change that later in System Settings.", table: "App"))
                    .font(.callout).foregroundStyle(.secondary)
                Button(T("Open Privacy & Security…", table: "App")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
                }
            }
            Section(T("Updates", table: "App")) {
                SettingsRow(title: T("Version", table: "App"), detail: AppVersion.label) {
                    Button(T("Check for Updates…", table: "App")) { Updates.shared.checkNow() }
                }
            }
        }
        .formStyle(.grouped)
        .tint(Theme.accent)
        .frame(width: 560)
        .frame(minHeight: 480, maxHeight: .infinity)
    }

    /// Read once: `ModelCatalog.bundled()` decodes a file, and views ask for the name on every redraw.
    static let localModelName: String = ModelCatalog.bundled().models.first?.label ?? ""
}

/// A small green dot before the status text.
private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 7)).foregroundStyle(Theme.ok)
            configuration.title
        }
    }
}

/// One row in a settings group: title, explanation, control (used by the online-AI settings).
struct SettingsRow<Trailing: View>: View {
    var title: String
    var detail: String?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            trailing
        }
    }
}

enum ButtonKind { case primary, secondary, quiet }

extension View {
    @ViewBuilder func pippa(_ kind: ButtonKind, large: Bool = false) -> some View {
        switch kind {
        case .primary: buttonStyle(.borderedProminent)
        case .secondary: buttonStyle(.bordered)
        case .quiet: buttonStyle(.borderless)
        }
    }
}
