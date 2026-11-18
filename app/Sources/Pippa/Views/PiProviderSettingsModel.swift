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
    func refresh(selection: PiModelSelection? = nil, online: Bool = false) {
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
                if providers.isEmpty {
                    problem = T("No providers are available. Try refreshing the list.", table: "Settings")
                    return
                }
                let preferred = selection?.providerID ?? selectedID
                let id = providers.contains(where: { $0.id == preferred }) ? preferred : providers.first?.id ?? ""
                select(id, preferredModel: selection?.modelID ?? modelID)
            } catch { if !Task.isCancelled { report(error) } }
        }
    }
    /// Signs in only: the refreshed list shows the account's models, and "Use <provider>" switches it on.
    func connect(method: String) {
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
                refresh(online: true)
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
            let saved = settings.inferenceSettings.disconnected(provider: selected.id)
            if saved != settings.inferenceSettings { try settings.saveInferenceSettings(saved) }
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
            case .failed, .signedOut: problem = T("The connection didn’t work. Please try again.", table: "Settings")
            }
        } else { problem = T("The connection didn’t work. Please try again.", table: "Settings") }
    }
}
