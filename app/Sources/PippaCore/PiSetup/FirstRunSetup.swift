import Foundation

/// The first-run choice between the AI on this Mac and an online AI, as decisions the views only draw. Nothing here
/// starts a download, a sign-in or a network request: each of those needs the person's click.
public enum FirstRunSetup {
    /// Which way the setup card leads with.
    public enum Lead: Sendable, Equatable { case local, online }

    /// Online leads only when this Mac can't run the AI at all (too little memory, an Intel Mac, a missing part):
    /// a failure Try Again can't fix. Everywhere else both ways are offered, the local one first.
    public static func lead(_ state: PiSetupState) -> Lead {
        if case .failed(let problem) = state, !problem.canRetry { return .online }
        return .local
    }

    /// The setup card shows a question, a download or a problem, unless an online AI is already in use: people who
    /// connected one before never see the first-run choice again.
    public static func needsAttention(_ state: PiSetupState, usesOnlineAI: Bool) -> Bool {
        if usesOnlineAI { return false }
        switch state {
        case .askDownload, .downloading, .failed: return true
        case .preparing, .ready: return false
        }
    }

    /// The few providers the first-run sheet offers: those already signed in first, then the ones Pippa can sign
    /// into, in `PiProvider.ordered`'s order. Every other provider stays in Settings.
    public static func recommended(_ providers: [PiProvider], limit: Int = 4) -> [PiProvider] {
        let ordered = PiProvider.ordered(providers)
        let signedIn = ordered.filter(\.configured)
        let available = ordered.filter { !$0.configured && !$0.methods.isEmpty }
        return Array((signedIn + available).prefix(limit))
    }

    /// One step of the online setup sheet.
    public enum OnlineStage: Sendable, Equatable {
        /// The provider list is on its way (from Pi on this Mac, no network).
        case loading
        /// No provider list: the bridge to Pi failed. Try Again asks once more.
        case unavailable
        /// Nothing picked yet: the recommended providers.
        case choose
        /// Picked and not signed in: the sign-in buttons. Without any, the provider needs setup outside Pippa.
        case signIn(PiProvider)
        /// A sign-in runs (its own sheet asks for codes or keys).
        case signingIn(PiProvider)
        /// Signed in, but the account lists no chat models.
        case noModels(PiProvider)
        /// Signed in with models, but Pi names no default: the person picks one in Settings.
        case chooseModel(PiProvider)
        /// Signed in with a model: one button, naming the provider, switches it on.
        case activate(PiProvider, model: PiProvider.Model)
        /// This provider and model already answer.
        case inUse(PiProvider)
    }

    /// The step for the sheet's state. `picked`: the provider the person chose in this sheet (`nil` before);
    /// `modelID`: the preselected model (`PiProvider.preselected`); `active`: the Pi model in use.
    public static func onlineStage(providers: [PiProvider], picked: PiProvider?, modelID: String, loading: Bool,
                                   connecting: Bool, failed: Bool, active: PiModelSelection?) -> OnlineStage {
        if providers.isEmpty { return loading ? .loading : failed ? .unavailable : .loading }
        guard let picked else { return .choose }
        if connecting { return .signingIn(picked) }
        guard picked.configured else { return .signIn(picked) }
        if picked.models.isEmpty { return .noModels(picked) }
        guard let model = picked.models.first(where: { $0.id == modelID }) else { return .chooseModel(picked) }
        if active?.providerID == picked.id, active?.modelID == model.id { return .inUse(picked) }
        return .activate(picked, model: model)
    }

    /// What "Use <provider>" saves: the provider and model as Pi's route, and nothing else of the settings changes
    /// (abilities stay, an older Keychain connection stays saved for Settings).
    public static func activated(_ settings: InferenceSettings, provider: PiProvider, model: PiProvider.Model) -> InferenceSettings {
        var saved = settings
        saved.piModel = PiModelSelection(providerID: provider.id, modelID: model.id, providerName: provider.name, modelName: model.name)
        saved.subscriptionModel = nil; saved.policy = .localOnly
        return saved
    }
}
