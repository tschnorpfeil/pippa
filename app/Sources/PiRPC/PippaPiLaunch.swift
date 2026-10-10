import Foundation

/// How Pippa starts the real Pi. Applies to the Pippa window (PiRPCChat) and the probe program (PiRPCSpike),
/// so both measure the same thing.
///
/// - Shared agent directory: `~/.pi/agent` as in the terminal. **No** `PI_CODING_AGENT_DIR` is set here;
///   only test scripts set one so ~/.pi stays untouched.
/// - `--extension` Pippa's file tools, its helps for small models and its web access (pi-web-access). Pi runs every
///   tool without asking, as in the terminal. The person's own extensions stay active ("don't trim").
/// - `--no-context-files`: `AGENTS.md`/`CLAUDE.md` in user folders (and their parent folders) are an injection path.
/// - `--no-approve`: project-local `.pi/` settings and resources are ignored (cli.md "Prompts and process"),
///   the counterpart of `defaultProjectTrust: "never"`, without touching the person's settings.
/// - `--session-dir` in Pippa's support folder and `--session-id` per conversation (one Pi session per Pippa conversation).
/// - `--system-prompt`: Pippa's own short prompt instead of "expert coding assistant"; fixed per language (prompt cache).
/// - `--tools`: a fixed list (`tools`); `--no-skills --skill <bundle>`: only Pippa's skills.
/// - Memory and context (pippa-memory.ts, pippa-context.ts): what Pippa knows about the person from `Paths.memoryFile`
///   as its own prompt section, the `remember` tool, a quiet summary while the person reads, and a short handover into
///   the session of a new topic. Without `memoryFile` (trial runs) nothing is kept beyond the process.
public enum PippaPiLaunch {
    public struct Paths: Sendable {
        /// runtime/pippa-tools: pippa-tools.ts (search_files, list_folder, move_files, move_to_trash),
        /// pippa-assist.ts (document reader instead of raw bytes, loop brake, search results), pippa-mcp.ts
        public var extensionsDirectory: URL
        /// runtime/pippa-web/index.ts (pi-web-access with Pippa's settings); `nil`: Pi has no web access.
        public var webExtension: URL?
        /// Folder for Pi's session files, e.g. ~/Library/Application Support/Pippa/pi-sessions
        public var sessionDirectory: URL
        /// Pippa's skills (runtime/pippa-skills -> Contents/Resources/pippa-skills), loaded with `--skill`.
        public var skillsDirectory: URL?
        /// "Was Pippa über dich weiß", e.g. ~/Library/Application Support/Pippa/memory.md; `nil`: kept only per process.
        public var memoryFile: URL?
        public init(extensionsDirectory: URL, webExtension: URL?, sessionDirectory: URL, skillsDirectory: URL? = nil, memoryFile: URL? = nil) {
            self.extensionsDirectory = extensionsDirectory; self.webExtension = webExtension; self.sessionDirectory = sessionDirectory
            self.skillsDirectory = skillsDirectory; self.memoryFile = memoryFile
        }
    }

    /// What Pi starts with: Pippa's Node + CLI of the pinned release (`PiInstaller.launchSpec`). Here without the
    /// PippaCore type so PiRPC stays small; the app copies the fields from `PiLaunchSpec`.
    public struct Launcher: Sendable, Equatable {
        public var executable: URL
        /// Before all Pi options, e.g. the path to the release's cli.js (also applies to `--version`).
        public var launcherArguments: [String]
        /// Pi options from the installer, e.g. `--provider pippa-local --model <id>`.
        public var piArguments: [String]
        public var environment: [String: String]
        public init(executable: URL, launcherArguments: [String] = [], piArguments: [String] = [], environment: [String: String] = [:]) {
            self.executable = executable; self.launcherArguments = launcherArguments
            self.piArguments = piArguments; self.environment = environment
        }
    }

    /// Without this environment Pi never starts: no network at startup, no telemetry, no version check at pi.dev.
    public static let offlineEnvironment = ["PI_OFFLINE": "1", "PI_SKIP_VERSION_CHECK": "1", "PI_TELEMETRY": "0"]

