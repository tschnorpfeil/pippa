import AppKit
import PippaCore
import ServiceManagement
import SwiftUI

// Settings, radically simplified (docs/settings-simplification.md): no
// model choice, no "Advanced". What remains: shortcut, launch at login, loading the AI, access, own online service,
// forget learned actions. History with "Undo" and "Show Pippa" live in the menu bar menu.

@MainActor
final class SettingsWindowController {
    private(set) var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) { self.model = model }

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            hosting.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: hosting)
            w.title = "Pippa"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Group: small heading, box with hairline, rows 44.
private struct SettingsGroup<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink3).padding(.leading, 12)
            }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hair, lineWidth: 0.5)))
        }
    }
}

struct SettingsRow<Trailing: View>: View {
    var title: String
    var detail: String?
    var divider = true
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5)).foregroundStyle(Theme.ink)
                if let detail { Text(detail).font(.system(size: 12)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .overlay(alignment: .top) { if divider { Theme.hair.frame(height: 0.5) } }
    }
}

/// "Pippas Wissen" once setup is ready: on 24 GB and up the one choice "Standard" / "Gründlicher" (plain words and the
/// download size, no model names), and on every Mac the offer to load new knowledge while the old one keeps working
/// (after an update that changed the table). Nothing else; previously loaded knowledge is never deleted.
private struct KnowledgeRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var setup: PiSetupController

    var body: some View {
        if setup.isReady, setup.offersThorough || setup.update != nil {
            SettingsRow(title: T("Pippa’s knowledge", table: "Settings"), detail: detail) {
                VStack(alignment: .trailing, spacing: 6) {
                    if setup.offersThorough {
                        Picker("", selection: Binding(get: { setup.preference }, set: { setup.choose($0) })) {
                            Text(T("Standard (fast, %@)", table: "Settings", size(.standard))).tag(ModelPreference.standard)
                            Text(T("More thorough (%@)", table: "Settings", size(.thorough))).tag(ModelPreference.thorough)
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(model.isActiveWork)
                    }
                    switch setup.update {
                    case .offer(let bytes)?:
                        Button(T("Load Pippa’s Knowledge Now (%@)", table: "App", ModelDownloadSize.gigabytes(bytes))) { setup.loadUpdate() }
                            .pippa(.secondary)
                    case .downloading?:
                        Button(T("Cancel", table: "Settings")) { setup.cancelUpdate() }.pippa(.quiet)
                    case .failed?:
                        Button(T("Try Again", table: "Settings")) { setup.loadUpdate() }.pippa(.quiet)
                    case nil:
                        EmptyView()
                    }
                }
            }
        }
    }

    private func size(_ preference: ModelPreference) -> String {
        setup.downloadBytes(preference).map(ModelDownloadSize.gigabytes) ?? "–"
    }

    private var detail: String? {
        switch setup.update {
        case .offer?:
            return T("New knowledge is ready to load. Until then, Pippa keeps working with what she has.", table: "Settings")
        case .downloading(let progress, let remaining)?:
            var text = T("Pippa is loading her knowledge · %lld %%", table: "App", Int((progress * 100).rounded()))
            if let remaining, remaining > 0 { text += " · " + AppModel.remainingText(remaining) }
            return text
        case .failed(let reason)?:
            return reason
        case nil:
            return nil
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    // @State is not available without Xcode (macro plugin): storage by hand.
    private let hotkeyState = State(initialValue: Hotkey.current)
    private let loginState = State(initialValue: SMAppService.mainApp.status == .enabled)
    private let loginError = State<String?>(initialValue: nil)
    private let hotkeyTaken = State(initialValue: HotkeyCenter.shared.mainTaken)
    private let accessState = State<[Integration: IntegrationAccess]>(initialValue: [:])

    private let learnedState = State(initialValue: 0)
    private let learningErrorState = State<String?>(initialValue: nil)
    private let learningStatusState = State<String?>(initialValue: nil)
    private let forgettingState = State(initialValue: false)

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsGroup(title: "Pippa") {
                    SettingsRow(title: T("Call Pippa", table: "Settings"), detail: hotkeyTaken.wrappedValue ? HotkeyCenter.takenText : nil, divider: false) {
                        Picker("", selection: hotkeyState.projectedValue) {
                            ForEach(Hotkey.allCases) { Text(Self.hotkeyTitle($0)).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .onChange(of: hotkeyState.wrappedValue) { _, new in
                            Hotkey.current = new
                            hotkeyTaken.wrappedValue = !HotkeyCenter.shared.apply(new)
                        }
                    }
                    SettingsRow(title: T("Open at login", table: "Settings"), detail: loginError.wrappedValue) {
                        Toggle("", isOn: loginState.projectedValue).labelsHidden()
                            .onChange(of: loginState.wrappedValue) { _, on in
                                do {
                                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                                    loginError.wrappedValue = nil
                                } catch {
                                    UserMessage.record(error, context: "autostart")
                                    loginError.wrappedValue = T("That didn’t work just now. Is Pippa in your Applications folder?", table: "Settings")
                                    loginState.wrappedValue = SMAppService.mainApp.status == .enabled
                                }
                            }
                    }
                    if !model.alwaysUsesConnection && !model.modelReady && model.unsupportedReason == nil {
                        SettingsRow(title: T("Pippa’s knowledge", table: "Settings"), detail: model.learningText ?? model.capabilityText) {
                            if model.needsDownloadConsent {
                                Button(T("Load Now", table: "Settings")) { model.startModelDownload() }.pippa(.secondary)
                            } else if model.isDownloading {
                                Button(T("Cancel", table: "Settings")) { model.cancelModelDownload() }.pippa(.quiet)
                            } else if model.downloadStalled {
                                Button(T("Try Again", table: "Settings")) { model.retryDownloadNow() }.pippa(.quiet)
                            }
                        }
                    }
                    if let setup = PiSetupController.shared, !model.alwaysUsesConnection {
                        KnowledgeRow(model: model, setup: setup)
                    }
                }
                SettingsGroup(title: T("Allow Pippa to…", table: "Settings")) {
                    accessRow(T("Add deadlines to Reminders and Calendar", table: "Settings"), [.reminders, .calendar], divider: false)
                    accessRow(T("Read the selected mail", table: "Settings"), [.mail])
                }
                SettingsGroup(title: T("Online service", table: "Settings")) {
                    ModelConnectionSettings(model: model)
                }
                learningGroup
            }
            .padding(.horizontal, 24)
            .padding(.top, 52)
            .padding(.bottom, 24)
            }
            Text(footer)
                .font(Fonts.sill).foregroundStyle(Theme.ink2)
                .padding(.horizontal, 24).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.sill)
        }
        .frame(width: 560, height: 620)
        .background(Color(nsColor: Theme.materialTintSolid))
        .toggleStyle(.switch)
        .tint(Theme.accentFill)
        .task { await load() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  window.contentViewController is NSHostingController<SettingsView>,
                  !forgettingState.wrappedValue else { return }
            Task { await loadLearning() }
        }
    }

    /// Just one row: what Pippa remembers and "Forget". No list of individual actions anymore.
    private var learningGroup: some View {
        SettingsGroup(title: T("What Pippa knows", table: "Settings")) {
            SettingsRow(title: T("Learned actions", table: "Settings"),
                        detail: T("I keep which actions you choose or pass over on this Mac for up to twelve months, so I can order suggestions. Forgetting them resets that order. Conversations, files and Undo stay.", table: "Settings"), divider: false) {
                Button(T("Forget", table: "Settings")) { forgetLearnedActions() }
                    .pippa(.quiet)
                    .disabled(forgettingState.wrappedValue || model.isActiveWork || model.tray.isWorking || learnedState.wrappedValue == 0)
            }
            if forgettingState.wrappedValue {
                ProgressView().controlSize(.small).padding(12)
            }
            if let error = learningErrorState.wrappedValue {
                Text(error).font(Fonts.hint).foregroundStyle(Theme.need)
                    .fixedSize(horizontal: false, vertical: true).padding(12)
            } else if let status = learningStatusState.wrappedValue {
                Text(status).font(Fonts.hint).foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true).padding(12)
            }
        }
    }

    private func forgetLearnedActions() {
        guard !forgettingState.wrappedValue, !model.isActiveWork, !model.tray.isWorking else { return }
        forgettingState.wrappedValue = true
        learningErrorState.wrappedValue = nil
        learningStatusState.wrappedValue = nil
        Task {
            defer { forgettingState.wrappedValue = false }
            do {
                try await model.taskLog.forgetLearnedActions()
                await model.tray.reloadHabits()
                await model.letter.reloadHabits()
                learnedState.wrappedValue = try await model.taskLog.recordsForSettings().count
                learningStatusState.wrappedValue = T("Learned actions forgotten.", table: "Settings")
            } catch {
                learningErrorState.wrappedValue = T("I couldn’t forget the learned actions. Please try again.", table: "Settings")
                UserMessage.record(error, context: "gewohnheiten-vergessen")
            }
        }
    }

    /// A custom online service gets only Pi's conversation requests, each only after Pippa's approval (PippaOnlineService).
    private var inferenceFooter: String {
        if model.inferenceSettings.policy != .localOnly,
           let connection = model.inferenceSettings.connection, !connection.isLocal {
            return T("Before anything is sent to %@, Pippa asks you. The internet is also used for downloads and updates.", table: "Settings", connection.destination)
        }
        return T("Your content is handled on your Mac. The internet is used for downloads, updates and network access you approve.", table: "Settings")
    }

    private var footer: String { inferenceFooter + " " + T("Version %@", table: "Settings", PippaCore.Pippa.version) }

    /// Shortcut with a hint about the default binding.
    private static func hotkeyTitle(_ hotkey: Hotkey) -> String {
        if hotkey == .standard { return T("%@ (Default)", table: "Settings", hotkey.display) }
        return hotkey.display
    }

    private func accessRow(_ title: String, _ integrations: [Integration], divider: Bool = true) -> some View {
        let states = integrations.compactMap { accessState.wrappedValue[$0] }
        return SettingsRow(title: title, divider: divider) {
            if !states.isEmpty && states.allSatisfy({ $0 == .granted }) {
                Label(T("allowed", table: "Settings"), systemImage: "checkmark").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ok)
            } else if states.contains(.denied) {
                Button(T("Open System Settings", table: "Settings")) { NSWorkspace.shared.open(integrations[0].settingsURL) }.pippa(.quiet)
            } else {
                Text(T("asks the first time", table: "Settings")).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ink3)
            }
        }
    }

    private func loadLearning() async {
        do {
            learnedState.wrappedValue = try await model.taskLog.recordsForSettings().count
            learningErrorState.wrappedValue = nil
        } catch {
            learningErrorState.wrappedValue = T("I couldn’t read the learned actions. Please open Settings again.", table: "Settings")
        }
    }

    private func load() async {
        await loadLearning()
        var access: [Integration: IntegrationAccess] = [:]
        for i in Integration.allCases { access[i] = await model.engine.integrationAccess(i) }
        accessState.wrappedValue = access
    }
}
