import AppKit
import PippaCore
import SwiftUI

struct PiProviderSettings: View {
    @ObservedObject var settings: SettingsModel
    private let providerState = StateObject(wrappedValue: PiProviderSettingsModel())
    private var provider: PiProviderSettingsModel { providerState.wrappedValue }
    private let showProvidersState = State(initialValue: false)
    private var showProviders: Bool {
        get { showProvidersState.wrappedValue }
        nonmutating set { showProvidersState.wrappedValue = newValue }
    }
    private let providerSearchState = State(initialValue: "")
    private var providerSearch: String {
        get { providerSearchState.wrappedValue }
        nonmutating set { providerSearchState.wrappedValue = newValue }
    }
    private let modelSearchState = State(initialValue: "")
    private var modelSearch: String {
        get { modelSearchState.wrappedValue }
        nonmutating set { modelSearchState.wrappedValue = newValue }
    }
    private let confirmDisconnectState = State(initialValue: false)
    private var confirmDisconnect: Bool {
        get { confirmDisconnectState.wrappedValue }
        nonmutating set { confirmDisconnectState.wrappedValue = newValue }
    }
    private var blocked: Bool { provider.busy || settings.isActiveWork }
    private var active: PiModelSelection? { settings.inferenceSettings.activePiModel }
    private var matchingModels: [PiProvider.Model] {
        (provider.selected?.orderedModels() ?? []).filter {
            modelSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(modelSearch) || $0.id.localizedCaseInsensitiveContains(modelSearch)
        }
    }

    /// The model's display name; the raw ID only when Pi lists no name.
    private func modelName(_ model: PiProvider.Model) -> String { model.name.isEmpty ? model.id : model.name }

    /// The name of the model in use, from the provider list, or as saved with the selection.
    private func activeModelName(_ selection: PiModelSelection) -> String {
        provider.providers.first { $0.id == selection.providerID }?.models.first { $0.id == selection.modelID }.map(modelName)
            ?? selection.modelDisplayName
    }

    private var statusLine: String {
        if let active { return T("Using %@ · %@", table: "Settings", active.providerName, activeModelName(active)) }
        if let own = PiOnlineProvider.activeConnection(settings.inferenceSettings) {
            return T("Using %@ · %@", table: "Settings", own.provider.displayName, own.modelID)
        }
        return T("Off · Pippa uses the AI on this Mac.", table: "Settings")
    }

