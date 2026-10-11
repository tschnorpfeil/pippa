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

/// Group: small heading, box with hairline, rows 52, an optional quiet note under the box.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var note: String?
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.scaled(size: 13, weight: .semibold)).foregroundStyle(Theme.ink2).padding(.leading, 4)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.fill)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hair, lineWidth: 0.5)))
            if let note {
                Text(note).font(Fonts.hint).foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }
}

/// Small coloured square with a symbol, as in System Settings: lets a row be found by its picture before it is read.
struct SettingsIcon: View {
    var symbol: String
    var tint: Color
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint))
            .accessibilityHidden(true)
    }
}

struct SettingsRow<Trailing: View>: View {
    var title: String
    var detail: String?
    var icon: String? = nil
    var tint: Color = .gray
    var divider = true
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 12) {
            if let icon { SettingsIcon(symbol: icon, tint: tint) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.scaled(size: 13.5, weight: .medium)).foregroundStyle(Theme.ink)
                if let detail { Text(detail).font(.scaled(size: 12)).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true) }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .overlay(alignment: .top) { if divider { Theme.hair.frame(height: 0.5).padding(.leading, icon == nil ? 14 : 52) } }
    }
}

/// The plain answer to "where do my things go?", at the top where it is read first. Green lock while everything stays
/// on this Mac; an orange globe naming the service as soon as conversations go online.
private struct PrivacyBanner: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let online = destination
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: online == nil ? "lock.fill" : "globe")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(online == nil ? Theme.ok : Theme.need)
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(online.map { T("Your conversations go to %@", table: "Settings", $0) }
                     ?? T("Everything stays on your Mac", table: "Settings"))
                    .font(.scaled(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(online == nil
                     ? T("Pippa only goes online for downloads, updates and web searches. Under each answer you see what was searched.", table: "Settings")
                     : T("Your files stay on your Mac. You can switch back below at any time.", table: "Settings"))
                    .font(.scaled(size: 12)).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(online == nil ? Theme.okTint : Theme.needTint))
        .accessibilityElement(children: .combine)
    }

    /// Where conversations go, or nil while they stay here. Covers the ChatGPT subscription as well as an own service.
    private var destination: String? {
        if model.inferenceSettings.subscriptionModel != nil { return "OpenAI (ChatGPT)" }
        if model.inferenceSettings.policy != .localOnly,
           let connection = model.inferenceSettings.connection, !connection.isLocal {
            switch connection.provider {
            case .openAI: return "OpenAI"
            case .anthropic: return "Anthropic"
            case .compatible: return connection.destination
            }
        }
        return nil
    }
}

/// Pippa's AI in its own group, only while there is something to see or do (loading, the Standard/More thorough
/// choice, an update). The rows and their logic are unchanged; this only decides whether the group shows.
private struct AIGroup: View {
    @ObservedObject var model: AppModel
    @ObservedObject var setup: PiSetupController

    var body: some View {
        if loadRowShows || knowledgeRowShows || readyRowShows {
            SettingsGroup(title: T("Pippa’s AI", table: "Settings")) {
                VStack(spacing: 0) {
                    if loadRowShows { AILoadRow(model: model) }
                    if knowledgeRowShows { KnowledgeRow(model: model, setup: setup) }
                    if readyRowShows {
                        // Nothing to choose: only say that the AI is here and works offline.
                        SettingsRow(title: T("Pippa’s AI", table: "Settings"),
                                    detail: T("Runs on your Mac, also without internet.", table: "Settings"),
                                    icon: "cpu", tint: .teal, divider: false) {
                            StatusBadge(text: T("Ready", table: "Settings"), symbol: "checkmark", ink: Theme.ok, fill: Theme.okTint)
                        }
                    }
                }
            }
        }
    }

    private var readyRowShows: Bool { !model.alwaysUsesConnection && setup.isReady && !knowledgeRowShows }

