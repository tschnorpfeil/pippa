import Foundation

/// Small settings file (settings.json) in the support folder.
public struct PippaSettings: Codable, Sendable, Equatable {
    /// Fixed port of the local server for Pi's models.json (`PiInstaller.stablePort`); chosen once. Stored under the
    /// old key so an existing setup keeps its port.
    public var serverPort: Int?
    /// On by default: short shown text documents go straight into Pi's message (`nil` = on).
    public var piInlineShortText: Bool?
    /// The model whose first download the person agreed to ("Set Up"): an interrupted download goes on by itself at
    /// the next start. `nil`: no consent kept.
    public var downloadConsent: String?

    enum CodingKeys: String, CodingKey {
        case serverPort = "llamaPort", piInlineShortText, downloadConsent
    }

    public init(serverPort: Int? = nil, piInlineShortText: Bool? = nil) {
        self.serverPort = serverPort; self.piInlineShortText = piInlineShortText
    }

    /// Change only the kept download consent (load, change, save); nothing is written when it is already so.
    public static func saveDownloadConsent(_ key: String?, to base: URL) throws {
        var settings = load(from: base)
        guard settings.downloadConsent != key else { return }
        settings.downloadConsent = key
        try settings.save(to: base)
    }

    /// Missing or unreadable settings mean defaults; a file that exists but does not decode is logged.
    public static func load(from base: URL) -> PippaSettings {
        guard let data = try? Data(contentsOf: base.appendingPathComponent("settings.json")) else { return PippaSettings() }
        do { return try JSONDecoder().decode(PippaSettings.self, from: data) }
        catch { UserMessage.record(error, context: "settings-load"); return PippaSettings() }
    }

    public func save(to base: URL) throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: base.appendingPathComponent("settings.json"), options: .atomic)
    }
}