    /// The one place that builds Pi's command line (app and probe program): installer launcher, Pippa's
    /// extensions, Pippa's options, session per conversation. `environment` is added last (undo folder,
    /// test switches); the offline switches cannot be overridden.
    /// `mcp`: the app's Pippa MCP server, attached via `addMCP` (extension after guard and tools).
    public static func configuration(launcher: Launcher, workingDirectory: URL, paths: Paths, sessionID: String?, language: String,
                                     environment: [String: String] = [:],
                                     mcp: (endpoint: MCPEndpoint, extension: URL)? = nil) -> PiRPCConfiguration {
        var env = launcher.environment.merging(environment) { $1 }
        if let memory = paths.memoryFile { env[memoryVariable] = memory.path }
        env.merge(offlineEnvironment) { $1 }
        var configuration = PiRPCConfiguration(executable: launcher.executable, workingDirectory: workingDirectory, environment: env,
                                               extensions: extensions(paths),
                                               arguments: launcher.piArguments + arguments(paths: paths, sessionID: sessionID, language: language))
        configuration.launcherArguments = launcher.launcherArguments
        if let mcp { addMCP(mcp.endpoint, extension: mcp.extension, to: &configuration) }
        return configuration
    }

    /// Where pippa-memory.ts keeps the person's facts.
    public static let memoryVariable = "PIPPA_MEMORY_FILE"

    /// Extensions in load order. Only these load: `arguments` passes `--no-extensions`, which keeps explicit `--extension`s.
    public static func extensions(_ paths: Paths) -> [URL] {
        ["pippa-tools.ts", "pippa-assist.ts", "pippa-memory.ts", "pippa-context.ts"].map { paths.extensionsDirectory.appendingPathComponent($0) }
            + (paths.webExtension.map { [$0] } ?? [])
    }

    /// Pi options except `--mode rpc` and `--extension` (set by PiRPCClient). `sessionID`: `nil` = do not
    /// save a session (`--no-session`, trial runs only).
    public static func arguments(paths: Paths, sessionID: String?, language: String) -> [String] {
        // Without the person's own Pi extensions and packages: one that registers a tool of the same name (pi-web-access's
        // web_search) makes Pi exit at startup, and every message failed.
        var args = ["--no-context-files", "--no-extensions", "--no-approve", "--tools", tools.joined(separator: ","), "--system-prompt", systemPrompt(language: language)]
        // Only Pippa's skills, so a same-named skill of the person never replaces the one a button means (PiSkillTurn).
        if let skills = paths.skillsDirectory { args += ["--no-skills", "--skill", skills.path] }
        if let sessionID {
            args += ["--session-dir", paths.sessionDirectory.path, "--session-id", piSessionID(sessionID)]
        } else {
            args += ["--no-session"]
        }
        return args
    }

    /// The tools Pi declares to the model, named explicitly so the person's `defaultTools` cannot widen or narrow
    /// them (cli.md "Tools"). Pi's read/bash/edit/write tools, Pippa's file tools (pippa-tools.ts), the web
    /// (pi-web-access: search, read a page), Pippa's memory (pippa-memory.ts) and Pippa's
    /// MCP server. Names Pi does not know are ignored.
    public static let tools = ["read", "bash", "edit", "write",
                               "search_files", "list_folder", "move_files", "move_to_trash", "remember",
                               "web_search", "fetch_content", "mcp__pippa__*"]