    var body: some View {
        SettingsSection(title: T("Online AI", table: "Settings")) {
            SettingsRow(title: statusLine,
                        detail: T("Connect an account, choose a model, and use it for conversations. You can switch back at any time.", table: "Settings"),
                        selectable: true) {
                if settings.inferenceSettings.usesOnlineAI {
                    Button(T("Use this Mac", table: "Settings")) { useLocal() }.pippa(.quiet).disabled(blocked)
                }
            }
            if provider.providers.isEmpty && provider.loading {
                SettingsDivider()
                HStack(spacing: Space.m) { ProgressView().controlSize(.small); Text(T("Loading providers…", table: "Settings")) }
                    .settingsBlock()
            } else if !provider.providers.isEmpty {
                providerFields
            }
            if let problem = provider.problem {
                SettingsDivider()
                HStack(spacing: Space.l) {
                    Text(problem).font(Typo.footnote).foregroundStyle(Theme.need).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Space.m)
                    if provider.providers.isEmpty {
                        Button(T("Try again", table: "Settings")) { provider.refresh(selection: active) }.pippa(.secondary).disabled(blocked)
                            .fixedSize()
                    }
                }.settingsBlock()
            }
        }
        .onChange(of: provider.selectedID) { _, _ in modelSearch = "" }
        .onAppear { provider.refresh(selection: active) }
        .onDisappear { provider.cancel() }
        .sheet(isPresented: Binding(get: { provider.connecting }, set: { if !$0 { provider.cancel() } })) {
            ProviderLoginSheet(provider: provider)
        }
        .confirmationDialog(T("Disconnect this provider?", table: "Settings"), isPresented: confirmDisconnectState.projectedValue) {
            Button(T("Disconnect", table: "Settings"), role: .destructive) { provider.disconnect(settings: settings) }
        } message: {
            Text(T("This also signs the provider out of Pi in Terminal. Credentials supplied outside Pippa may still apply.", table: "Settings"))
        }
    }

    @ViewBuilder private var providerFields: some View {
        SettingsDivider()
        SettingsRow(title: T("Provider", table: "Settings")) {
            Button { showProviders = true } label: {
                HStack(spacing: Space.m) {
                    Text(provider.selected?.name ?? T("Choose a provider", table: "Settings"))
                    Image(systemName: "chevron.up.chevron.down").font(Typo.caption)
                }
            }.pippa(.secondary).disabled(blocked)
                .popover(isPresented: showProvidersState.projectedValue) { providerPicker }
        }
        if let selected = provider.selected {
            SettingsDivider()
            HStack(spacing: Space.l) {
                if selected.configured {
                    SettingsStatus(symbol: "checkmark.circle.fill", color: Theme.ok, text: T("Connected", table: "Settings"))
                } else {
                    Text(T("Connect your account", table: "Settings")).foregroundStyle(Theme.ink)
                }
                Spacer(minLength: Space.m)
                if selected.configured {
                    HStack(spacing: Space.xl) {
                        if !selected.methods.isEmpty {
                            Menu(T("Reconnect", table: "Settings")) {
                                ForEach(selected.methods) { method in
                                    Button(method.name) { provider.connect(method: method.id) }
                                }
                            }.menuStyle(.borderlessButton).foregroundStyle(Theme.accent).fixedSize().disabled(blocked)
                        }
                        Button(T("Disconnect", table: "Settings")) { confirmDisconnect = true }.pippa(.quiet).disabled(blocked)
                    }.fixedSize()
                }
            }.settingsBlock()
            if !selected.configured || selected.models.isEmpty {
                SettingsDivider()
                VStack(alignment: .leading, spacing: Space.l) {
                    if !selected.configured {
                        OnlineDataFlowStrip(providerName: selected.name)
                    }
                    ForEach(selected.methods) { method in
                        Button(method.name) { provider.connect(method: method.id) }.pippa(.secondary).disabled(blocked)
                    }
                    SettingsNote(T("Sign-in and credentials are managed by Pi and shared with Pi in Terminal.", table: "Settings"))
                    if selected.methods.isEmpty {
                        SettingsNote(T("This provider uses external configuration. Set it up in Pi, then refresh here.", table: "Settings"))
                    }
                }.settingsBlock()
            }
            if selected.configured && !selected.models.isEmpty {
                SettingsDivider()
                modelChooser(selected)
                SettingsDivider()
                HStack(spacing: Space.l) {
                    SettingsNote(T("What you type will be sent to %@. Anything from your Mac goes along only after you check it.", table: "Settings", selected.name))
                    Spacer(minLength: Space.m)
                    Button(T("Use %@", table: "Settings", selected.name)) { useSelected(selected) }.pippa(.primary)
                        .disabled(blocked || !selected.configured || !selected.models.contains(where: { $0.id == provider.modelID })
                                  || (active?.providerID == selected.id && active?.modelID == provider.modelID))
                        .fixedSize()
                }.settingsBlock()
            } else if selected.configured {
                SettingsDivider()
                SettingsNote(T("No chat models are available for this account yet. Refresh or reconnect to try again.", table: "Settings"))
                    .settingsBlock()
            }
        }
        SettingsDivider()
        Button(T("Refresh providers", table: "Settings")) { provider.refresh(online: true) }.pippa(.quiet).disabled(blocked)
            .settingsBlock()
    }

    /// The search field and the list of models, by display name. Search still matches the ID.
    private func modelChooser(_ selected: PiProvider) -> some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text(T("Choose a model", table: "Settings")).font(Typo.callout).foregroundStyle(Theme.ink)
            TextField("", text: modelSearchState.projectedValue, prompt: Text(T("Search models", table: "Settings")))
                .textFieldStyle(.roundedBorder).labelsHidden().accessibilityLabel(T("Search models", table: "Settings"))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Space.xxs) {
                        ForEach(matchingModels) { model in
                            let chosen = provider.modelID == model.id
                            Button { provider.modelID = model.id } label: {
                                HStack(spacing: Space.m) {
                                    Text(modelName(model)).foregroundStyle(Theme.ink).lineLimit(1)
                                    if model.id == selected.defaultModel { RecommendedBadge() }
                                    Spacer(minLength: Space.xs)
                                    if chosen { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                                }
                                .padding(.horizontal, Space.l).padding(.vertical, Space.m)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(chosen ? Theme.accentTint : .clear, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(model.id).disabled(blocked)
                                .accessibilityAddTraits(chosen ? .isSelected : [])
                        }
                        if matchingModels.isEmpty {
                            Text(T("No matching models", table: "Settings")).font(Typo.footnote).foregroundStyle(Theme.ink2)
                                .padding(Space.l)
                        }
                    }.padding(Space.xs)
                }.frame(minHeight: 140, maxHeight: 220)
                    // Concentric with the group's 12 pt corners: 8 pt here, 6 pt for the chosen row inside.
                    .background(Theme.fill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    .onAppear { proxy.scrollTo(provider.modelID, anchor: .center) }
            }
        }.settingsBlock()
    }

    private var providerPicker: some View {
        VStack(spacing: Space.m) {
            TextField(T("Search providers", table: "Settings"), text: providerSearchState.projectedValue).textFieldStyle(.roundedBorder)
                .padding(.horizontal, Space.ml).padding(.top, Space.ml)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(provider.providers.filter { providerSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(providerSearch) || $0.id.localizedCaseInsensitiveContains(providerSearch) }) { item in
                        Button {
                            provider.select(item.id, preferredModel: active?.providerID == item.id ? active?.modelID : nil)
                            showProviders = false
                        } label: {
                            HStack {
                                Text(item.name)
                                Spacer()
                                if item.configured { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.ok) }
                            }.font(Typo.callout).foregroundStyle(Theme.ink).padding(Space.ml).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.frame(width: 360, height: 350)
    }
    private func useLocal() {
        do { try settings.saveInferenceSettings(settings.inferenceSettings.onThisMac()) } catch { provider.report(error) }
    }
    /// Signing in only connects; this button, naming the provider, is what sends conversations there.
    private func useSelected(_ selected: PiProvider) {
        guard let model = selected.models.first(where: { $0.id == provider.modelID }) else { return }
        do {
            try settings.saveInferenceSettings(FirstRunSetup.activated(settings.inferenceSettings, provider: selected, model: model))
            if let (roots, agent) = try? PiSession.installation(ProcessInfo.processInfo.environment) {
                PiInstaller(roots: roots).writeOnlineModelEffort(providerID: selected.id, modelID: model.id,
                                                                 supportedEfforts: model.supportedEfforts,
                                                                 agentDirectory: agent)
            }
        } catch { provider.report(error) }
    }
}

struct ProviderLoginSheet: View {
    @ObservedObject var provider: PiProviderSettingsModel
    private let answerState = State(initialValue: "")
    private var answer: String {
        get { answerState.wrappedValue }
        nonmutating set { answerState.wrappedValue = newValue }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Text(T("Connect %@", table: "Settings", provider.selected?.name ?? "")).font(Typo.headline)
            SettingsNote(T("Pi handles the sign-in. API keys and sign-in tokens are stored in Pi’s credential file on this Mac.", table: "Settings"))
            if !provider.progress.isEmpty {
                ScrollView { Text(provider.progress).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 120)
            }
            if let code = provider.deviceCode {
                HStack(spacing: Space.l) {
                    Text(code).font(Typo.body.monospaced()).textSelection(.enabled)
                    Button(T("Copy code", table: "Settings")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) }
                        .pippa(.secondary)
                }
            }
            if let url = provider.browserURL {
                Button(T("Open sign-in page", table: "Settings")) { NSWorkspace.shared.open(url) }.pippa(.secondary)
            }
            if let prompt = provider.prompt {
                Text(prompt.message ?? "").fixedSize(horizontal: false, vertical: true)
                if prompt.type == "select" {
                    ForEach(prompt.options ?? []) { option in
                        Button(option.label) { provider.respond(option.id) }.pippa(.secondary)
                    }
                } else if prompt.type == "secret" {
                    SecureField(prompt.placeholder ?? "", text: answerState.projectedValue).textFieldStyle(.roundedBorder).onSubmit(submit)
                } else {
                    TextField(prompt.placeholder ?? "", text: answerState.projectedValue).textFieldStyle(.roundedBorder).onSubmit(submit)
                }
            } else {
                HStack(spacing: Space.m) { ProgressView().controlSize(.small); Text(T("Waiting for sign-in…", table: "Settings")) }
            }
            // One row: the way back, then the one main action when the sheet asks for typed text.
            HStack(spacing: Space.xl) {
                Spacer()
                Button(T("Cancel", table: "Settings")) { answer = ""; provider.cancel() }.keyboardShortcut(.cancelAction).pippa(.quiet)
                if let prompt = provider.prompt, prompt.type != "select" {
                    Button(T("Continue", table: "Settings"), action: submit).pippa(.primary).disabled(prompt.type == "secret" && answer.isEmpty)
                }
            }
        }
        .font(Typo.callout).foregroundStyle(Theme.ink)
        .padding(Space.x3).frame(width: 460)
        .background(Color(nsColor: Theme.chatTint))
        .onChange(of: provider.prompt?.id) { _, _ in answer = "" }
    }
    private func submit() { let value = answer; answer = ""; provider.respond(value) }
}