    private var loadRowShows: Bool { AILoadRow.shows(model) }
    private var knowledgeRowShows: Bool {
        !model.alwaysUsesConnection && setup.isReady && (setup.offersThorough || setup.update != nil)
    }
}

/// Before the AI is on this Mac: say so and offer loading. Same conditions and buttons as before.
private struct AILoadRow: View {
    @ObservedObject var model: AppModel
    static func shows(_ model: AppModel) -> Bool {
        !model.alwaysUsesConnection && !model.aiLoaded && model.unsupportedReason == nil
    }
    var body: some View {
        SettingsRow(title: T("Pippa’s AI", table: "Settings"), detail: model.learningText ?? model.capabilityText, divider: false) {
            if model.needsDownloadConsent {
                Button(T("Load Now", table: "Settings")) { model.startModelDownload() }.pippa(.secondary)
            } else if model.downloadStalled || model.piSetupFailed {
                Button(T("Try Again", table: "Settings")) { model.retryDownloadNow() }.pippa(.quiet)
            } else if model.isDownloading, PiSetupController.shared == nil {
                // Pi path: loading goes on in the background; there is nothing to cancel here.
                Button(T("Cancel", table: "Settings")) { model.cancelModelDownload() }.pippa(.quiet)
            }
        }
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
            SettingsRow(title: T("Pippa’s AI", table: "Settings"), detail: detail, divider: false) {
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
                        Button(T("Load Pippa’s AI Now (%@)", table: "App", ModelDownloadSize.gigabytes(bytes))) { setup.loadUpdate() }
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
            return T("A new AI is ready to load. Until then, Pippa keeps working with the one she has.", table: "Settings")
        case .downloading(let progress, let remaining)?:
            var text = T("Pippa is loading her AI · %lld %%", table: "App", Int((progress * 100).rounded()))
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

    private let learnedState = State(initialValue: 0)
    private let learningErrorState = State<String?>(initialValue: nil)
    private let learningStatusState = State<String?>(initialValue: nil)
    private let forgettingState = State(initialValue: false)

    /// "Online AI" stays folded away until someone opens it; it opens by itself when an online AI is already in use.
    private let onlineOpenState: State<Bool>

    init(model: AppModel) {
        self.model = model
        let settings = model.inferenceSettings
        onlineOpenState = State(initialValue: settings.subscriptionModel != nil || settings.policy != .localOnly || settings.connection != nil)
    }

    var body: some View { TextScaleRoot { content } }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PrivacyBanner(model: model)
                SettingsGroup(title: T("Everyday", table: "Settings")) {
                    SettingsRow(title: T("Call Pippa", table: "Settings"),
                                detail: hotkeyTaken.wrappedValue ? HotkeyCenter.takenText : T("Opens Pippa from anywhere.", table: "Settings"),
                                icon: "keyboard", tint: .blue, divider: false) {
                        Picker("", selection: hotkeyState.projectedValue) {
                            ForEach(Hotkey.allCases) { Text(Self.hotkeyTitle($0)).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityLabel(T("Call Pippa", table: "Settings"))
                        .onChange(of: hotkeyState.wrappedValue) { _, new in
                            Hotkey.current = new
                            hotkeyTaken.wrappedValue = !HotkeyCenter.shared.apply(new)
                        }
                    }
                    SettingsRow(title: T("Open at login", table: "Settings"),
                                detail: loginError.wrappedValue ?? T("Pippa is there as soon as your Mac is on.", table: "Settings"),
                                icon: "power", tint: .green) {
                        Toggle("", isOn: loginState.projectedValue).labelsHidden()
                            .accessibilityLabel(T("Open at login", table: "Settings"))
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
                    SettingsRow(title: T("Text size", table: "Settings"), detail: T("Makes all text in Pippa larger.", table: "Settings"),
                                icon: "textformat.size", tint: .orange) {
                        TextSizeControl()
                    }
                }
                if let setup = PiSetupController.shared {
                    AIGroup(model: model, setup: setup)
                } else if AILoadRow.shows(model) {
                    SettingsGroup(title: T("Pippa’s AI", table: "Settings")) { AILoadRow(model: model) }
                }
                // Same rows and buttons as the onboarding page "What Pippa may do".
                PermissionSettingsGroup(permissions: model.permissions)
                MemoryFactsGroup()
                learningGroup
                onlineGroup
                Text(T("Pippa %@", table: "Settings", PippaCore.Pippa.version))
                    .font(Fonts.sill).foregroundStyle(Theme.ink3)
                    .frame(maxWidth: .infinity)
                    .textSelection(.enabled)
            }
            .padding(.horizontal, 24)
            .padding(.top, 48)
            .padding(.bottom, 20)
        }
        .frame(width: 560, height: 640)
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

    /// Online AI is for the few who already pay for one: one folded row with a plain "optional", the forms behind it.
    private var onlineGroup: some View {
        SettingsGroup(title: T("Online AI", table: "Settings")) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { onlineOpenState.wrappedValue.toggle() } } label: {
                SettingsRow(title: T("Use an online AI (optional)", table: "Settings"),
                            detail: T("Only if you already have ChatGPT or your own AI account. Pippa doesn’t need it.", table: "Settings"),
                            icon: "globe", tint: .purple, divider: false) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink3)
                        .rotationEffect(.degrees(onlineOpenState.wrappedValue ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(onlineOpenState.wrappedValue ? T("Details shown", table: "Settings") : T("Details hidden", table: "Settings"))
            if onlineOpenState.wrappedValue {
                ChatGPTSubscriptionSettings(model: model)
                ModelConnectionSettings(model: model)
            }
        }
    }

    /// Just one row: what Pippa remembers and "Forget". No list of individual actions anymore.
    private var learningGroup: some View {
        SettingsGroup(title: T("What Pippa remembers", table: "Settings")) {
            SettingsRow(title: T("Favourite suggestions", table: "Settings"),
                        detail: T("Pippa notes which suggestions you pick, so the right ones come first. Only on this Mac, for up to a year. Forgetting keeps your conversations and files.", table: "Settings"),
                        icon: "sparkles", tint: .pink, divider: false) {
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

    /// Shortcut spelled out with the key names printed on the keyboard; the symbols alone mean nothing to many people.
    private static func hotkeyTitle(_ hotkey: Hotkey) -> String {
        let keys: String
        switch hotkey {
        case .optionSpace: keys = T("Option + Space", table: "Settings")
        case .controlOptionSpace: keys = T("Control + Option + Space", table: "Settings")
        case .controlShiftSpace: keys = T("Control + Shift + Space", table: "Settings")
        case .controlOptionP: keys = T("Control + Option + P", table: "Settings")
        case .off: keys = hotkey.display
        }
        if hotkey == .standard { return T("%@ (Default)", table: "Settings", keys) }
        return keys
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
    }
}

/// Small rounded label for a state that needs no action ("Allowed", "Will ask").
struct StatusBadge: View {
    var text: String
    var symbol: String?
    var ink: Color
    var fill: Color
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
            Text(text).font(.scaled(size: 12, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(fill))
        .fixedSize()
    }
}

/// Three steps as large buttons in our own text (the system segmented control does not follow the text size).
private struct TextSizeControl: View {
    @ObservedObject private var store = TextScaleStore.shared
    private var options: [(Double, String)] {
        [(TextScale.normal, T("Normal", table: "Settings")),
         (TextScale.large, T("Large", table: "Settings")),
         (TextScale.extraLarge, T("Extra large", table: "Settings"))]
    }
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                let selected = store.factor == value
                Button { store.set(value) } label: {
                    Text(title)
                        .font(.scaled(size: 12.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.white : Theme.ink)
                        .lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Theme.accentFill : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.hair))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(T("Text size", table: "Settings"))
    }
}
