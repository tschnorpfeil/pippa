import AppKit
import PiRPC
import PippaCore

/// The **conversation path in every
/// build**: free text and capabilities in the conversation go to the real Pi (`pi --mode rpc`) instead of the own core.
/// Pi runs its tools without asking. Should an extension still ask (`extension_ui_request`), a simple Pippa prompt
/// (NSAlert) shows the question. The old own core no longer exists; only debug recordings use a stand-in (`ConversationChat`).
///
/// Launch as in `PippaPiLaunch.configuration`: the **pinned release with Pippa's Node** (`PiInstaller.launchSpec`, never
/// `~/.local/bin/pi`), `--provider pippa-local`, shared `~/.pi/agent`, Pippa's extensions and web access, no
/// `AGENTS.md`, no project trust, Pippa's system prompt, Pi's version check before launch. If the
/// installer step "Pi" is missing, it runs at the first conversation (idempotent; only creates what is missing).
///
/// **One Pi session per conversation:** `--session-id` from the conversation id in `<Support>/pi-sessions`. When
/// the conversation changes, Pi restarts with the other session (instead of `switch_session`). Pi finds an id only among
/// sessions with the same working directory; so for an existing session Pi starts in its working directory
/// (`PiSessionFiles.pinnedWorkingDirectory`), otherwise a second session with the same id would arise. Conversation
/// deleted → session files to the trash (`forget`).
///
/// **llama-server for `pippa-local`:** owned by the app. One server for all conversations, fixed port and
/// key as in models.json, 127.0.0.1 only, switches like LocalEngine's server (`PiLocalServer`). Pi starts only
/// when `/health` returns 200; until then the thought line shows how far loading is ("Ich werde wach …"). Every answer holds the server
/// (lease); after `llamaIdleMinutes` (default 10) without a request the model is unloaded and reloaded
/// at the next answer. `PIPPA_PI_OWN_LLAMA=0`: the app starts none (server already running, e.g. `pi-rpc-spike.sh llama-start`).
///
/// Environment (all optional; without it the app bundle or Pippa's support folder applies): `PIPPA_PI_EXTENSIONS`
/// (folder with Pippa's Pi extensions, otherwise Contents/Resources/pippa-tools, in a debug run without a bundle
/// runtime/pippa-tools in the repo), `PIPPA_PI_WEB` (pippa-web/index.ts, the same way; empty: no web access),
/// `PIPPA_PI_WORKDIR` (working directory of new sessions, otherwise `<Support>/pi-work`),
/// `PIPPA_PI_PAYLOAD` (install payload; in the finished app from the bundle), `PIPPA_PI_MODEL` (otherwise the first
/// model of `pippa-local` in models.json). Tests only: `PIPPA_PI_HOME` (fake HOME under .build for
/// installer and Pi, so ~/.pi and ~/.local stay untouched) and `PI_CODING_AGENT_DIR` (isolated agent folder,
/// passed through; Pippa never sets it itself).
@MainActor
final class PiRPCChat {
    static let shared = PiRPCChat()
    /// Does the real Pi run the conversation? Always in release builds; in debug recordings not without `PIPPA_PI_RPC=1`
    /// (`PiConversationDefault.usesPiRPC`, then `SnapshotChat`). Pi, setup and llama-server run only then.
    static let isLive = PiConversationDefault.usesPiRPC(debug: isDebugBuild)

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// What the person reads is always one everyday sentence; technical detail goes only to the diagnostic log.
    enum Failure: LocalizedError {
        case setup(String)
        case model(String)
        /// ChatGPT subscription (PiSubscriptionAuth): signed out or expired, or the subscription's limit is reached.
        case subscription(PiSubscriptionAuth.Problem)
        var errorDescription: String? {
            switch self {
            case .setup: T("I’m not fully set up yet. Open Pippa’s setup and choose “Try Again”.", table: "App")
            case .model: T("The answer didn’t come through just now. Please try again in a moment.", table: "App")
            case .subscription(.signedOut):
                T("Your ChatGPT sign-in has run out. Sign in again in Pippa’s settings, or switch back to the AI on this Mac.", table: "App")
            case .subscription(.limit):
                T("Your ChatGPT subscription has reached its limit for now. Try again later, or switch back to the AI on this Mac.", table: "App")
            }
        }
        /// For the log only (DiagnosticsLog), never in the UI; own technical texts, no content.
        var details: String {
            switch self {
            case .setup(let what): "setup: " + what
            case .model: "model"   // Pi's error text may contain content: not into the log
            case .subscription(let problem): "subscription: " + problem.rawValue
            }
        }
    }

