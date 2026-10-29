import Foundation
import PiRPC

/// Skills the person saved (save_skill, runtime/pippa-tools/skill-save.ts): loaded after the bundled ones and only in
/// standard scope; a refusal never reads as done, the person's no reads as theirs.
@MainActor func runSkillLaunchChecks() {
    let t = URL(fileURLWithPath: "/fixture/pi", isDirectory: true)
    let bundled = URL(fileURLWithPath: "/fixture/Pippa.app/Contents/Resources/pippa-skills", isDirectory: true)
    let user = URL(fileURLWithPath: "/fixture/Application Support/Pippa/skills", isDirectory: true)
    let paths = PippaPiLaunch.Paths(extensionsDirectory: t, webExtension: nil, sessionDirectory: t, skillsDirectory: bundled,
                                    userSkillsDirectory: user)
    func run(_ args: [String], _ part: [String]) -> Bool {
        guard args.count >= part.count else { return false }
        return (0...(args.count - part.count)).contains { Array(args[$0..<($0 + part.count)]) == part }
    }
    let standard = PippaPiLaunch.arguments(paths: paths, sessionID: nil, language: "de")
    let draft = PippaPiLaunch.arguments(paths: paths, sessionID: nil, language: "de", actionPolicy: .draftOnly)
    check("Saved skills load after the bundled ones, never in draft scope",
          run(standard, ["--no-skills", "--skill", bundled.path, "--skill", user.path])
          && run(draft, ["--no-skills", "--skill", bundled.path]) && !draft.contains(user.path))
    let withoutBundle = PippaPiLaunch.Paths(extensionsDirectory: t, webExtension: nil, sessionDirectory: t, userSkillsDirectory: user)
    check("Without Pippa's own skills no folder of the person's is loaded",
          !PippaPiLaunch.arguments(paths: withoutBundle, sessionID: nil, language: "de").contains(user.path))

    let launcher = PippaPiLaunch.Launcher(executable: URL(fileURLWithPath: "/usr/bin/true"))
    let configured = PippaPiLaunch.configuration(launcher: launcher, workingDirectory: t, paths: paths, sessionID: nil, language: "de")
    let drafting = PippaPiLaunch.configuration(launcher: launcher, workingDirectory: t, paths: paths, sessionID: nil, language: "de",
                                               actionPolicy: .draftOnly)
    check("save_skill gets its folder and the bundled names only in standard scope",
          configured.environment[PippaPiLaunch.userSkillsVariable] == user.path
          && configured.environment["PIPPA_USER_SKILLS_DIR"] == user.path
          && configured.environment[PippaPiLaunch.bundledSkillsVariable] == bundled.path
          && drafting.environment["PIPPA_USER_SKILLS_DIR"] == nil && drafting.environment["PIPPA_BUNDLED_SKILLS_DIR"] == nil)
    check("save_skill is launched in standard scope and never in draft scope",
          PippaPiLaunch.tools.contains("save_skill") && !PiActionPolicy.draftLaunchTools.contains("save_skill")
          && !PiActionPolicy.draftTools.contains("save_skill"))

    let refused: [String: Any] = ["content": [["type": "text", "text": "Not saved"]], "details": ["pippaSkill": "not_saved"]]
    let saved: [String: Any] = ["content": [["type": "text", "text": "Saved."]],
                                "details": ["pippaSkill": "saved", "file": "/fixture/skills/x/SKILL.md"]]
    let broken: [String: Any] = ["content": [["type": "text", "text": "EACCES"]]]
    check("A save_skill refusal is a known no-effect outcome; a saved skill is done; a bare error stays a failure",
          PiTurnReceipt.classify(tool: "save_skill", isError: true, result: refused) == .blocked
          && PiTurnReceipt.classify(tool: "save_skill", isError: false, result: saved) == .done
          && PiTurnReceipt.classify(tool: "save_skill", isError: true, result: broken) == .failed)

    var receipt = PiTurnReceipt()
    let arguments = #"{"description":"Wenn eine Rechnung kommt","instructions":"Betrag prüfen.","name":"rechnungen-prufen"}"#
    let calls: [(id: String, text: String, outcome: PiActionRecord.Outcome)] = [
        ("no", "Not saved: the person said no. Do not try again in this answer.", .blocked),
        ("foreign", "Not saved: this conversation read web pages, mail or other people's content.", .blocked),
        ("yes", "Saved. Pippa can use this skill from the next conversation on.", .done),
    ]
    for (id, text, outcome) in calls {
        receipt.observe(.toolStarted(id: id, name: "save_skill", arguments: arguments))
        receipt.observe(.toolEnded(id: id, name: "save_skill", isError: outcome != .done, result: text, outcome: outcome))
    }
    let records = receipt.records
    check("Saved-skill lines name the skill; only the person's no reads as declined",
          records.map(\.action) == ["skill", "skill", "skill"]
          && records.allSatisfy { $0.name == "rechnungen-prufen" }
          && records.map(\.reason) == ["declined", nil, nil]
          && records.map(\.outcome) == [.blocked, .blocked, .done])
}
