import Foundation

/// The Pi RPC path is the conversation path; the old in-house core no longer exists.
///
/// Decisions the app makes stand here without UI, so PippaChecks can check them.
public enum PiConversationDefault {

    /// Working folder of new Pi sessions when nothing else is set: its own empty folder in Pippa's
    /// support folder. Not home: Pi would read `~/.pi` additionally as a project folder, and Bash would run in the middle of
    /// the person's files. Anything shown always comes with an absolute path.
    public static func workingDirectory(support: URL) -> URL {
        support.appendingPathComponent("pi-work", isDirectory: true)
    }

    /// "Was Pippa über dich weiß": one fact per line, written by Pi's `remember` tool (runtime/pippa-tools/pippa-memory.ts).
    public static func memoryFile(support: URL) -> URL {
        support.appendingPathComponent("memory.md")
    }

    /// Notes on documents too long to read at once, one Markdown file per document (runtime/pippa-tools/digest.ts).
    public static func digestDirectory(support: URL) -> URL {
        support.appendingPathComponent("digests", isDirectory: true)
    }

    /// Pippa's Pi extensions in the app bundle (scripts/build-app.sh: Contents/Resources/pippa-tools): file tools,
    /// helps for small models, the MCP connection.
    public static func bundledExtensions(bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Resources/pippa-tools", isDirectory: true)
    }

    /// Web access for Pi in the app bundle (scripts/bundle-web.sh: Contents/Resources/pippa-web, pi-web-access).
    public static func bundledWeb(bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Resources/pippa-web/index.ts")
    }
}