    /// Error text for the person: Pi-path errors as an everyday sentence (technical detail only to the log), otherwise as usual.
    static func userText(for error: Error, context: String) -> String {
        guard let failure = error as? Failure else { return UserMessage.text(for: error, context: context) }
        DiagnosticsLog.shared.event("pi-weg-fehler", ["wo": context, "details": String(failure.details.prefix(300))])
        return failure.localizedDescription
    }

    /// Pippa's Pi extensions (folder): environment, otherwise the app bundle, in a debug run without a bundle the repo.
    static func extensionsPath(_ env: [String: String]) -> String {
        if let path = env["PIPPA_PI_EXTENSIONS"], !path.isEmpty { return path }
        if let repo = repoRuntime { return repo.appendingPathComponent("pippa-tools", isDirectory: true).path }
        return PiConversationDefault.bundledExtensions(bundle: Bundle.main.bundleURL).path
    }

    /// Web access (pippa-web/index.ts), found like the extensions; `PIPPA_PI_WEB` empty: none.
    static func webPath(_ env: [String: String]) -> String? {
        if let path = env["PIPPA_PI_WEB"] { return path.isEmpty ? nil : path }
        if let repo = repoRuntime { return repo.appendingPathComponent("pippa-web/index.ts").path }
        return PiConversationDefault.bundledWeb(bundle: Bundle.main.bundleURL).path
    }

    /// `runtime/` in the repo for a debug run without an app bundle, otherwise `nil`.
    private static var repoRuntime: URL? {
        #if DEBUG
        if Bundle.main.bundleURL.pathExtension != "app" {
            return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("runtime", isDirectory: true)
        }
        #endif
        return nil
    }

    /// For the everyday step wording (WorkStepPhrase): the person's home folder.
    static let homePath = FileManager.default.homeDirectoryForCurrentUser.path

