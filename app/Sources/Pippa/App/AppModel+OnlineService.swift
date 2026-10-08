import AppKit
import PippaCore

// Pippa's "own online service" setting. The connection uses only Pi's conversation, via Pippa's broker with
// approval per request (PippaOnlineService, PiRPCChat.launchRoute). Fixed flows (sorting, invoices, deadlines,
// letter) always run on the local model; there is no per-task approval card anymore.
extension AppModel {
    static var inferenceSettingsDirectory: URL {
        if let path = DevEnvironment.value("PIPPA_SNAPSHOT") {
            return URL(fileURLWithPath: path).appendingPathComponent("settings")
        }
        return Pippa.supportDirectory
    }

    var hasConfiguredInference: Bool {
        inferenceSettings.policy != .localOnly && inferenceSettings.connection != nil
    }

    /// Does the connected model always do the work (policy "always", or it runs on this Mac itself)?
    /// Only then Pippa does not need to prepare the local model.
    var alwaysUsesConnection: Bool {
        guard hasConfiguredInference, let connection = inferenceSettings.connection else { return false }
        return inferenceSettings.policy == .customAlways || connection.isLocal
    }

    nonisolated static var localStatus: String { T("Locally on this Mac", table: "App") }

    /// For the menu: where Pippa is currently working, according to Settings.
    var inferenceSummary: String {
        guard hasConfiguredInference, let connection = inferenceSettings.connection else { return T("Runs on this Mac", table: "App") }
        if connection.isLocal { return T("On this Mac · Connected service", table: "App") }
        if inferenceSettings.policy == .ask { return T("Asks before sending to %@", table: "App", connection.destination) }
        return T("Online · %@", table: "App", connection.destination)
    }

    func saveInferenceSettings(_ settings: InferenceSettings) throws {
        guard !isActiveWork else { throw InferenceError.busy }
        try settings.save(to: Self.inferenceSettingsDirectory)
        let wasConnectionOnly = alwaysUsesConnection
        inferenceSettings = settings
        inferenceSettingsDidChange(wasConnectionOnly: wasConnectionOnly)
    }
}