    /// Pi allows only letters, digits, `.`, `_`, `-` in session IDs, and a letter or digit at start and end
    /// (cli.md "Sessions"). Pippa's ID is `<conversation UUID>` or `<conversation UUID>:<revision UUID>`.
    public static func piSessionID(_ pippaID: String) -> String {
        var id = String(pippaID.lowercased().map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "_" })
        while let first = id.first, !(first.isLetter || first.isNumber) { id.removeFirst() }
        while let last = id.last, !(last.isLetter || last.isNumber) { id.removeLast() }
        return id.isEmpty ? "pippa" : id
    }

    /// Pippa's system prompt for Pi, per app language. Deliberately short and without date or counter: every change costs
    /// the local model a cold prompt evaluation. Today's date comes with each message instead (pippa-assist.ts). Tone from PippaCore/Resources/persona.md. What happened is told by
    /// Pippa itself (receipt from events); the prompt only demands honesty.
    public static func systemPrompt(language: String) -> String {
        language.hasPrefix("de") ? german : english
    }

    // Tool names appear only where the prompt says when to use a tool; what a tool does is in its own description.
    // How to answer a mail that proposes a time is not here: Pippa's mail results bring it along when a mail is read
    // (runtime/pippa-skills/termin-aus-mail, `PippaMCPTools.mailAppointmentHint`).
    static let german = """
    Du bist Pippa, eine Helferin auf diesem Mac für Menschen ohne Technikkenntnisse. Du erledigst Aufgaben mit Dateien, Texten, Kalender und Mail direkt mit deinen Werkzeugen; bash nur, wenn kein anderes passt.
    Antworte in der Sprache der Frage, nicht der Dokumente: ruhig, freundlich, mit du (nie Sie) und einfachen Wörtern. Erst die Antwort, kurz. Listen nur, wenn sie helfen. Keine Füllsätze, keine Emojis, kein Fachjargon.
    Halte Namen, Daten, Zahlen und Zitate genau. Rate nicht; was du nicht gelesen hast, weißt du nicht.
    Was die Person zeigt, steht mit Pfad in ihrer Nachricht; lies es selbst, PDF, Scan, Bild, Word und Mail mit mcp__pippa__read_document.
    Alltagsordner liegen im Benutzerordner, nie im Arbeitsordner: Downloads = ~/Downloads, Dokumente = ~/Documents, Schreibtisch = ~/Desktop.
    Eigene Dateien finden: search_files, nie web_search.
    Für Aktuelles (Wetter, Öffnungszeiten, Nachrichten) ruf web_search auf; nenne die Quellen mit Link. Such nie mit Namen, Beträgen, Nummern oder Adressen aus den Unterlagen der Person.
    Soll etwas geändert, eingetragen oder nachgesehen werden, ruf das passende Werkzeug gleich auf. Frag nie im Text, ob du darfst, und schreib keinen Plan aus. Lösche nie endgültig; nimm move_to_trash.
    Aufräumen oder Sortieren: list_folder, dann ein einziger move_files-Aufruf, danach kurz sagen, was wohin kam.
    Ist ein Werkzeug fehlgeschlagen, ist nichts passiert; sag das in einem Satz. Behaupte nie, etwas sei erledigt, wenn das Werkzeug es nicht bestätigt hat.
    Verschicke nie Mail; Antworten sind Entwürfe.
    """

    static let english = """
    You are Pippa, a helper on this Mac for people without technical knowledge. You get tasks with files, texts, calendar and mail done directly with your tools; bash only when no other tool fits.
    Answer in the question's language, not the documents': calm, friendly, plain words. Answer first, briefly. Lists only when they help. No filler, emojis or jargon.
    Keep names, dates, numbers and quotes exact. Don't guess; what you haven't read, you don't know.
    What the person shows you is listed with its path in their message; read it yourself, PDF, scan, image, Word and email with mcp__pippa__read_document.
    Everyday folders are in the home folder, never in the working folder: Downloads = ~/Downloads, Documents = ~/Documents, Desktop = ~/Desktop.
    Find personal files: search_files, never web_search.
    For current facts (weather, opening hours, news) call web_search and name the sources with their link. Never search with names, amounts, numbers or addresses from the person's documents.
    When something should be changed, added or looked up, call the matching tool right away. Never ask for permission in your text and don't write out a plan. Never delete for good; use move_to_trash.
    Tidying or sorting: list_folder, then one move_files call, then say briefly what went where.
    If a tool failed, nothing happened; say so in one sentence. Never claim something is done unless the tool confirmed it.
    Never send mail; replies are drafts.
    """
}