    /// Working directory of new sessions: environment, otherwise an own folder in Pippa's support folder (created).
    static func workingDirectory(_ env: [String: String]) throws -> URL {
        if let path = env["PIPPA_PI_WORKDIR"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        let url = PiConversationDefault.workingDirectory(support: Pippa.supportDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var client: PiRPCClient?
    /// The one llama-server for `pippa-local` and what it was started with (if the plan changes, it restarts).
    private var localServer: LlamaServer?
    private var localPlan: PiLocalServer.Plan?
    static var ownsLocalServer: Bool { ProcessInfo.processInfo.environment["PIPPA_PI_OWN_LLAMA"] != "0" }
    /// Pippa conversation id whose Pi session the running process has.
    private var sessionKey: String?
    /// Receipt of the last answer (also stopped or with error); `takeActions()` collects it.
    private var lastActions: ActionReceipt?
    /// The mail the last answer read via `mail_selected` (identity from Pippa's result), otherwise `nil`.
    private(set) var lastSelectedMail: MailReplySource?

    static var sessionDirectory: URL { Pippa.supportDirectory.appendingPathComponent("pi-sessions", isDirectory: true) }

    private func ready(session key: String) async throws -> PiRPCClient {
        let env = ProcessInfo.processInfo.environment
        // Local model or own online service (only via Pippa's broker). If the path changes, Pi restarts.
        let route = try await launchRoute(env)
        if let client, sessionKey == key, launchKey == route.key, await client.isRunning { return client }
        if let old = client { await old.shutdown(); client = nil }
        let extensions = URL(fileURLWithPath: Self.extensionsPath(env), isDirectory: true)
        guard FileManager.default.fileExists(atPath: extensions.appendingPathComponent("pippa-tools.ts").path) else {
            throw Failure.setup("Pippas Pi-Erweiterungen fehlen (PIPPA_PI_EXTENSIONS oder Contents/Resources/pippa-tools)")
        }
        let work = try Self.workingDirectory(env)
        try FileManager.default.createDirectory(at: Self.sessionDirectory, withIntermediateDirectories: true)
        // pi-web-access reads Pippa's settings from here, never from the person's ~/.pi (runtime/pippa-web/index.ts).
        var extra = ["PIPPA_WEB_DIR": Pippa.supportDirectory.appendingPathComponent("pi-web", isDirectory: true).path]
        if let online = route.online { extra[PiOnlineProvider.keyVariable] = online.key }
        // Test scripts only (scripts/pi-rpc-spike.sh app): own Pi folder instead of ~/.pi, test trash under .build.
        for key in ["PI_CODING_AGENT_DIR", "PIPPA_TRASH_DIR"] { if let value = env[key] { extra[key] = value } }
        let web = Self.webPath(env).flatMap { FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
        let paths = PippaPiLaunch.Paths(extensionsDirectory: extensions, webExtension: web,
                                        sessionDirectory: Self.sessionDirectory, skillsDirectory: PippaSkill.bundledDirectory(),
                                        memoryFile: PiConversationDefault.memoryFile(support: Pippa.supportDirectory))
        let language = Bundle.module.preferredLocalizations.first ?? "en"
        var launcher = try await Self.launcher(env)
        if let online = route.online { launcher.piArguments = PiOnlineProvider.launchArguments(online.connection) }
        if let model = route.subscriptionModel { launcher.piArguments = ["--provider", PiSubscriptionAuth.provider, "--model", model] }
        // Existing session: Pi starts in its working directory, otherwise it would not find the id (see above).
        let cwd = PiSessionFiles.pinnedWorkingDirectory(id: PippaPiLaunch.piSessionID(key), in: Self.sessionDirectory)
            ?? work
        // Pippa's MCP server (calendar, reminders, mail, read Excel), see PippaMCPService.
        let mcp = await PippaMCPService.endpoint(extensions: extensions)
        let configuration = PippaPiLaunch.configuration(launcher: launcher, workingDirectory: cwd, paths: paths, sessionID: key,
                                                        language: language, environment: extra, mcp: mcp)
        let fresh = PiRPCClient(configuration: configuration)
        await fresh.setUIHandler { request in await Self.ask(request) }
        try await fresh.start()
        client = fresh; sessionKey = key; launchKey = route.key
        return fresh
    }

    /// What the running Pi was started with (provider, model, broker); if it changes, Pi restarts.
    private var launchKey: String?

    struct LaunchRoute {
        var key: String
        var online: (connection: ModelConnection, key: String)?
        /// ChatGPT subscription through Pi's own sign-in: `--provider openai --model <id>`, nothing written anywhere.
        var subscriptionModel: String? = nil
    }

    /// If an own online service is connected and on, Pi works with `pippa-online` (Pi's own provider, straight to the
    /// service); otherwise with `pippa-local`. models.json then gets exactly the matching `pippa-online` entry (or none).
    /// The key stays in the Keychain and reaches only this Pi, as an environment variable.
    private func launchRoute(_ env: [String: String]) async throws -> LaunchRoute {
        let target = try Self.installTarget(env)
        let modelsJSON = target.agent.appendingPathComponent("models.json")
        if let model = Self.subscriptionModel {
            _ = try? await Task.detached { try PiOnlineProvider.sync(nil, modelsJSON: modelsJSON) }.value
            return LaunchRoute(key: "chatgpt|" + model, online: nil, subscriptionModel: model)
        }
        guard let connection = Self.onlineConnection else {
            _ = try? await Task.detached { try PiOnlineProvider.sync(nil, modelsJSON: modelsJSON) }.value
            return LaunchRoute(key: "local|" + target.model, online: nil)
        }
        let key = try await Task.detached { try ModelCredentialStore.read(connection.id) }.value ?? ""
        _ = try await Task.detached { try PiOnlineProvider.sync(connection, modelsJSON: modelsJSON) }.value
        let routeKey = ["online", connection.id.uuidString, connection.provider.rawValue, connection.endpoint.absoluteString,
                        connection.modelID, String(connection.contextWindow), String(key.hashValue)].joined(separator: "|")
        return LaunchRoute(key: routeKey, online: (connection, key))
    }

    /// Pi refuses a prompt before any request when the subscription sign-in is gone ("No API key found for openai"):
    /// that is a sign-in problem for the person, not a general failure.
    private func subscriptionChecked<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch PiRPCError.commandFailed(_, let message) where launchKey?.hasPrefix("chatgpt|") == true {
            if let problem = PiSubscriptionAuth.problem(in: message) { throw Failure.subscription(problem) }
            throw Failure.model(message)
        }
    }

    /// The ChatGPT model when the person switched the subscription on (`nil`: not on).
    static var subscriptionModel: String? {
        InferenceSettings.load(from: AppModel.inferenceSettingsDirectory).subscriptionModel
    }

    /// The enabled own service according to the saved settings (`nil`: Pippa works on this Mac).
    static var onlineConnection: ModelConnection? {
        PiOnlineProvider.activeConnection(InferenceSettings.load(from: AppModel.inferenceSettingsDirectory))
    }

    /// "Eigener Dienst" settings changed: if no service is on any more, `pippa-online` disappears from models.json right
    /// away. The next Pi start takes the new path (`launchKey`).
    func onlineSettingsChanged() {
        guard Self.onlineConnection == nil, let target = try? Self.installTarget(ProcessInfo.processInfo.environment) else { return }
        let modelsJSON = target.agent.appendingPathComponent("models.json")
        Task.detached { _ = try? PiOnlineProvider.sync(nil, modelsJSON: modelsJSON) }
    }

    /// Pinned release + Pippa's Node from the installer. If step "Pi" has not run yet, now (off the
    /// main thread; checks `--version`, creates only what is missing).
    /// Installer roots, agent folder (models.json) and model id of `pippa-local`, for Pi and the llama-server.
    static func installTarget(_ env: [String: String]) throws -> (roots: PiInstallRoots, agent: URL, model: String) {
        guard let payload = PiPayload.locate(environment: env) else { throw Failure.setup("Pi-Ladung fehlt (PIPPA_PI_PAYLOAD)") }
        let roots: PiInstallRoots
        if let home = env["PIPPA_PI_HOME"] {
            let url = URL(fileURLWithPath: home, isDirectory: true)
            roots = PiInstallRoots(home: url, payload: payload, searchPath: [url.appendingPathComponent(".local/bin")])
        } else {
            roots = PiInstallRoots(support: Pippa.supportDirectory, payload: payload)
        }
        let agent = env["PI_CODING_AGENT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? roots.agentDirectory
        guard let model = env["PIPPA_PI_MODEL"] ?? PiInstaller.providerModelIDs(modelsJSON: agent.appendingPathComponent("models.json")).first else {
            throw Failure.setup("pippa-local fehlt in models.json (Installer-Schritt „models.json“)")
        }
        return (roots, agent, model)
    }

    /// Pippa's support folder as the installer sees it (fake HOME in measurement runs), e.g. for `llama-slots`.
    static var installSupport: URL {
        (try? installTarget(ProcessInfo.processInfo.environment))?.roots.support ?? Pippa.supportDirectory
    }

    static func launcher(_ env: [String: String]) async throws -> PippaPiLaunch.Launcher {
        let (roots, _, model) = try installTarget(env)
        let spec: PiLaunchSpec = try await Task.detached {
            let installer = PiInstaller(roots: roots)
            if let spec = installer.launchSpec(modelID: model) { return spec }
            let result = installer.installPi()
            guard let spec = installer.launchSpec(modelID: model) else { throw Failure.setup(result.message) }
            return spec
        }.value
        return PippaPiLaunch.Launcher(executable: spec.executable, launcherArguments: spec.launcherArguments,
                                      piArguments: spec.piArguments, environment: spec.environment)
    }

    /// The llama-server for `pippa-local`, created anew if needed (not yet started). The plan (port, key,
    /// model file) is read by `PiLocalServer` off the main thread.
    func localModelServer() async throws -> LlamaServer {
        let target = try Self.installTarget(ProcessInfo.processInfo.environment)
        let support = Pippa.supportDirectory
        let plan: PiLocalServer.Plan
        do {
            plan = try await Task.detached {
                try PiLocalServer.plan(roots: target.roots, agentDirectory: target.agent, modelID: target.model, legacySupport: support)
            }.value
        } catch let failure as PiLocalServer.Failure { throw Failure.setup(failure.localizedDescription) }
        if let localServer, localPlan == plan { return localServer }
        Self.publishLaunchFile(plan, support: target.roots.support)
        if let old = localServer { await old.stop() }
        let server = PiLocalServer.server(plan, logDirectory: support)
        localServer = server; localPlan = plan
        DiagnosticsLog.shared.event("pi-llama-plan", ["modell": plan.modelID, "quelle": plan.source, "port": String(plan.port),
                                                     "leerlauf-s": String(Int(plan.idleSeconds))])
        return server
    }

    /// Launch file for Pippa's terminal extension (`pi` in the terminal then starts the same server if the app does
    /// not run it). Off the main thread (`--help` of the program); errors cost only terminal convenience.
    nonisolated static func publishLaunchFile(_ plan: PiLocalServer.Plan, support: URL) {
        Task.detached(priority: .utility) {
            do {
                if try PiLocalServer.publishLaunchFile(plan, support: support) {
                    DiagnosticsLog.shared.event("pi-terminal-startdatei", ["modell": plan.modelID, "port": String(plan.port)])
                }
            } catch {
                DiagnosticsLog.shared.event("pi-terminal-startdatei-fehler", ["grund": error.localizedDescription])
            }
        }
    }

    /// After setup (and at every app start with setup done): keep the launch file current, even if no
    /// message has come in Pippa yet. Pippa.app may have been moved; the file then names the new location.
    static func refreshLaunchFile() {
        let env = ProcessInfo.processInfo.environment
        guard ownsLocalServer, let target = try? installTarget(env) else { return }
        let support = Pippa.supportDirectory
        Task.detached(priority: .utility) {
            guard let plan = try? PiLocalServer.plan(roots: target.roots, agentDirectory: target.agent, modelID: target.model, legacySupport: support)
            else { return }
            publishLaunchFile(plan, support: target.roots.support)
        }
    }

    /// Holds the server for an answer (starts it if needed and waits for `/health`). If it has to load first,
    /// the thought line shows the progress (`lease(_:onWork:)`). `nil`: the app runs no server (`PIPPA_PI_OWN_LLAMA=0`).
    private func modelLease(onWork: WorkEventHandler?) async throws -> (server: LlamaServer, lease: LlamaServer.AgentLease)? {
        guard Self.ownsLocalServer else { return nil }
        let server = try await localModelServer()
        return (server, try await Self.lease(server, onWork: onWork))
    }

    /// LocalEngine (sort classification, invoices, deadlines, letter suggestions) no longer gets its own llama-server,
    /// but this one. State and loading belong to setup (PiSetupController), not LocalEngine.
    func shareServer(with engine: any PippaEngine) {
        guard let local = engine as? LocalEngine else { return }
        let shared = LocalEngine.SharedModelServer(server: { try await PiRPCChat.serverForLocalEngine() },
                                                   status: { await PiRPCChat.statusForLocalEngine() })
        Task { await local.useSharedServer(shared) }
    }

    static func serverForLocalEngine() async throws -> LlamaServer {
        guard isLive, ownsLocalServer else { throw Failure.setup("kein eigener llama-server (PIPPA_PI_OWN_LLAMA=0)") }
        return try await shared.localModelServer()
    }

    /// State of setup in LocalEngine's terms (pill, "Knowledge" line, `canRunModelWork`).
    static func statusForLocalEngine() -> ModelStatus {
        if DevEnvironment.value("PIPPA_MODEL_FILE") != nil { return .ready }
        switch PiSetupController.shared?.state {
        case .ready?: return .ready
        case .preparing?: return .loading
        case .askDownload?, nil: return .notInstalled
        case .downloading(let progress, let remaining)?: return .downloading(progress: progress, remaining: remaining)
        case .failed(let problem)?: return .failed(reason: problem.message)
        }
    }

    /// For measurements (recording `pirpc`): whether the server runs, which process, how long the last start took.
    func localServerStatus() async -> (pid: Int32?, lastStart: Double?, idle: Double?) {
        guard let localServer else { return (nil, nil, localPlan?.idleSeconds) }
        return (await localServer.processID, await localServer.lastStartSeconds, localPlan?.idleSeconds)
    }

    /// This app's llama-server (if created), so that quitting the app can stop it without the MainActor
    /// (AppDelegate; otherwise its guard process ends it as soon as the app is gone).
    var ownedServer: LlamaServer? { localServer }

    /// Conversation deleted: if Pi currently runs with one of these sessions, end it first (otherwise Pi would rewrite the file),
    /// then move the session files to the trash. `keys`: Pippa's ids (`uuid`, `uuid:revision`).
    func forget(_ keys: [String]) async {
        if let sessionKey, keys.contains(sessionKey) {
            await client?.shutdown()
            client = nil; self.sessionKey = nil
        }
        // The saved prompt cache (llama-slots) may contain exactly this conversation.
        await localServer?.discardSavedSlot()
        let support = Self.installSupport
        await Task.detached { PiLocalServer.discardSavedSlots(support: support) }.value
        Self.trashSessions(keys)
    }

    /// Without a running Pi (switch off): only the files. Never delete permanently; `PIPPA_TRASH_DIR` for tests only.
    static func trashSessions(_ keys: [String]) {
        let fake = ProcessInfo.processInfo.environment["PIPPA_TRASH_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        PiSessionFiles.trash(ids: keys.map(PippaPiLaunch.piSessionID), in: sessionDirectory) { url in
            if let fake {
                try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: fake.appendingPathComponent(url.lastPathComponent))
            } else {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
    }

    /// Like `PippaEngine.chat`: returns the answer after the last recorded message. Stopped throws
    /// `AnswerFailure.stopped`, so ConversationController leaves the partial answer in place as usual.
    /// The receipt ("Was passiert ist") arises on the side from the events and afterwards lies in `takeActions()`.
    /// `onReset` (letter draft): if set, only the text after the last tool call counts; what Pi wrote before
    /// ("Ich lese den Brief …") disappears again, so the draft is only the draft.
    func chat(_ text: String, taskID: String, onWork: WorkEventHandler?, onDelta: @escaping @Sendable (String) -> Void,
              onSteered: @escaping @Sendable (String) -> Void, onReset: (@Sendable (String) -> Void)? = nil) async throws -> String {
        lastActions = nil
        searchFiles = []
        // Read and write receipts belong to the answer that triggered them.
        _ = PippaMCPService.readNotes.take()
        _ = PippaMCPService.writeNotes.take()
        // First the model, then Pi: Pi starts only if the server responds.
        // If the own online service works, no local model is needed.
        let held = Self.onlineConnection == nil && Self.subscriptionModel == nil ? try await modelLease(onWork: onWork) : nil
        defer { if let held { Task { await held.server.releaseAgentLease(held.lease) } } }
        let client = try await ready(session: taskID)
        var segment = ""
        var lastStop = ""
        var lastError: String?
        var loopStop: String?
        var receipt = PiTurnReceipt()
        lastSelectedMail = nil
        defer {
            let reads = PippaMCPService.readNotes.take()
            // Did this answer read the selected mail? (offer "Als Entwurf in Mail", PiRPCChat+Shown.)
            lastSelectedMail = reads.last { $0.tool == "mail_selected" && $0.read }?.mail
            lastActions = Self.actions(receipt, reads: reads, writes: PippaMCPService.writeNotes.take())
        }
        var toolArguments: [String: String] = [:]
        do {
        for try await event in try await subscriptionChecked({ try await client.prompt(text) }) {
            receipt.observe(event)
            switch event {
            case .textDelta(let delta):
                segment += delta
                onDelta(delta)
            case .toolStarted(let id, let name, let arguments):
                if name == "read" || WorkStepPhrase.hasOutcome(tool: name) { toolArguments[id] = arguments }
                onWork?(.toolStarted(name: name, source: nil, step: WorkStepPhrase.phrase(tool: name, arguments: arguments, home: Self.homePath)))
            case .toolEnded(let id, let name, let isError, let result):
                // What Pi read with `read`, for this answer's source check (PiReadLedger).
                let arguments = toolArguments.removeValue(forKey: id)
                if name == "read", !isError, let arguments {
                    await PippaMCPTurns.shared.active?.notePiRead(arguments: arguments, result: result)
                }
                let outcome = arguments.flatMap {
                    WorkStepPhrase.outcome(tool: name, arguments: $0, isError: isError, result: result, home: Self.homePath,
                                           resultWasCut: result.count >= PiRPCClient.listingResultLimit)
                }
                onWork?(.toolEnded(name: name, outcome: outcome))
            case .userMessage:
                onSteered(segment)
                segment = ""
            case .assistantEnded(_, let reason, let error):
                lastStop = reason; lastError = error
                if reason == "toolUse", let onReset {
                    segment = ""; onReset("")
                } else if reason == "toolUse", !segment.isEmpty, !segment.hasSuffix("\n") {
                    // Text before a tool call stays part of the answer; a paragraph separates it from the rest.
                    segment += "\n\n"; onDelta("\n\n")
                }
            case .notice(let text, let kind):
                if kind == "pippa-search-result", let data = text.data(using: .utf8),
                   let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    for path in (record["files"] as? [String] ?? []) where path.hasPrefix("/") {
                        let url = URL(fileURLWithPath: path)
                        if !searchFiles.contains(url), searchFiles.count < 200 { searchFiles.append(url) }
                    }
                }
                if kind == "pippa-loop-stop", let data = text.data(using: .utf8),
                   let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let files = (record["files"] as? [String] ?? []).filter { $0.hasPrefix("/") }
                    var reason = T("I stopped because the same action kept repeating. The task is incomplete.", table: "App")
                    if !files.isEmpty {
                        reason += "\n\n" + T("Found so far (%lld):", table: "App", files.count)
                        for path in files {
                            let name = URL(fileURLWithPath: path).lastPathComponent.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                            let target = URL(fileURLWithPath: path).absoluteString
                            reason += searchFiles.contains(URL(fileURLWithPath: path)) ? "\n- [\(name)](\(target))" : "\n- \(name)"
                        }
                    } else if record["searched"] as? Bool == true {
                        reason += "\n" + T("The search returned no file locations before it stopped. Files may still exist.", table: "App")
                    }
                    if record["truncated"] as? Bool == true {
                        reason += "\n" + T("More file locations were found; only the first 200 are shown.", table: "App")
                    }
                    loopStop = reason
                }
            case .settled:
                break
            }
        }
        }
        if let loopStop {
            throw AnswerFailure.stopped(partial: segment.trimmingCharacters(in: .whitespacesAndNewlines) + (segment.isEmpty ? "" : "\n\n") + loopStop)
        }
        if lastStop == "aborted" { throw AnswerFailure.stopped(partial: segment) }
        if lastStop == "error" {
            // Through the subscription: say what is wrong (sign-in, limit); never switch to another service by itself.
            if launchKey?.hasPrefix("chatgpt|") == true, let problem = PiSubscriptionAuth.problem(in: lastError ?? "") {
                throw Failure.subscription(problem)
            }
            throw Failure.model(lastError ?? "unbekannt")
        }
        return segment.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchFiles: [URL] = []
    func takeSearchFiles() -> [URL] {
        defer { searchFiles = [] }
        return searchFiles
    }

    /// The receipt of the last answer, once. `nil` if no tool wanted to change anything.
    func takeActions() -> ActionReceipt? {
        defer { lastActions = nil }
        return lastActions
    }

    /// PiRPC (without PippaCore) → history. Events only, no model text. Read and write lines get their text from the
    /// notes of Pippa's MCP server, one per tool in call order; a read without note shows "Etwas gelesen", a write without
    /// note "Benutzt: …" (what happened is then known only to Pi).
    static func actions(_ receipt: PiTurnReceipt, reads: [PippaMCPReadNote] = [], writes: [PippaMCPWriteReceipt] = []) -> ActionReceipt? {
        var pendingReads = reads
        var pendingWrites = writes
        let items = receipt.records.map { record -> ActionReceipt.Item in
            if record.action == "read" {
                let note = pendingReads.firstIndex { $0.tool == record.name }.map { pendingReads.remove(at: $0) }
                return ActionReceipt.Item(action: "read", outcome: note.map { $0.read ? "done" : "failed" } ?? record.outcome.rawValue,
                                          name: note?.line)
            }
            if record.action == "write" {
                let action = Self.writeActions[record.name ?? ""]
                if let index = pendingWrites.firstIndex(where: { $0.action == action }) { return pendingWrites.remove(at: index).item }
                return ActionReceipt.Item(action: "tool", outcome: record.outcome.rawValue, name: record.name)
            }
            return ActionReceipt.Item(action: record.action, outcome: record.outcome.rawValue, name: record.name, toName: record.toName)
        }
        return items.isEmpty ? nil : ActionReceipt(items: items)
    }

    /// Pippa's write tools → the action of their receipt (PippaMCPWriteReceipt).
    static let writeActions = ["calendar_add": "calendarAdd", "reminder_add": "reminderAdd", "mail_draft": "mailDraft"]

    func steer(_ text: String) async -> Bool {
        guard let client else { return false }
        return (try? await client.steer(text)) ?? false
    }

    func cancel() async {
        try? await client?.abort()
    }

    /// Only for recording `PIPPA_SNAPSHOT_ONLY=pirpc`: receives the open prompt window (for a screenshot) and
    /// answers in the person's place (button code). `nil`: the person answers.
    static var answerForSnapshot: ((NSWindow, PiUIRequest) -> NSApplication.ModalResponse)?

    /// A question of an extension (Pippa's own ask none): a Pippa prompt, so Pi never waits forever. `confirm` and
    /// short `select` as buttons, `input`/`editor` with text field.
    private static func ask(_ request: PiUIRequest) async -> PiUIResponse {
        let alert = NSAlert()
        if answerForSnapshot != nil {
            // Runs in the prompt's modal mode; an ordinary task would only run after it closes.
            nonisolated(unsafe) let shown = alert
            let timer = Timer(timeInterval: 1.5, repeats: false) { _ in
                MainActor.assumeIsolated {
                    if let answer = answerForSnapshot { NSApp.stopModal(withCode: answer(shown.window, request)) }
                }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
        }
        // Pi's `select` has no text, only title and answers: "Frage⏎⏎Satz⏎⏎Zusatz" may come in the title.
        var title = request.title, message = request.message
        if request.method == "select", message.isEmpty, let cut = title.range(of: "\n\n") {
            message = String(title[cut.upperBound...]); title = String(title[..<cut.lowerBound])
        }
        alert.messageText = title.isEmpty ? T("May Pippa do this?", table: "App") : title
        // First paragraph: the everyday sentence. What follows (command, path) appears smaller below.
        let parts = message.components(separatedBy: "\n\n")
        alert.informativeText = parts.first ?? message
        if parts.count > 1 {
            let detail = NSTextField(wrappingLabelWithString: parts.dropFirst().joined(separator: "\n\n"))
            detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            detail.textColor = .secondaryLabelColor
            detail.frame.size.width = 320
            detail.sizeToFit()
            alert.accessoryView = detail
        }
        switch request.method {
        case "confirm":
            alert.addButton(withTitle: T("Allow", table: "App"))
            alert.addButton(withTitle: T("Don’t Allow", table: "App"))
            return .confirmed(alert.runModal() == .alertFirstButtonReturn)
        case "select" where !request.options.isEmpty && request.options.count <= 3:
            for option in request.options { alert.addButton(withTitle: option) }
            let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            return request.options.indices.contains(index) ? .value(request.options[index]) : .cancelled
        case "select":
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
            popup.addItems(withTitles: request.options)
            alert.accessoryView = popup
            alert.addButton(withTitle: T("OK", table: "App")); alert.addButton(withTitle: T("Cancel", table: "App"))
            guard alert.runModal() == .alertFirstButtonReturn, let title = popup.titleOfSelectedItem else { return .cancelled }
            return .value(title)
        default:
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            field.placeholderString = request.placeholder
            field.stringValue = request.prefill ?? ""
            alert.accessoryView = field
            alert.addButton(withTitle: T("OK", table: "App")); alert.addButton(withTitle: T("Cancel", table: "App"))
            return alert.runModal() == .alertFirstButtonReturn ? .value(field.stringValue) : .cancelled
        }
    }
}
