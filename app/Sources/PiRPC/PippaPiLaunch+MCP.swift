import Foundation

/// Attaches Pippa's MCP server (Calendar, Reminders, Mail, read Excel) to a
/// Pi launch. Deliberately its own file and function, separate from the rest of the launch (`PippaPiLaunch.swift`).
///
/// The server runs in the app itself on 127.0.0.1 (PippaCore/MCP/PippaMCPServer.swift). The extension
/// `runtime/pippa-tools/pippa-mcp.ts` registers it via `pi.registerMcpServer`, so only for this session: no entry
/// in `~/.pi/agent/mcp.json`, the terminal Pi does not see it.
extension PippaPiLaunch {
    public struct MCPEndpoint: Sendable, Equatable {
        /// `http://127.0.0.1:<port>/mcp`
        public var url: URL
        /// Key per app launch (64 hex characters).
        public var token: String
        /// `direct` (default: tools are available to the model like built-in ones) or `codemode` (measurement only).
        public var exposure: String
        public init(url: URL, token: String, exposure: String = "direct") {
            self.url = url; self.token = token; self.exposure = exposure
        }
    }

    /// Attaches the extension (after guard and file tools) and gives address and key only to this Pi.
    public static func addMCP(_ endpoint: MCPEndpoint, extension file: URL, to configuration: inout PiRPCConfiguration) {
        if !configuration.extensions.contains(file) { configuration.extensions.append(file) }
        configuration.environment["PIPPA_MCP_URL"] = endpoint.url.absoluteString
        configuration.environment["PIPPA_MCP_TOKEN"] = endpoint.token
        configuration.environment["PIPPA_MCP_EXPOSURE"] = endpoint.exposure
    }
}
