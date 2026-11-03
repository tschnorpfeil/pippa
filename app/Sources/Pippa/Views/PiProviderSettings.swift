import AppKit
import PippaCore
import SwiftUI

@MainActor
final class PiProviderSettingsModel: ObservableObject {
    @Published var providers: [PiProvider] = []
    @Published var selectedID = "openai"
    @Published var modelID = ""
    @Published var loading = false
    @Published var connecting = false
    @Published var problem: String?
    @Published var prompt: PiProviderEvent?
    @Published var progress = ""
    @Published var browserURL: URL?
    @Published var deviceCode: String?
    private var operation: PiProviderClient?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    var selected: PiProvider? { providers.first { $0.id == selectedID } }
    var busy: Bool { loading || connecting }
    private func client() -> PiProviderClient? {
        guard let target = try? PiSession.installation(ProcessInfo.processInfo.environment) else { return nil }
        return PiProviderClient.bundled(roots: target.roots, agentDirectory: target.agent)
    }
    func select(_ id: String, preferredModel: String? = nil) {
        selectedID = id
        guard let selected else { modelID = ""; return }
        modelID = selected.preselected(preferredModel)
        problem = nil
    }
    func refresh(selection: PiModelSelection? = nil, online: Bool = false, then done: ((PiProvider) -> Void)? = nil) {
        guard !busy else { return }
        guard let client = client() else { problem = T("The provider setup is unavailable. Please reopen Pippa.", table: "Settings"); return }
        loading = true; problem = nil
        operation = client
        let generation = UUID(); self.generation = generation
        task = Task {
            defer { if self.generation == generation { loading = false; operation = nil; task = nil } }
            do {
                let result = try await client.run(online ? ["catalog", selectedID] : ["catalog"])
                guard self.generation == generation, !Task.isCancelled else { return }
                providers = PiProvider.ordered(result.providers ?? [])
                let preferred = selection?.providerID ?? selectedID
                let id = providers.contains(where: { $0.id == preferred }) ? preferred : providers.first?.id ?? ""
                select(id, preferredModel: selection?.modelID ?? modelID)
                if let done, let selected = self.selected { done(selected) }
            } catch { if !Task.isCancelled { report(error) } }
        }
    }
    /// `connected`: after a successful sign-in, with the refreshed provider (its models and Pi's default).
    func connect(method: String, connected: ((PiProvider) -> Void)? = nil) {
        guard !busy, let selected, let client = client() else { return }
        connecting = true; problem = nil; prompt = nil; progress = ""; browserURL = nil; deviceCode = nil
        operation = client
        let generation = UUID(); self.generation = generation
        task = Task {
            do {
                _ = try await client.run(["login", selected.id, method]) { [self] event in
                    Task { @MainActor in
                        guard self.generation == generation, self.connecting else { return }
                        self.receive(event)
                    }
                }
                guard self.generation == generation, !Task.isCancelled else { return }
                connecting = false; operation = nil; task = nil; prompt = nil
                refresh(online: true, then: connected)
            } catch {
                guard self.generation == generation else { return }
                connecting = false; operation = nil; task = nil; prompt = nil
                if !Task.isCancelled { report(error) }
            }
        }
    }
    private func receive(_ event: PiProviderEvent) {
        switch event.event {
        case "prompt": prompt = event
        case "dismiss": if prompt?.id == event.id { prompt = nil }
        case "open":
            if let url = Self.webURL(event.url) { browserURL = url; NSWorkspace.shared.open(url) }
            progress = event.instructions ?? ""
        case "device_code":
            deviceCode = event.userCode
            browserURL = Self.webURL(event.verificationUri)
        case "progress", "info": progress = event.message ?? ""
        default: break
        }
    }
    static func webURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
    func respond(_ value: String) {
        guard let id = prompt?.id else { return }
        do { try operation?.respond(id: id, value: value); prompt = nil }
        catch { report(error) }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); operation?.cancel()
        task = nil; operation = nil; connecting = false; loading = false; prompt = nil
    }
    func disconnect(settings: SettingsModel) {
        guard !busy, let selected, let client = client() else { return }
        do {
            if settings.inferenceSettings.activePiModel?.providerID == selected.id {
                var saved = settings.inferenceSettings
                saved.piModel = nil; saved.subscriptionModel = nil; saved.policy = .localOnly
                try settings.saveInferenceSettings(saved)
            }
        } catch { report(error); return }
        loading = true; operation = client
        let generation = UUID(); self.generation = generation
        task = Task {
            do {
                _ = try await client.run(["logout", selected.id])
                guard self.generation == generation, !Task.isCancelled else { return }
                loading = false; operation = nil; task = nil
                refresh()
            } catch {
                guard self.generation == generation else { return }
                loading = false; operation = nil; task = nil; report(error)
            }
        }
    }
    func report(_ error: Error) {
        if let failure = error as? PiProviderClient.Failure {
            switch failure {
            case .cancelled: return
            case .portBusy: problem = T("Another sign-in is still open. Close it and try again.", table: "Settings")
            case .unavailable: problem = T("The provider setup is unavailable. Please reopen Pippa.", table: "Settings")
            case .failed: problem = T("The connection didn’t work. Please try again.", table: "Settings")
            }
        } else { problem = T("The connection didn’t work. Please try again.", table: "Settings") }
    }
}

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
        (provider.selected?.models ?? []).filter {
            modelSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(modelSearch) || $0.id.localizedCaseInsensitiveContains(modelSearch)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(T("Online AI", table: "Settings")).font(.headline)
                    Text(active.map { T("Using %@ · %@", table: "Settings", $0.providerName, $0.modelID) }
                         ?? (PiOnlineProvider.activeConnection(settings.inferenceSettings).map { T("Using %@ · %@", table: "Settings", $0.provider.displayName, $0.modelID) }
                             ?? T("Off · Pippa uses the AI on this Mac.", table: "Settings")))
                        .font(.caption).foregroundStyle(Theme.ink2).textSelection(.enabled)
                }
                Spacer()
                if settings.inferenceSettings.usesOnlineAI {
                    Button(T("Use this Mac", table: "Settings")) { useLocal() }.pippa(.secondary).disabled(blocked)
                }
            }
            Text(T("Connect an account, choose a model, and use it for conversations. You can switch back at any time.", table: "Settings"))
                .font(.callout).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            if provider.providers.isEmpty && provider.loading {
                HStack { ProgressView().controlSize(.small); Text(T("Loading providers…", table: "Settings")) }.font(.callout)
            } else if !provider.providers.isEmpty {
                providerFields
            }
            if let problem = provider.problem {
                Text(problem).font(.caption).foregroundStyle(Theme.need).fixedSize(horizontal: false, vertical: true)
                if provider.providers.isEmpty {
                    Button(T("Try again", table: "Settings")) { provider.refresh(selection: active) }.disabled(blocked)
                }
            }
        }
        // A row of the settings form: the form already insets it, a second inset made it look nested.
        .padding(.vertical, Space.xs)
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

    private var providerFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(T("Provider", table: "Settings")).foregroundStyle(Theme.ink2)
                Spacer()
                Button { showProviders = true } label: {
                    HStack(spacing: 8) {
                        Text(provider.selected?.name ?? T("Choose a provider", table: "Settings"))
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                }.pippa(.secondary).disabled(blocked)
                    .popover(isPresented: showProvidersState.projectedValue) { providerPicker }
            }
            if let selected = provider.selected {
                HStack(spacing: 6) {
                    Image(systemName: selected.configured ? "checkmark.circle.fill" : "person.crop.circle")
                    Text(selected.configured ? T("Connected", table: "Settings") : T("Connect your account", table: "Settings"))
                    Spacer()
                    if selected.configured {
                        if !selected.methods.isEmpty {
                            Menu(T("Reconnect", table: "Settings")) {
                                ForEach(selected.methods) { method in
                                    Button(method.name) { provider.connect(method: method.id, connected: signedIn) }
                                }
                            }.menuStyle(.borderlessButton).fixedSize().disabled(blocked)
                        }
                        Button(T("Disconnect", table: "Settings")) { confirmDisconnect = true }.pippa(.quiet).disabled(blocked)
                    }
                }.font(.caption).foregroundStyle(selected.configured ? Theme.ok : Theme.ink2)
                if !selected.configured || selected.models.isEmpty {
                    ForEach(selected.methods) { method in
                        Button(method.name) { provider.connect(method: method.id, connected: signedIn) }.pippa(.secondary).disabled(blocked)
                    }
                    Text(T("Sign-in and credentials are managed by Pi and shared with Pi in Terminal.", table: "Settings"))
                        .font(.caption).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
                    if selected.methods.isEmpty {
                        Text(T("This provider uses external configuration. Set it up in Pi, then refresh here.", table: "Settings"))
                            .font(.caption).foregroundStyle(Theme.ink2)
                    }
                }
                if selected.configured && !selected.models.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(T("Choose a model", table: "Settings")).font(.caption).foregroundStyle(Theme.ink2)
                        TextField("", text: modelSearchState.projectedValue, prompt: Text(T("Search models", table: "Settings")))
                            .textFieldStyle(.roundedBorder).labelsHidden().accessibilityLabel(T("Search models", table: "Settings"))
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 2) {
                                    ForEach(matchingModels) { model in
                                        Button { provider.modelID = model.id } label: {
                                            HStack(spacing: 8) {
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(model.name).font(.callout).foregroundStyle(Theme.ink).lineLimit(1)
                                                    if model.name != model.id { Text(model.id).font(.caption2).foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.middle) }
                                                }
                                                Spacer(minLength: 4)
                                                if provider.modelID == model.id { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                                            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                                .background(provider.modelID == model.id ? Theme.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
                                                .contentShape(Rectangle())
                                        }.buttonStyle(.plain).id(model.id).disabled(blocked)
                                            .accessibilityAddTraits(provider.modelID == model.id ? .isSelected : [])
                                    }
                                    if matchingModels.isEmpty { Text(T("No matching models", table: "Settings")).font(.caption).padding(8) }
                                }
                            }.frame(height: 142)
                                .onAppear { proxy.scrollTo(provider.modelID, anchor: .center) }
                        }
                    }
                    Text(T("Your conversations and everything Pippa reads for them will be sent to %@.", table: "Settings", selected.name))
                        .font(.caption).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                    Button(T("Use %@", table: "Settings", selected.name)) { useSelected(selected) }.pippa(.primary)
                        .disabled(blocked || !selected.configured || !selected.models.contains(where: { $0.id == provider.modelID })
                                  || (active?.providerID == selected.id && active?.modelID == provider.modelID))
                } else if selected.configured {
                    Text(T("No chat models are available for this account yet. Refresh or reconnect to try again.", table: "Settings"))
                        .font(.caption).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(T("Refresh providers", table: "Settings")) { provider.refresh(online: true) }.pippa(.quiet).disabled(blocked)
        }
        .onChange(of: provider.selectedID) { _, _ in modelSearch = "" }
    }

    private var providerPicker: some View {
        VStack(spacing: 8) {
            TextField(T("Search providers", table: "Settings"), text: providerSearchState.projectedValue).textFieldStyle(.roundedBorder).padding(10)
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
                            }.foregroundStyle(Theme.ink).padding(10).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.frame(width: 330, height: 350)
    }
    private func useLocal() {
        var saved = settings.inferenceSettings
        saved.piModel = nil; saved.subscriptionModel = nil; saved.policy = .localOnly
        do { try settings.saveInferenceSettings(saved) } catch { provider.report(error) }
    }
    /// Signing in is the person's choice of this provider: without another online AI in use, Pippa uses it right away
    /// with Pi's default model, instead of leaving "Connected" while answers still come from this Mac.
    private func signedIn(_ selected: PiProvider) {
        let current = settings.inferenceSettings
        guard current.activePiModel == nil || current.activePiModel?.providerID == selected.id,
              PiOnlineProvider.activeConnection(current) == nil,
              selected.configured, selected.models.contains(where: { $0.id == provider.modelID }) else { return }
        useSelected(selected)
    }

    private func useSelected(_ selected: PiProvider) {
        var saved = settings.inferenceSettings
        saved.piModel = PiModelSelection(providerID: selected.id, modelID: provider.modelID, providerName: selected.name)
        saved.subscriptionModel = nil; saved.policy = .localOnly
        do { try settings.saveInferenceSettings(saved) } catch { provider.report(error) }
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
        VStack(alignment: .leading, spacing: 16) {
            Text(T("Connect %@", table: "Settings", provider.selected?.name ?? "")).font(.title2.weight(.semibold))
            Text(T("Pi handles the sign-in. API keys and sign-in tokens are stored in Pi’s credential file on this Mac.", table: "Settings"))
                .font(.callout).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            if !provider.progress.isEmpty {
                ScrollView { Text(provider.progress).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 120)
            }
            if let code = provider.deviceCode {
                HStack { Text(code).font(.title3.monospaced()).textSelection(.enabled)
                    Button(T("Copy code", table: "Settings")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) }
                }
            }
            if let url = provider.browserURL {
                Button(T("Open sign-in page", table: "Settings")) { NSWorkspace.shared.open(url) }.pippa(.secondary)
            }
            if let prompt = provider.prompt {
                Text(prompt.message ?? "").font(.callout).fixedSize(horizontal: false, vertical: true)
                if prompt.type == "select" {
                    ForEach(prompt.options ?? []) { option in
                        Button(option.label) { provider.respond(option.id) }.pippa(.secondary)
                    }
                } else {
                    if prompt.type == "secret" { SecureField(prompt.placeholder ?? "", text: answerState.projectedValue).textFieldStyle(.roundedBorder).onSubmit(submit) }
                    else { TextField(prompt.placeholder ?? "", text: answerState.projectedValue).textFieldStyle(.roundedBorder).onSubmit(submit) }
                    Button(T("Continue", table: "Settings"), action: submit).pippa(.primary).disabled(prompt.type == "secret" && answer.isEmpty)
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text(T("Waiting for sign-in…", table: "Settings")) }.font(.callout)
            }
            HStack { Spacer(); Button(T("Cancel", table: "Settings")) { answer = ""; provider.cancel() }.keyboardShortcut(.cancelAction) }
        }
        .padding(24).frame(width: 460)
        .onChange(of: provider.prompt?.id) { _, _ in answer = "" }
    }
    private func submit() { let value = answer; answer = ""; provider.respond(value) }
}
