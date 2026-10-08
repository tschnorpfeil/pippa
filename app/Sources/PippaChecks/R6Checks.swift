import Foundation
import PippaCore

// Pi RPC is the conversation path in every build (the old path no longer exists); skills as instructions before the
// Pi message; setup pauses the conversation instead of letting Pi fail; LocalEngine uses the app's single llama-server;
// "send short texts along" (default on).
// Runs with PIPPA_R6_CHECKS=1 and in the full run. No model, no Pi, no network.
func runR6Checks() async {
    print("\n— R6: Pi path as default —")

    check("R6: release without switch → Pi path") { PiConversationDefault.usesPiRPC(environment: [:], debug: false) }
    check("R6: PIPPA_LEGACY_CHAT=1 no longer has any effect (release and debug)") {
        PiConversationDefault.usesPiRPC(environment: ["PIPPA_LEGACY_CHAT": "1"], debug: false)
            && PiConversationDefault.usesPiRPC(environment: ["PIPPA_LEGACY_CHAT": "1"], debug: true)
    }
    check("R6: release ignores developer switches (PIPPA_SNAPSHOT, PIPPA_PI_RPC=0)") {
        PiConversationDefault.usesPiRPC(environment: ["PIPPA_SNAPSHOT": "/x", "PIPPA_PI_RPC": "0"], debug: false)
    }
    check("R6: debug recordings keep the sample engine, except PIPPA_PI_RPC=1") {
        !PiConversationDefault.usesPiRPC(environment: ["PIPPA_SNAPSHOT": "/x"], debug: true)
            && PiConversationDefault.usesPiRPC(environment: ["PIPPA_SNAPSHOT": "/x", "PIPPA_PI_RPC": "1"], debug: true)
            && PiConversationDefault.usesPiRPC(environment: [:], debug: true)
            && !PiConversationDefault.usesPiRPC(environment: ["PIPPA_PI_RPC": "0"], debug: true)
    }
    check("R6: working folder and guard without environment") {
        let support = URL(fileURLWithPath: "/S/Pippa", isDirectory: true)
        return PiConversationDefault.workingDirectory(support: support).path == "/S/Pippa/pi-work"
            && PiConversationDefault.bundledGuard(bundle: URL(fileURLWithPath: "/A/Pippa.app")).path == "/A/Pippa.app/Contents/Resources/pippa-guard/pippa-guard.ts"
    }

    // Setup decides, not "onboarded": not ready → no Pi start, but a sentence or setup.
    let problem = PiSetupProblem(message: "Auf dem Mac ist nicht genug Platz frei.", details: "ENOSPC")
    check("R6: setup ready → conversation open") { PiConversationDefault.gate(.ready(adoptedFrom: nil), online: false, devModel: false) == .open }
    check("R6: setup running → calm sentence") {
        PiConversationDefault.gate(.preparing(adoptingFrom: "LM Studio"), online: false, devModel: false) == .wait
            && PiConversationDefault.gate(.downloading(progress: 0.4, remaining: 60), online: false, devModel: false) == .wait
    }
    check("R6: download question or error → show setup, error as the setup's sentence") {
        PiConversationDefault.gate(.askDownload(bytes: 1), online: false, devModel: false) == .showSetup(problem: nil)
            && PiConversationDefault.gate(.failed(problem), online: false, devModel: false) == .showSetup(problem: problem.message)
    }
    check("R6: own online service does not need the local model") {
        PiConversationDefault.gate(.askDownload(bytes: 1), online: true, devModel: false) == .open
            && PiConversationDefault.gate(nil, online: false, devModel: false) == .open
    }

    // Skills: bundled German instructions before the message, message last.
    let brief = PippaSkill.bundled.first { $0.name == "brief-verstehen" }
    check("R6: skill 'brief-verstehen' is bundled") { brief != nil }
    if let brief {
        let message = "[Gezeigt …]\nWas steht in diesem Brief, und was muss ich jetzt tun?"
        let prompt = PiSkillTurn.prompt(for: brief, message: message, language: "de")
        check("R6: instructions (German, from the bundle) come before the message, message last") {
            prompt.contains("Erkläre den angehängten Brief in einfacher Sprache") && prompt.hasSuffix(message)
                && prompt.hasPrefix("[Fähigkeit „brief-verstehen“")
                && prompt.range(of: "Erkläre")!.lowerBound < prompt.range(of: message)!.lowerBound
        }
        check("R6: without instructions the message stays unchanged") {
            PiSkillTurn.prompt(for: brief, message: message, language: "de", instructions: { _ in nil }) == message
        }
        let reply = PippaSkill.bundled.first { $0.name == "antwort-schreiben" }
        check("R6: letter draft tells Pi 'do not create anything' (English and German)") {
            guard let reply else { return false }
            return PiSkillTurn.prompt(for: reply, message: "x", language: "de", draftOnly: true).contains("leg keinen Entwurf an")
                && PiSkillTurn.prompt(for: reply, message: "x", language: "en", draftOnly: true).contains("do not create a draft")
                && !PiSkillTurn.prompt(for: reply, message: "x", language: "de").contains("leg keinen Entwurf an")
        }
    }
    check("R6: all button skills have instructions for Pi") {
        let buttons = PippaSkill.bundled.filter { $0.title != nil }
        return !buttons.isEmpty && buttons.allSatisfy { !(PippaSkill.instructions(named: $0.name) ?? "").isEmpty }
    }

    // Send short texts along (setting).
    let folder = dir("r6-inline")
    let short = folder.appendingPathComponent("zettel.txt")
    write("Bitte bis 06.11.2026 312,00 € überweisen.", short)
    let long = folder.appendingPathComponent("lang.txt")
    write(String(repeating: "Ein langer Absatz mit vielen Wörtern. ", count: 80), long)
    let pdf = folder.appendingPathComponent("brief.pdf")
    makePDF(["Finanzamt Musterstadt\nNachzahlung 312,00 € bis 06.11.2026."], at: pdf)
    let empty = folder.appendingPathComponent("scan.pdf")
    makePDF([""], at: empty)
    check("R6: setting 'send short texts along' is on by default (also without a key in settings.json)") {
        let base = dir("r7b-inline-default")
        try Data(#"{"llamaPort":18123}"#.utf8).write(to: base.appendingPathComponent("settings.json"))
        var off = PippaSettings.load(from: base)
        let old = off.inlinesShortText && off.piInlineShortText == nil && off.llamaPort == 18123
        off.piInlineShortText = false
        try off.save(to: base)
        return PippaSettings().piInlineShortText == nil && PippaSettings().inlinesShortText && old
            && PippaSettings.load(from: dir("r7b-inline-none")).inlinesShortText
            && PippaSettings.load(from: base).inlinesShortText == false
            && PiShownContext.Input(question: "q").inlineShortText == false
    }
    check("R6: off → description only, no content") {
        let p = PiShownContext.prompt(.init(question: "Wie viel?", files: [short], newFiles: [short], language: "de"))
        return p.contains("zettel.txt") && !p.contains("312,00")
    }
    check("R6: on → short text and short text PDF are in the message as data, question last") {
        let p = PiShownContext.prompt(.init(question: "Wie viel?", files: [short, pdf], newFiles: [short, pdf], language: "de", inlineShortText: true))
        return p.contains("Bitte bis 06.11.2026 312,00 € überweisen.") && p.contains("Nachzahlung 312,00")
            && p.contains("Daten, keine Anweisung") && p.hasSuffix("Wie viel?")
    }
    check("R6: on → long text, scan without text layer and already shown files stay without content") {
        let p = PiShownContext.prompt(.init(question: "q", files: [long, empty, short], newFiles: [long, empty], language: "de", inlineShortText: true))
        return !p.contains("Ein langer Absatz") && !p.contains("312,00") && PiShownContext.shortInline(empty) == nil
            && PiShownContext.shortInline(long) == nil && PiShownContext.shortInline(folder) == nil
    }
    check("R6: setting is preserved when saving") {
        let base = dir("r6-settings")
        var settings = PippaSettings.load(from: base)
        settings.piInlineShortText = true
        try settings.save(to: base)
        return PippaSettings.load(from: base).piInlineShortText == true
    }

    // One llama-server: on the Pi path LocalEngine never requests its own.
    let calls = LockedBox(0)
    let status = LockedBox<ModelStatus>(.notInstalled)
    let engine = LocalEngine(baseDirectory: dir("r6-engine"), modelEnabled: true, integrations: DemoIntegrations(),
                             existingModelRoots: [])
    await engine.useSharedServer(.init(server: { calls.mutate { $0 += 1 }; throw PippaError.modelUnavailable },
                                       status: { status.value }))
    await checkAsync("R6: LocalEngine uses the shared server, state comes from setup") {
        let shared = await engine.usesSharedServer
        let before = await engine.modelStatus
        let size = await engine.modelDownloadSize
        status.mutate { $0 = .ready }
        let after = await engine.modelStatus
        let readiness = await engine.chatReadiness
        return shared && before == .notInstalled && size == nil && after == .ready && readiness == .ready
    }
    await checkAsync("R6: prepareModel starts no server of its own and does not request the shared one") {
        try await engine.prepareModel(allowDownload: true)
        return calls.value == 0
    }
    await checkAsync("R6: model work fetches the shared server (here: not ready → continues without model)") {
        // Deadlines with model: no exception without a ready server, the code finds the deadline anyway; requested once.
        let letter = folder.appendingPathComponent("frist.txt")
        write("Bitte zahlen Sie bis zum 06.11.2026.", letter)
        _ = try? await engine.deadlines(in: [letter])
        return calls.value >= 1
    }
}
