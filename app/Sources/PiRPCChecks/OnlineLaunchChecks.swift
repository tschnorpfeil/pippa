import Foundation
import PiRPC

/// How Pippa starts Pi for an online AI (issue #193): no notes, no Mac tools, no skills, the egress guard on, its own
/// session. Nothing is started.
@MainActor func runOnlineLaunchChecks() {
    let t = URL(fileURLWithPath: "/fixture/pi", isDirectory: true)
    let memory = URL(fileURLWithPath: "/fixture/Application Support/Pippa/memory.md")
    let web = URL(fileURLWithPath: "/fixture/pippa-web/index.ts")
    let paths = PippaPiLaunch.Paths(extensionsDirectory: t, webExtension: web, sessionDirectory: t,
                                    skillsDirectory: URL(fileURLWithPath: "/fixture/skills", isDirectory: true), memoryFile: memory)
    let launcher = PippaPiLaunch.Launcher(executable: URL(fileURLWithPath: "/usr/bin/true"),
                                          environment: [PippaPiLaunch.egressVariable: "spoofed", PippaPiLaunch.memoryVariable: "/elsewhere.md"])
    func value(_ args: [String], after flag: String) -> String? {
        args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }
    let online = PippaPiLaunch.Capabilities(web: true, memory: true, online: .init(mcpTools: ["calendar_add", "mail_draft"]))
    let conversation = PippaPiLaunch.sessionID(conversation: "C0FFEE-1", scope: "online-abc")
    let configured = PippaPiLaunch.configuration(launcher: launcher, workingDirectory: t, paths: paths, sessionID: conversation,
                                                 language: "en", capabilities: online)
    let tools = value(configured.arguments, after: "--tools")?.split(separator: ",").map(String.init) ?? []

    check("Online AI: only ask, web access and the allowed writers; no read, bash, write, file tools, notes or MCP wildcard",
          tools == ["ask", "web_search", "fetch_content", "mcp__pippa__calendar_add", "mcp__pippa__mail_draft"]
          && !tools.contains { ["read", "bash", "write", "search_files", "list_folder", "move_files", "remember", "mcp__pippa__*"].contains($0) })
    check("Online AI: personal notes never load, even with the notes switch on, and no notes file reaches the extensions",
          configured.extensions == ["pippa-tools.ts", "pippa-assist.ts"].map { t.appendingPathComponent($0) } + [web]
          && configured.environment[PippaPiLaunch.memoryVariable] == nil)
    check("Online AI: the extensions' guard gets exactly the tool list; a spoofed value from elsewhere is replaced",
          configured.environment[PippaPiLaunch.egressVariable] == "online"
          && configured.environment[PippaPiLaunch.egressToolsVariable] == tools.joined(separator: ","))
    check("Online AI: no skills to open, its own session beside the conversation's",
          configured.arguments.contains("--no-skills") && !configured.arguments.contains("--skill")
          && value(configured.arguments, after: "--session-id") == "c0ffee-1_online-abc"
          && PippaPiLaunch.sessionID(conversation: "C0FFEE-1", scope: nil) == "C0FFEE-1")
    check("Online AI: native readiness expects exactly the allowed writers; the AI on this Mac all twelve",
          PippaPiLaunch.nativeTools(online) == ["mcp__pippa__calendar_add", "mcp__pippa__mail_draft"]
          && PippaPiLaunch.nativeTools(.all) == PiNativeReadiness.tools)
    let noWeb = PippaPiLaunch.Capabilities(web: false, memory: false, online: .init())
    check("Online AI with web access off and every source on “Only on this Mac”: only ask",
          PippaPiLaunch.tools(noWeb) == ["ask"] && PippaPiLaunch.extensions(paths, capabilities: noWeb) == ["pippa-tools.ts", "pippa-assist.ts"].map { t.appendingPathComponent($0) })
    let local = PippaPiLaunch.configuration(launcher: PippaPiLaunch.Launcher(executable: URL(fileURLWithPath: "/usr/bin/true"),
                                                                              environment: [PippaPiLaunch.egressVariable: "online"]),
                                            workingDirectory: t, paths: paths, sessionID: "C0FFEE-1", language: "en")
    check("Back on this Mac: everything as before, and no egress setting survives from anywhere",
          local.environment[PippaPiLaunch.egressVariable] == nil && local.environment[PippaPiLaunch.memoryVariable] == memory.path
          && value(local.arguments, after: "--tools") == PippaPiLaunch.tools.joined(separator: ",")
          && online.key != PippaPiLaunch.Capabilities.all.key && online.key != noWeb.key)
}
