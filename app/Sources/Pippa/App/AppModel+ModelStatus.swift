import PippaCore
import SwiftUI

// What Pippa says about her knowledge (the model): readiness, download line, reasons why the chat
// cannot answer right now. Derived texts only; loading and state live in AppModel.
extension AppModel {
    var modelReady: Bool { modelStatus == .ready }
    /// Model work is possible: local model loaded or a connected model set up.
    var canRunModelWork: Bool { modelReady || hasConfiguredInference }

    /// Asks before the first load: model is missing and the person has not agreed yet.
    var needsDownloadConsent: Bool {
        if let setup = PiSetupController.shared {
            if alwaysUsesConnection { return false }
            if case .askDownload = setup.state { return true }
            return false
        }
        return !alwaysUsesConnection && !mayPrepareWithoutAsking
    }

    /// Pi path: setup stopped with an error that "Try Again" can fix.
    var piSetupFailed: Bool {
        if case .failed(let problem)? = PiSetupController.shared?.state { return problem.canRetry }
        return false
    }

    /// Pi path (default): Pippa's AI is loaded and set up for Pi. The old engine's `modelReady` says nothing there.
    var aiLoaded: Bool { PiSetupController.shared?.isReady ?? modelReady }

    /// Pi path: what the setup is doing, in the same words as the old path. `nil` = not the Pi path.
    private var piSetupText: String?? {
        guard let setup = PiSetupController.shared else { return nil }
        if alwaysUsesConnection { return .some(nil) }
        switch setup.state {
        case .ready: return .some(nil)
        case .askDownload(let bytes): return T("Pippa’s AI isn’t loaded yet (%@)", table: "App", ModelDownloadSize.gigabytes(bytes))
        case .preparing(let source):
            if let source { return T("Pippa’s AI is already in %@ and is being adopted", table: "App", source) }
            return T("Pippa is getting ready to load…", table: "App")
        case .downloading(let progress, let remaining):
            if setup.stalled { return Self.offlineText }
            var s = T("Pippa is loading her AI · %lld %%", table: "App", Int((progress * 100).rounded()))
            if let r = remaining, r > 0 { s += " · \(Self.remainingText(r))" }
            return s
        case .failed(let problem): return problem.message
        }
    }

    /// The one rule for whether Pippa may prepare without asking: consent given, model already present, or everything lies
    /// with another program (then nothing goes onto the network, see `prepareModel(allowDownload:)`).
    var mayPrepareWithoutAsking: Bool {
        downloadAllowed || modelStatus != .notInstalled || canAdoptWithoutDownload
    }

    /// Everything needed already lies with another program (LM Studio, Ollama …): adopting needs no internet,
    /// so no consent either.
    var canAdoptWithoutDownload: Bool {
        guard let size = downloadSize else { return false }
        return size.remaining == 0 && size.existing > 0
    }

    /// Why the chat cannot answer right now (for the send button and system line); `nil` = it can.
    var chatBlockedReason: String? {
        if hasConfiguredInference { return nil }
        if let reason = unsupportedReason { return reason }
        guard chatReadiness == .unavailable else { return nil }
        var text = T("I need my AI to answer.", table: "App")
        switch modelStatus {
        case .downloading(_, let remaining):
            if let remaining {
                text += " " + T("It’s loading right now, %@.", table: "App", Self.remainingText(remaining))
            } else {
                text += " " + T("It’s loading right now.", table: "App")
            }
        case .notInstalled where !downloadAllowed:
            if !canAdoptWithoutDownload {
                text += " " + T("You can load it in Settings.", table: "App")
            }
        case .loading:
            text += " " + T("I’m just waking up.", table: "App")
        default: break
        }
        return text
    }

    /// Honest: what works immediately and what is added after loading.
    var capabilityText: String {
        T("Ready now: tidying up, overviews and deadlines. Once my AI has loaded, invoices and large documents join in, and I’ll sort unclear documents more carefully.", table: "App")
    }

    var isDownloading: Bool {
        if let setup = PiSetupController.shared {
            if case .downloading = setup.state { return true }
            return false
        }
        if case .downloading = modelStatus { return true }
        return false
    }

    nonisolated static var offlineText: String { T("I can’t get online right now. I’ll keep trying.", table: "App") }

    var learningText: String? {
        if let pi = piSetupText { return pi }
        if alwaysUsesConnection { return nil }
        if downloadStalled, modelStatus != .ready { return Self.offlineText }
        if let note = downloadNote, modelStatus != .ready { return note }
        switch modelStatus {
        case .downloading(let progress, _) where canAdoptWithoutDownload:
            return T("Pippa is adopting her AI from %@ · %lld %%", table: "App",
                     downloadSize?.existingSource ?? T("another app", table: "App"), Int((progress * 100).rounded()))
        case .downloading(let progress, let remaining):
            let percent = Int((progress * 100).rounded())
            var s = T("Pippa is loading her AI · %lld %%", table: "App", percent)
            if let r = remaining, r > 0 { s += " · \(Self.remainingText(r))" }
            return s
        case .notInstalled:
            if downloadAllowed { return T("Pippa is getting ready to load…", table: "App") }
            if canAdoptWithoutDownload {
                return T("Pippa’s AI is already in %@ and is being adopted", table: "App",
                         downloadSize?.existingSource ?? T("another app", table: "App"))
            }
            if let size = downloadSize {
                return T("Pippa’s AI isn’t loaded yet (%@)", table: "App", ModelDownloadSize.gigabytes(size.remaining))
            }
            return T("Pippa’s AI isn’t loaded yet", table: "App")
        case .loading: return T("Pippa is waking up…", table: "App")
        case .failed(let reason): return reason
        default: return nil
        }
    }

    var progressValue: Double? {
        if let setup = PiSetupController.shared {
            if case .downloading(let p, _) = setup.state { return p }
            return nil
        }
        if case .downloading(let p, _) = modelStatus { return p }
        return nil
    }

    var unsupportedReason: String? {
        if alwaysUsesConnection { return nil }
        if case .unsupported(let reason) = modelStatus { return reason }
        return nil
    }

    static func remainingText(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return T("almost done", table: "App") }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return T("about %lld min left", table: "App", minutes) }
        let hours = Int((Double(minutes) / 60).rounded())
        return T("about %lld hr left", table: "App", hours)
    }
}
