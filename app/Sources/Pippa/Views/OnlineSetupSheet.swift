import AppKit
import PippaCore
import SwiftUI

/// First run, the online way: pick one of a few providers, sign in through Pi, then switch it on with one button that
/// names the provider. Signing in alone changes nothing about where answers come from. Every other provider and model
/// stays in Settings. The chat window behind keeps its draft and attachments; a download on this Mac keeps going.
struct OnlineSetupSheet: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var setup: SetupModel
    var close: () -> Void
    private let providerState: StateObject<PiProviderSettingsModel>
    private var provider: PiProviderSettingsModel { providerState.wrappedValue }
    private let pickedState: State<String?>
    private var picked: String? {
        get { pickedState.wrappedValue }
        nonmutating set { pickedState.wrappedValue = newValue }
    }
    private let loadsOnAppear: Bool

    /// `provider`, `picked` and `loadsOnAppear: false` are for snapshots, which can't sign in.
    init(settings: SettingsModel, setup: SetupModel, provider: PiProviderSettingsModel = PiProviderSettingsModel(),
         picked: String? = nil, loadsOnAppear: Bool = true, close: @escaping () -> Void) {
        self.settings = settings; self.setup = setup; self.close = close
        providerState = StateObject(wrappedValue: provider)
        pickedState = State(initialValue: picked)
        self.loadsOnAppear = loadsOnAppear
    }

    private var pickedProvider: PiProvider? { picked.flatMap { id in provider.providers.first { $0.id == id } } }

    private var stage: FirstRunSetup.OnlineStage {
        FirstRunSetup.onlineStage(providers: provider.providers, picked: pickedProvider, modelID: provider.modelID,
                                  loading: provider.loading, connecting: provider.connecting, failed: provider.problem != nil,
                                  active: settings.inferenceSettings.activePiModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Text(T("Use an Online AI", table: "Settings")).font(Typo.headline)
            SettingsNote(T("No download. Your conversations and everything Pippa reads for them go to the provider you choose. You can switch back to this Mac at any time in Settings.", table: "Settings"))
            content
            if let problem = provider.problem, !provider.providers.isEmpty {
                Text(problem).font(Typo.footnote).foregroundStyle(Theme.need).fixedSize(horizontal: false, vertical: true)
            }
            if case .downloading = setup.state {
                SettingsNote(T("The download for this Mac keeps going.", table: "Settings"))
            }
            HStack(spacing: Space.xl) {
                Button(T("More Providers and Models…", table: "Settings")) { close(); SettingsWindow.shared.show(.ai) }
                    .pippa(.quiet).disabled(provider.connecting).fixedSize()
                Spacer()
                if picked != nil {
                    Button(T("Back", table: "Views")) { picked = nil; provider.problem = nil }.pippa(.quiet).disabled(provider.busy)
                }
                Button(T("Cancel", table: "Settings")) { provider.cancel(); close() }.keyboardShortcut(.cancelAction).pippa(.secondary)
                primaryButton
            }
        }
        .font(Typo.callout).foregroundStyle(Theme.ink)
        .padding(Space.x3).frame(width: 520)
        .background(Color(nsColor: Theme.chatTint))
        .onAppear { if loadsOnAppear { provider.refresh(selection: settings.inferenceSettings.activePiModel) } }
        .onDisappear { provider.cancel() }
        .sheet(isPresented: Binding(get: { provider.connecting }, set: { if !$0 { provider.cancel() } })) {
            ProviderLoginSheet(provider: provider)
        }
    }

    @ViewBuilder private var content: some View {
        switch stage {
        case .loading:
            HStack(spacing: Space.m) { ProgressView().controlSize(.small); Text(T("Loading providers…", table: "Settings")) }
        case .unavailable:
            HStack(spacing: Space.l) {
                Text(provider.problem ?? "").font(Typo.footnote).foregroundStyle(Theme.need).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Space.m)
                Button(T("Try again", table: "Settings")) { provider.refresh(selection: settings.inferenceSettings.activePiModel) }
                    .pippa(.secondary).disabled(provider.busy).fixedSize()
            }
        case .choose:
            VStack(spacing: Space.xs) {
                ForEach(FirstRunSetup.recommended(provider.providers)) { item in
                    Button { pick(item) } label: {
                        HStack(spacing: Space.m) {
                            Text(item.name).foregroundStyle(Theme.ink)
                            Spacer(minLength: Space.m)
                            if item.configured {
                                SettingsStatus(symbol: "checkmark.circle.fill", color: Theme.ok, text: T("Connected", table: "Settings"))
                            }
                            Image(systemName: "chevron.right").font(Typo.caption).foregroundStyle(Theme.ink3)
                        }
                        .padding(.horizontal, Space.l).padding(.vertical, Space.ml)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(provider.busy)
                }
            }
        case .signIn(let item), .signingIn(let item):
            VStack(alignment: .leading, spacing: Space.l) {
                Text(T("Sign in to %@", table: "Settings", item.name)).font(Typo.callout.weight(.semibold))
                if item.methods.isEmpty {
                    SettingsNote(T("This provider uses external configuration. Set it up in Pi, then refresh here.", table: "Settings"))
                } else {
                    ForEach(item.methods) { method in
                        Button(method.name) { provider.connect(method: method.id) }.pippa(.secondary).disabled(provider.busy)
                    }
                }
                SettingsNote(T("Signing in doesn’t switch anything yet: you choose afterwards.", table: "Settings"))
            }
        case .noModels:
            if provider.loading { ProgressView().controlSize(.small) }
            SettingsNote(T("No chat models are available for this account yet. Refresh or reconnect to try again.", table: "Settings"))
            Button(T("Try again", table: "Settings")) { provider.refresh(online: true) }.pippa(.secondary).disabled(provider.busy)
        case .chooseModel(let item):
            VStack(alignment: .leading, spacing: Space.m) {
                SettingsStatus(symbol: "checkmark.circle.fill", color: Theme.ok, text: T("Connected", table: "Settings"))
                SettingsNote(T("%@ doesn’t recommend a model. Choose one under More Providers and Models.", table: "Settings", item.name))
            }
        case .activate(let item, let model):
            connected(item, model: model.name.isEmpty ? model.id : model.name)
        case .inUse(let item):
            connected(item, model: settings.inferenceSettings.activePiModel?.modelDisplayName ?? "")
        }
    }

    private func connected(_ item: PiProvider, model: String) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.m) {
                Text(item.name).font(Typo.callout.weight(.semibold))
                SettingsStatus(symbol: "checkmark.circle.fill", color: Theme.ok, text: T("Connected", table: "Settings"))
            }
            Text(T("Model: %@", table: "Settings", model)).foregroundStyle(Theme.ink2)
            SettingsNote(T("Your conversations and everything Pippa reads for them will be sent to %@.", table: "Settings", item.name))
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch stage {
        case .activate(let item, let model):
            Button(T("Use %@", table: "Settings", item.name)) { activate(item, model) }.pippa(.primary).disabled(provider.busy)
        case .inUse:
            Button(T("Done", table: "Views")) { close() }.pippa(.primary)
        default:
            EmptyView()
        }
    }

    private func pick(_ item: PiProvider) {
        let active = settings.inferenceSettings.activePiModel
        provider.select(item.id, preferredModel: active?.providerID == item.id ? active?.modelID : nil)
        picked = item.id
        // A signed-in account lists its models only after an online catalog; one click, no sign-in.
        if item.configured && item.models.isEmpty { provider.refresh(online: true) }
    }

    private func activate(_ item: PiProvider, _ model: PiProvider.Model) {
        do {
            try settings.saveInferenceSettings(FirstRunSetup.activated(settings.inferenceSettings, provider: item, model: model))
            close()
        } catch { provider.report(error) }
    }
}
