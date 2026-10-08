import Foundation

/// The Pi RPC path is the conversation path; the old in-house core no longer exists.
///
/// Decisions the app makes stand here without UI, so PippaChecks can check them.
public enum PiConversationDefault {
    /// Does the conversation run through the real Pi (RPC)? Yes in every release build.
    /// Debug only: developer captures (`PIPPA_SNAPSHOT`) show their conversation images with a stand-in
    /// (app: `SnapshotChat`) unless they explicitly ask for the real Pi (`PIPPA_PI_RPC=1`, scripts/pi-rpc-spike.sh,
    /// pi-setup-ui.sh). `PIPPA_PI_RPC=0` turns it off in debug runs.
    public static func usesPiRPC(environment: [String: String] = ProcessInfo.processInfo.environment, debug: Bool) -> Bool {
        guard debug else { return true }
        switch environment["PIPPA_PI_RPC"] {
        case "1": return true
        case "0": return false
        default: return environment["PIPPA_SNAPSHOT"] == nil
        }
    }

    /// Working folder of new Pi sessions when nothing else is set: its own empty folder in Pippa's
    /// support folder. Not home: Pi would read `~/.pi` additionally as a project folder, and Bash would run in the middle of
    /// the person's files. Anything shown always comes with an absolute path.
    public static func workingDirectory(support: URL) -> URL {
        support.appendingPathComponent("pi-work", isDirectory: true)
    }

    /// What a conversation shows while setup is not finished. Pi then does not start at all, instead of failing with
    /// a technical error.
    public enum SetupGate: Equatable, Sendable {
        /// Conversation runs.
        case open
        /// Setup still running (quiet, loading): one calm sentence, the message stays in the field.
        case wait
        /// The one question (download) or an error: show the setup (Load · Later or "Nochmal versuchen", try again).
        case showSetup(problem: String?)
    }

    /// `online`: an own online service is switched on, then the local model is not needed.
    /// `devModel` (debug only): developer runs provide the model directly (`PIPPA_MODEL_FILE`) or a running server
    /// (`PIPPA_PI_OWN_LLAMA=0`); setup then does not hold up the conversation (Pi sets itself up at startup).
    public static func gate(_ state: PiSetupState?, online: Bool, devModel: Bool) -> SetupGate {
        guard let state, !online, !devModel else { return .open }
        switch state {
        case .ready: return .open
        case .preparing, .downloading: return .wait
        case .askDownload: return .showSetup(problem: nil)
        case .failed(let problem): return .showSetup(problem: problem.message)
        }
    }

    /// Guard and Pippa's Pi extensions in the app bundle (scripts/build-app.sh: Contents/Resources/pippa-guard).
    public static func bundledGuard(bundle: URL) -> URL {
        bundle.appendingPathComponent("Contents/Resources/pippa-guard/pippa-guard.ts")
    }
}

/// Capabilities (buttons like "Einfach erklären", "Antwort schreiben") on the Pi RPC path. Pi loads the bundled skills
/// itself (`PippaPiLaunch`: `--no-skills --skill <bundle>`, so a same-named skill of the person never replaces Pippa's);
/// a button sends `/skill:<name> <message>`, which Pi expands to the instructions before the message (skills.md,
/// rpc-commands.md). Reason for the explicit command: a button press is a choice, so exactly this skill applies without
/// the model having to find it. All of Pippa's skills are `disable-model-invocation: true`: none costs prompt space.
public enum PiSkillTurn {
    /// The message to Pi. `draftOnly`: the text lands in Pippa's own row (letter), Pi should create or change nothing.
    public static func prompt(skill name: String, message: String, language: String, draftOnly: Bool = false) -> String {
        guard PippaSkill.isValid(name: name) else { return message }
        var lines: [String] = []
        if draftOnly {
            lines.append(language.hasPrefix("de") ? "Schreib nur den Text. Pippa zeigt ihn der Person; leg keinen Entwurf an und ändere nichts."
                                                  : "Write only the text. Pippa shows it to the person; do not create a draft or change anything.")
            lines.append("")
        }
        lines.append(message)
        // Pi takes the skill name up to the first space; everything after it follows the instructions.
        return "/skill:\(name) " + lines.joined(separator: "\n")
    }

    /// The command for a bundled capability; for a capability that is not bundled the message stays as it is.
    public static func prompt(for skill: PippaSkill, message: String, language: String, draftOnly: Bool = false,
                              bundled: (String) -> Bool = { name in PippaSkill.bundled.contains { $0.name == name } }) -> String {
        guard bundled(skill.name) else { return message }
        return prompt(skill: skill.name, message: message, language: language, draftOnly: draftOnly)
    }
}
