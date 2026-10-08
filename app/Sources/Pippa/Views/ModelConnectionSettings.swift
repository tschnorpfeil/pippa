import SwiftUI
import PippaCore

/// The user's own online service, as plain as possible (docs/settings-simplification.md): a switch, below it only
/// service, model and key, a "Test and save" button, a "Remove" button. Switching it on is the consent: Pi then talks to
/// the service directly; context size and "remove key only" no longer exist.
/// Drafts never contain an already stored key.
struct ModelConnectionSettings: View {
    @ObservedObject var model: AppModel
    private let providerState = State(initialValue: ModelProvider.openAI)
    private let endpointState = State(initialValue: "")
    private let modelIDState = State(initialValue: "")
    /// No longer configurable: the stored value stays, new connections get the default.
    private let contextState = State(initialValue: ModelConnection().contextWindow)
    private let keyState = State(initialValue: "")
    private let storedKeyState = State(initialValue: false)
    private let identifierState = State(initialValue: UUID())
    private let busyState = State(initialValue: false)
    private let statusState = State<String?>(initialValue: nil)
    private let errorState = State(initialValue: false)

    private var blocked: Bool { model.isActiveWork || busyState.wrappedValue }
    private var savedCredentialApplies: Bool {
        guard storedKeyState.wrappedValue, let saved = model.inferenceSettings.connection,
              saved.provider == providerState.wrappedValue else { return false }
        return saved.provider != .compatible || saved.endpoint == URL(string: endpointState.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    /// On = Pi works with the service (stored as `ask` for older versions); off = this Mac only. An old "always" counts as on.
    private var onBinding: Binding<Bool> {
        Binding(get: { model.inferenceSettings.policy != .localOnly }, set: { on in
            guard !blocked else { return }
            var settings = model.inferenceSettings
            settings.policy = on ? .ask : .localOnly
            do { try model.saveInferenceSettings(settings); statusState.wrappedValue = nil }
            catch { report(error) }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(title: T("Use my own online AI", table: "Settings"), detail: explanation, divider: false) {
                Toggle("", isOn: onBinding).labelsHidden()
            }
            if onBinding.wrappedValue { form.padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 14) }
        }
        .disabled(blocked)
        .onAppear { loadDraft() }
    }

    @ViewBuilder private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            field(T("Service", table: "Settings")) {
                Picker(T("Service", table: "Settings"), selection: providerState.projectedValue) {
                    Text(verbatim: "OpenAI").tag(ModelProvider.openAI)
                    Text(verbatim: "Anthropic").tag(ModelProvider.anthropic)
                    // A custom server stays visible only for already stored connections; creating a new one is no longer possible.
                    if providerState.wrappedValue == .compatible {
                        Text(T("OpenAI-compatible", table: "Settings")).tag(ModelProvider.compatible)
                    }
                }.labelsHidden().fixedSize()
                    .onChange(of: providerState.wrappedValue) { _, _ in statusState.wrappedValue = nil }
            }
            if providerState.wrappedValue == .compatible {
                field(T("Server address", table: "Settings")) {
                    TextField("https://…/v1", text: endpointState.projectedValue)
                        .textFieldStyle(.roundedBorder).accessibilityLabel(T("Address of your server", table: "Settings"))
                }
            }
            field(T("Model ID", table: "Settings")) {
                TextField(modelPlaceholder, text: modelIDState.projectedValue)
                    .textFieldStyle(.roundedBorder).accessibilityLabel(T("Model ID", table: "Settings"))
            }
            field(T("API key", table: "Settings")) {
                SecureField(keyPlaceholder, text: keyState.projectedValue)
                    .textFieldStyle(.roundedBorder).accessibilityLabel(T("API key", table: "Settings"))
            }
            HStack(spacing: 6) {
                Image(systemName: savedCredentialApplies ? "lock.fill" : "lock")
                Text(keyNote)
            }.font(Fonts.hint).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(T("Test and Save", table: "Settings")) { testAndSave() }.pippa(.primary)
                if model.inferenceSettings.connection != nil {
                    Button(T("Remove", table: "Settings")) { removeConnection() }.pippa(.quiet)
                }
                if busyState.wrappedValue { ProgressView().controlSize(.small) }
            }
            Text(T("Saving first sends one short test message. No files and nothing from your conversations.", table: "Settings"))
                .font(Fonts.hint).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
            if let status = statusState.wrappedValue {
                Text(status).font(Fonts.hint).foregroundStyle(errorState.wrappedValue ? Theme.need : Theme.ok)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Fonts.hint).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            content()
        }
    }

    private var keyPlaceholder: String {
        if savedCredentialApplies { return T("Saved · leave empty to keep it", table: "Settings") }
        return T("Enter API key", table: "Settings")
    }

    private var keyNote: String {
        if savedCredentialApplies { return T("Key saved in your macOS Keychain", table: "Settings") }
        return T("Key will be saved in your macOS Keychain", table: "Settings")
    }

    private var modelPlaceholder: String {
        switch providerState.wrappedValue {
        case .openAI: T("Model ID from your OpenAI account", table: "Settings")
        case .anthropic: T("Model ID from your Anthropic account", table: "Settings")
        case .compatible: T("Model ID on your server", table: "Settings")
        }
    }

    private var explanation: String {
        if model.inferenceSettings.policy == .localOnly {
            return T("Off: everything stays on this Mac. On: Pippa works with your own OpenAI or Anthropic account; your conversations go there.", table: "Settings")
        }
        return T("Your conversations and what you show Pippa go to your online service. Your key stays in your macOS Keychain.", table: "Settings")
    }

    private func loadDraft() {
        guard let connection = model.inferenceSettings.connection else { return }
        identifierState.wrappedValue = connection.id
        providerState.wrappedValue = connection.provider
        endpointState.wrappedValue = connection.endpoint.absoluteString
        modelIDState.wrappedValue = connection.modelID
        contextState.wrappedValue = connection.contextWindow
        keyState.wrappedValue = ""
        storedKeyState.wrappedValue = (try? ModelCredentialStore.contains(connection.id)) == true
    }

    private func draft() throws -> ModelConnection {
        let endpoint: URL?
        if providerState.wrappedValue == .compatible {
            guard let url = URL(string: endpointState.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw SettingsConnectionError(T("Please enter a valid server address.", table: "Settings"))
            }
            endpoint = url
        } else { endpoint = nil }
        let context = contextState.wrappedValue
        let target = endpoint ?? providerState.wrappedValue.defaultEndpoint
        let saved = model.inferenceSettings.connection
        let changedRecipient = saved != nil && (saved?.provider != providerState.wrappedValue || saved?.endpoint != target)
        return try ModelConnection(id: changedRecipient ? UUID() : identifierState.wrappedValue, provider: providerState.wrappedValue,
                                   endpoint: target, modelID: modelIDState.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                   contextWindow: context).validated()
    }

    private func testAndSave() {
        guard !blocked else { return }
        do {
            let connection = try draft()
            let enteredKey = keyState.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = enteredKey.isEmpty && savedCredentialApplies ? (try ModelCredentialStore.read(connection.id) ?? "") : enteredKey
            guard connection.isLocal || !key.isEmpty else {
                throw SettingsConnectionError(T("This online connection needs an API key.", table: "Settings"))
            }
            busyState.wrappedValue = true
            statusState.wrappedValue = nil
            Task { @MainActor in
                defer { busyState.wrappedValue = false }
                do {
                    try await LocalEngine.testModelConnection(connection, apiKey: key)
                    do {
                        guard !model.isActiveWork else { throw InferenceError.busy }
                        let oldIdentifier = model.inferenceSettings.connection?.id
                        let previousKey = !enteredKey.isEmpty ? try ModelCredentialStore.read(connection.id) : nil
                        if !enteredKey.isEmpty { try ModelCredentialStore.save(enteredKey, for: connection.id) }
                        var settings = model.inferenceSettings
                        settings.connection = connection
                        do {
                            try model.saveInferenceSettings(settings)
                        } catch {
                            if !enteredKey.isEmpty {
                                if let previousKey { try? ModelCredentialStore.save(previousKey, for: connection.id) }
                                else { try? ModelCredentialStore.delete(connection.id) }
                            }
                            throw error
                        }
                        if let oldIdentifier, oldIdentifier != connection.id { try? ModelCredentialStore.delete(oldIdentifier) }
                        identifierState.wrappedValue = connection.id
                        keyState.wrappedValue = ""
                        storedKeyState.wrappedValue = (try? ModelCredentialStore.contains(connection.id)) == true
                    }
                    errorState.wrappedValue = false
                    statusState.wrappedValue = T("Connection tested and saved.", table: "Settings")
                } catch { report(error) }
            }
        } catch { report(error) }
    }

    private func removeConnection() {
        guard !blocked, let connection = model.inferenceSettings.connection else { return }
        do {
            var settings = model.inferenceSettings
            settings.connection = nil
            settings.policy = .localOnly
            let previousKey = try ModelCredentialStore.read(connection.id)
            try ModelCredentialStore.delete(connection.id)
            do { try model.saveInferenceSettings(settings) }
            catch {
                if let previousKey { try? ModelCredentialStore.save(previousKey, for: connection.id) }
                throw error
            }
            identifierState.wrappedValue = UUID()
            keyState.wrappedValue = ""
            storedKeyState.wrappedValue = false
            errorState.wrappedValue = false
            statusState.wrappedValue = T("Connection and key removed. Pippa works on this Mac again.", table: "Settings")
        } catch { report(error) }
    }

    private func report(_ error: Error) {
        errorState.wrappedValue = true
        statusState.wrappedValue = UserMessage.text(for: error, context: "verbindung")
    }
}

private struct SettingsConnectionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
