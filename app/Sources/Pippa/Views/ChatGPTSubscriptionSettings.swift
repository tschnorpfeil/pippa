import AppKit
import PippaCore
import SwiftUI

/// "ChatGPT (dein Abo)": sign in with Pi's own browser sign-in (PiSubscriptionAuth), then switch it on with one clear
/// sentence about what goes to OpenAI. Off goes back to the AI on this Mac and keeps the sign-in; "Sign out" ends the
/// sign-in for Pippa and Pi in the terminal alike (they share it). Never a terminal, never a token on screen.
@MainActor
final class ChatGPTSubscriptionModel: ObservableObject {
    enum Phase: Equatable { case checking, unavailable, signedOut, signingIn, signedIn(PiSubscriptionAuth.Status), problem(String) }
    @Published private(set) var phase: Phase = .checking
    private var task: Task<Void, Never>?

    private var auth: PiSubscriptionAuth? {
        guard let target = try? PiRPCChat.installTarget(ProcessInfo.processInfo.environment) else { return nil }
        return PiInstaller(roots: target.roots).subscriptionAuth()
    }

    func refresh() {
        guard let auth else { phase = .unavailable; return }
        Task {
            do {
                let status = try await auth.status()
                phase = status.signedIn ? .signedIn(status) : .signedOut
            } catch { phase = .unavailable }
        }
    }

    func signIn() {
        guard let auth, task == nil else { return }
        phase = .signingIn
        task = Task {
            do {
                let status = try await auth.signIn { url in Task { @MainActor in NSWorkspace.shared.open(url) } }
                DiagnosticsLog.shared.event("chatgpt-anmeldung", ["ergebnis": status.signedIn ? "ok" : "nicht-abo"])
                phase = status.signedIn ? .signedIn(status) : .problem(T("This sign-in isn’t a ChatGPT subscription.", table: "Settings"))
            } catch PiSubscriptionAuth.Failure.cancelled {
                phase = .signedOut
            } catch PiSubscriptionAuth.Failure.portBusy {
                DiagnosticsLog.shared.event("chatgpt-anmeldung", ["ergebnis": "port-belegt"])
                phase = .problem(T("Another sign-in is still open. Close it and try again.", table: "Settings"))
            } catch {
                DiagnosticsLog.shared.event("chatgpt-anmeldung", ["ergebnis": "fehler"])
                phase = .problem(T("The sign-in didn’t work just now. Please try again.", table: "Settings"))
            }
            task = nil
        }
    }

    func cancel() { task?.cancel() }

    func signOut(model: AppModel) {
        guard let auth else { return }
        Task {
            try? await auth.signOut()
            var settings = model.inferenceSettings
            settings.subscriptionModel = nil
            try? model.saveInferenceSettings(settings)
            refresh()
        }
    }
}

struct ChatGPTSubscriptionSettings: View {
    @ObservedObject var model: AppModel
    private let subscriptionState = StateObject(wrappedValue: ChatGPTSubscriptionModel())
    private let askState = State(initialValue: false)
    private var subscription: ChatGPTSubscriptionModel { subscriptionState.wrappedValue }

    var body: some View {
        content
            .onAppear { subscription.refresh() }
            .alert(T("Use ChatGPT for conversations?", table: "Settings"), isPresented: askState.projectedValue) {
                Button(T("Use ChatGPT", table: "Settings")) { setOn(true) }
                Button(T("Cancel", table: "Settings"), role: .cancel) {}
            } message: {
                Text(T("Your conversation and everything Pippa reads for it will be sent to OpenAI. You can switch back to the AI on this Mac at any time.", table: "Settings"))
            }
    }

    @ViewBuilder private var content: some View {
        switch subscription.phase {
        case .checking, .unavailable:
            EmptyView()
        case .signedOut, .problem:
            SettingsRow(title: T("ChatGPT (your subscription)", table: "Settings"), detail: detail) {
                Button(T("Sign in with ChatGPT", table: "Settings")) { subscription.signIn() }.pippa(.secondary)
            }
        case .signingIn:
            SettingsRow(title: T("ChatGPT (your subscription)", table: "Settings"), detail: T("Sign in in your browser. Pippa waits here.", table: "Settings")) {
                Button(T("Cancel", table: "Settings")) { subscription.cancel() }.pippa(.quiet)
            }
        case .signedIn:
            SettingsRow(title: T("ChatGPT (your subscription)", table: "Settings"), detail: detail) {
                HStack(spacing: 8) {
                    Button(T("Sign Out", table: "Settings")) { subscription.signOut(model: model) }.pippa(.quiet)
                    Toggle("", isOn: Binding(get: { model.inferenceSettings.subscriptionModel != nil },
                                             set: { on in if on { askState.wrappedValue = true } else { setOn(false) } })).labelsHidden()
                }
            }
        }
    }

    private var detail: String {
        switch subscription.phase {
        case .problem(let text): return text
        case .signedIn:
            if let id = model.inferenceSettings.subscriptionModel {
                return T("On · conversations go to OpenAI (%@).", table: "Settings", id)
            }
            return T("Signed in. Off: Pippa uses the AI on this Mac.", table: "Settings")
        default:
            return T("Uses your ChatGPT subscription instead of the AI on this Mac. You sign in in your browser.", table: "Settings")
        }
    }

    private func setOn(_ on: Bool) {
        guard case .signedIn(let status) = subscription.phase else { return }
        var settings = model.inferenceSettings
        // Pi's own default model for the provider, read live from the installed Pi.
        settings.subscriptionModel = on ? (status.defaultModel ?? status.models.first) : nil
        // One cloud service at a time: the own online service goes off.
        if on { settings.policy = .localOnly }
        try? model.saveInferenceSettings(settings)
    }
}
