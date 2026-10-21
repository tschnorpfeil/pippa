import Foundation

/// A fresh Pi process must prove that Pippa's own MCP tools reached its active tool registry. This is a local
/// extension command, never a model request. Names alone do not establish server identity: the extension also
/// uses a scoped Pi connector without shared MCP configuration and checks the app-provided endpoint registration.
public enum PiNativeReadiness {
    public static let command = "pippa-native-ready"
    public static let tools = ["calendar_read", "reminders_read", "mail_selected", "mail_search", "excel_selection",
                               "photos_search", "front_read", "read_document", "calendar_add", "reminder_add", "mail_draft"]
        .map { "mcp__pippa__" + $0 }

    public enum Failure: String, Error, Sendable, Equatable {
        case commandMissing, toolsUnavailable, registrationMismatch
        case invalidReceipt, timedOut, cancelled
    }

    static func hasCommand(_ data: Data?) -> Bool {
        struct Commands: Decodable { struct Command: Decodable { let name: String; let source: String }; let commands: [Command] }
        guard let data, let result = try? JSONDecoder().decode(Commands.self, from: data) else { return false }
        return result.commands.filter { $0.name == command }.count == 1
            && result.commands.contains { $0.name == command && $0.source == "extension" }
    }

    static func validate(_ text: String, nonce: String) throws {
        struct Receipt: Decodable { let v: Int; let nonce: String; let status: String; let tools: [String]? }
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: Data(text.utf8)),
              receipt.v == 1, receipt.nonce == nonce else { throw Failure.invalidReceipt }
        if receipt.status != "ready" { throw Failure(rawValue: receipt.status) ?? .invalidReceipt }
        guard let tools = receipt.tools, Set(Self.tools).isSubset(of: Set(tools)) else { throw Failure.invalidReceipt }
    }
}

extension PiRPCClient {
    /// The outer deadline also bounds get_commands, a missing acknowledgement and a broken extension command.
    /// Rejecting admission terminates this process and releases pending continuations before the race is joined.
    public func verifyNativeTools(timeout: Duration = .seconds(12)) async throws {
        try Task.checkCancellation()
        let attempt = try beginNativeReadiness()
        defer { finishNativeReadiness(attempt) }
        do {
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await self.nativeReadinessRoundTrip(nonce: attempt.uuidString) }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        await self.rejectNativeReadiness(attempt, error: .timedOut)
                        throw PiNativeReadiness.Failure.timedOut
                    }
                    defer { group.cancelAll() }
                    try await group.next()
                }
                try Task.checkCancellation()
            } onCancel: {
                Task { await self.rejectNativeReadiness(attempt, error: .cancelled) }
            }
        } catch {
            rejectNativeReadiness(attempt, error: error as? PiNativeReadiness.Failure ?? .invalidReceipt)
            throw error
        }
    }

    private func nativeReadinessRoundTrip(nonce: String) async throws {
        let commands = try await command(["type": "get_commands"])
        guard PiNativeReadiness.hasCommand(commands) else { throw PiNativeReadiness.Failure.commandMissing }
        // Unknown slash commands can reach the model, so never send this until get_commands confirms ownership.
        var received = false
        for try await event in try await prompt("/" + PiNativeReadiness.command + " " + nonce) {
            guard case .notice(let text, let kind) = event, kind == PiNativeReadiness.command, !received else {
                throw PiNativeReadiness.Failure.invalidReceipt
            }
            try PiNativeReadiness.validate(text, nonce: nonce)
            received = true
        }
        guard received else { throw PiNativeReadiness.Failure.invalidReceipt }
    }
}
