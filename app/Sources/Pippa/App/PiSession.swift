import Foundation
import PiRPC
import PippaCore

/// Pippa's one connection to Pi: starts the pinned Pi over RPC with Pippa's tools, the app's MCP server and the local
/// model server (or the online AI), one Pi session per conversation, and streams Pi's events back. Pi decides what to
/// do; nothing here reads or rewrites the person's message or Pi's answer.
@MainActor
final class PiSession {
    static let shared = PiSession()

    enum Failure: LocalizedError {
        case setup(String)
        case nativeTools(String)
        case model(String)

        var errorDescription: String? {
            switch self {
            case .setup: T("Pippa isn't set up yet. Open Settings to finish setting up her AI.", table: "App")
            case .nativeTools: T("Pippa couldn't start her Mac tools. Quit Pippa and open her again.", table: "App")
            case .model(let message): message
            }
        }
    }

    private var client: PiRPCClient?
    private var startupTask: Task<(PiRPCClient, LaunchRoute), Error>?
    private var preloadTask: Task<Void, Never>?
    private var lastPrewarmAttempt: ContinuousClock.Instant?
    private var sessionID: String?
    private var launchKey: String?
    private var needsFreshClient = false
    private var localServer: OMLXServer?
    private var localPlan: PiLocalServer.Plan?

    static var sessionDirectory: URL { Pippa.supportDirectory.appendingPathComponent("pi-sessions", isDirectory: true) }
    static var settingsDirectory: URL { Pippa.supportDirectory }

    /// The local server, so quitting can stop it without the main actor.
    var ownedServer: OMLXServer? { localServer }

    // MARK: Asking

    /// Sends `text` to Pi in the session `conversation` and calls `onEvent` for every event until Pi settles.
    /// `turn` binds the app's MCP tools to this answer: writes outside an answer are refused.
    func ask(_ text: String, conversation: String, onEvent: @escaping (PiRPCEvent) -> Void) async throws {
        let turn = PippaMCPTurn()
        PippaMCPService.begin(turn)
        defer { PippaMCPService.end(turn) }
        var settled = false
        defer { if !settled { needsFreshClient = true; PippaMCPService.invalidateEndpoint() } }
        let startup = Task { try await prepare(conversation: conversation) }
        startupTask = startup
        let client: PiRPCClient
        let route: LaunchRoute
        do { (client, route) = try await withTaskCancellationHandler { try await startup.value } onCancel: { startup.cancel() } }
        catch { startupTask = nil; throw error }
        startupTask = nil
        try Task.checkCancellation()
        let stream: AsyncThrowingStream<PiRPCEvent, Error>

        do { stream = try await client.prompt(text) } catch PiRPCError.commandFailed(_, let message) {
            if route.piModel != nil, let problem = PiProviderClient.problem(in: message) {
                throw Failure.model(problem == .limit ? T("Your online AI limit is reached for now. Try again later, or switch to the AI on this Mac in Settings.", table: "App")
                                                      : T("Reconnect your online AI in Settings.", table: "App"))
            }
            throw Failure.model(route.online == nil && route.piModel == nil ? ChatModel.modelError(message, online: false) : message)
        }
        for try await event in stream {
            onEvent(event)
            if case .settled = event { settled = true }
        }
    }

    private func prepare(conversation: String) async throws -> (PiRPCClient, LaunchRoute) {
        let route = try await launchRoute()
        if route.online == nil && route.piModel == nil {
            do { try await localModelServer().ensureRunning() }
            catch let error as Failure { throw error }
            catch { throw Failure.setup(T("The AI on this Mac didn’t start. Try again in a moment.", table: "App")) }
        }
        try Task.checkCancellation()
        return (try await ready(conversation: conversation, route: route), route)
    }

    func stop() async {
        preloadTask?.cancel()
        if let startupTask {
            startupTask.cancel()
            await client?.cancelNativeReadiness()
            await client?.shutdown()
            needsFreshClient = true
        } else if let client {
            do { try await client.abort() } catch {
                await client.shutdown()
                needsFreshClient = true
            }
        }
    }

    /// How full the current conversation's context is (Pi's `get_session_stats`), for the context panel.
    func contextUsage() async -> ContextUsage? {
        guard let client, let data = try? await client.command(["type": "get_session_stats"], timeout: .seconds(2)),
              let stats = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let usage = stats["contextUsage"] as? [String: Any],
              let tokens = usage["tokens"] as? Int, let window = usage["contextWindow"] as? Int else { return nil }
        return ContextUsage(tokens: tokens, window: window)
    }

    /// Before a conversation is deleted: end Pi if it holds that session, then move the session file to the Trash.
    func forget(_ conversation: String) async {
        if sessionID == conversation { await client?.shutdown(); client = nil; sessionID = nil }
        PiSessionFiles.trash(ids: [PippaPiLaunch.piSessionID(conversation)], in: Self.sessionDirectory) { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    func shutdown() async {
        startupTask?.cancel()
        preloadTask?.cancel()
        await client?.cancelNativeReadiness()
        await client?.shutdown()
        client = nil
    }

    /// The model's or Pi's settings changed: the next question starts Pi afresh.
    func settingsChanged() {
        needsFreshClient = true
        preloadTask?.cancel()
        lastPrewarmAttempt = nil
    }

    // MARK: Starting Pi

    private func ready(conversation: String, route: LaunchRoute) async throws -> PiRPCClient {
        if !needsFreshClient, let client, sessionID == conversation, launchKey == route.key,
           await client.isRunning, await client.isAnswering == false { return client }
        PippaMCPService.invalidateEndpoint()
        if let old = client { await old.shutdown(); client = nil }
        let env = ProcessInfo.processInfo.environment
        let extensions = URL(fileURLWithPath: Self.extensionsPath(env), isDirectory: true)
        guard FileManager.default.fileExists(atPath: extensions.appendingPathComponent("pippa-tools.ts").path) else {
            throw Failure.setup("pippa-tools missing at \(extensions.path)")
        }
        try FileManager.default.createDirectory(at: Self.sessionDirectory, withIntermediateDirectories: true)
        let work = PiConversationDefault.workingDirectory(support: Pippa.supportDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var extra = ["PIPPA_WEB_DIR": Pippa.supportDirectory.appendingPathComponent("pi-web", isDirectory: true).path]
        if let online = route.online { extra[PiOnlineProvider.keyVariable] = online.key }
        for key in ["PI_CODING_AGENT_DIR", "PIPPA_TRASH_DIR"] { if let value = env[key] { extra[key] = value } }
        let web = Self.webPath(env).flatMap { FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
        let paths = PippaPiLaunch.Paths(extensionsDirectory: extensions, webExtension: web, sessionDirectory: Self.sessionDirectory,
                                        skillsDirectory: PippaSkill.bundledDirectory(),
                                        memoryFile: PiConversationDefault.memoryFile(support: Pippa.supportDirectory))
        var launcher = try await Self.launcher(env, modelID: route.piModel?.modelID ?? route.online?.connection.modelID)
        if let online = route.online { launcher.piArguments = PiOnlineProvider.launchArguments(online.connection) }
        if let model = route.piModel { launcher.piArguments = model.launchArguments }
        // An existing session must start in the folder it was created in, or Pi doesn't find it.
        let cwd = PiSessionFiles.pinnedWorkingDirectory(id: PippaPiLaunch.piSessionID(conversation), in: Self.sessionDirectory) ?? work
        let mcp: (endpoint: PippaPiLaunch.MCPEndpoint, extension: URL)
        do { mcp = try await PippaMCPService.endpoint(extensions: extensions) }
        catch { throw Failure.nativeTools(String(describing: error)) }
        let language = Bundle.module.preferredLocalizations.first ?? "en"
        let configuration = PippaPiLaunch.configuration(launcher: launcher, workingDirectory: cwd, paths: paths, sessionID: conversation,
                                                        language: language, environment: extra, mcp: mcp)
        let fresh = PiRPCClient(configuration: configuration)
        try Task.checkCancellation()
        client = fresh
        await fresh.setUIHandler { request in await Confirmations.ask(request) }
        do {
            try await fresh.start()
            try await fresh.verifyNativeTools()
            try Task.checkCancellation()
        } catch {
            PippaMCPService.invalidateEndpoint()
            await fresh.shutdown()
            throw error
        }
        client = fresh; sessionID = conversation; launchKey = route.key; needsFreshClient = false
        return fresh
    }

    struct LaunchRoute {
        var key: String
        var online: (connection: ModelConnection, key: String)?
        var piModel: PiModelSelection?
    }

    /// A Pi provider, an existing Keychain connection, or the model on this Mac, as saved in Settings.
    private func launchRoute() async throws -> LaunchRoute {
        let target = try Self.installation(ProcessInfo.processInfo.environment)
        let modelsJSON = target.agent.appendingPathComponent("models.json")
        let settings = InferenceSettings.load(from: Self.settingsDirectory)
        if let model = settings.activePiModel {
            await removeOnlineProvider(from: modelsJSON)
            return LaunchRoute(key: "pi|" + model.providerID + "|" + model.modelID, piModel: model)
        }
        guard let connection = PiOnlineProvider.activeConnection(settings) else {
            await removeOnlineProvider(from: modelsJSON)
            return LaunchRoute(key: "local|" + (try Self.installTarget(ProcessInfo.processInfo.environment)).model)
        }
        let key = try await Task.detached { try ModelCredentialStore.read(connection.id) }.value ?? ""
        _ = try await Task.detached { try PiOnlineProvider.sync(connection, modelsJSON: modelsJSON) }.value
        let routeKey = ["online", connection.id.uuidString, connection.provider.rawValue, connection.endpoint.absoluteString,
                        connection.modelID, String(connection.contextWindow), String(key.hashValue)].joined(separator: "|")
        return LaunchRoute(key: routeKey, online: (connection, key))
    }

    /// Pi's models.json keeps no online entry while another route is active. Best effort: a failure is only logged.
    private func removeOnlineProvider(from modelsJSON: URL) async {
        do { _ = try await Task.detached { try PiOnlineProvider.sync(nil, modelsJSON: modelsJSON) }.value }
        catch { UserMessage.record(error, context: "online-provider-sync") }
    }

    /// The local oMLX server for `pippa-local`, created when the plan (model, port) changes.
    private func localModelServer() async throws -> OMLXServer {
        let target = try Self.installTarget(ProcessInfo.processInfo.environment)
        let support = Pippa.supportDirectory
        let plan: PiLocalServer.Plan
        do {
            plan = try await Task.detached {
                try PiLocalServer.plan(roots: target.roots, agentDirectory: target.agent, modelID: target.model)
            }.value
        } catch { throw Failure.setup(error.localizedDescription) }
        if let localServer, localPlan == plan { return localServer }
        // Pi in the terminal starts the same server from this file when the app isn't running.
        let launchSupport = target.roots.support
        Task.detached {
            do { try PiLocalServer.publishLaunchFile(plan, support: launchSupport) }
            catch { UserMessage.record(error, context: "launch-file") }
        }
        if let old = localServer { await old.stop() }
        let server = PiLocalServer.server(plan, logDirectory: support)
        localServer = server; localPlan = plan
        return server
    }

    /// Typing is intent to ask. Never send the draft, start an online provider, or load on merely opening a window.
    /// Keep typing responsive and coalesce changes, including edits to an already nonempty draft after a long pause.
    func prewarmForInput() {
        let settings = SettingsModel.shared.inferenceSettings
        guard settings.activePiModel == nil, PiOnlineProvider.activeConnection(settings) == nil,
              SetupModel.shared.isReady, !ChatModel.shared.isAnswering, preloadTask == nil else { return }
        let now = ContinuousClock.now
        if let lastPrewarmAttempt, now - lastPrewarmAttempt < .seconds(30) { return }
        lastPrewarmAttempt = now
        preloadTask = Task {
            defer { preloadTask = nil }
            do {
                DiagnosticsLog.shared.event("model-prewarm-start")
                let began = ContinuousClock.now
                let server = try await localModelServer()
                try Task.checkCancellation()
                try await server.prewarm()
                DiagnosticsLog.shared.event("model-prewarm-ready", ["seconds": String(describing: ContinuousClock.now - began)])
            } catch is CancellationError {
            } catch {
                // Best effort: a failed speculative load must not block sending the real question.
                DiagnosticsLog.shared.event("model-prewarm-failed", [:])
            }
        }
    }

    // MARK: Paths

    static func installation(_ env: [String: String]) throws -> (roots: PiInstallRoots, agent: URL) {
        guard let payload = PiPayload.locate(environment: env) else { throw Failure.setup("Pi payload missing (PIPPA_PI_PAYLOAD)") }
        let roots = PiInstallRoots.forApp(payload: payload, environment: env)
        let agent = env["PI_CODING_AGENT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? roots.agentDirectory
        return (roots, agent)
    }

    static func installTarget(_ env: [String: String]) throws -> (roots: PiInstallRoots, agent: URL, model: String) {
        let (roots, agent) = try installation(env)
        guard let model = env["PIPPA_PI_MODEL"] ?? PiInstaller.providerModelIDs(modelsJSON: agent.appendingPathComponent("models.json")).first else {
            throw Failure.setup("pippa-local missing in models.json")
        }
        return (roots, agent, model)
    }

    static func launcher(_ env: [String: String], modelID: String? = nil) async throws -> PippaPiLaunch.Launcher {
        let (roots, _) = try installation(env)
        let model = try modelID ?? installTarget(env).model
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

    /// Pippa's Pi extensions: environment, otherwise the app bundle, in a debug run without a bundle the repo.
    static func extensionsPath(_ env: [String: String]) -> String {
        if let path = env["PIPPA_PI_EXTENSIONS"], !path.isEmpty { return path }
        if let repo = repoRuntime { return repo.appendingPathComponent("pippa-tools", isDirectory: true).path }
        return PiConversationDefault.bundledExtensions(bundle: Bundle.main.bundleURL).path
    }

    static func webPath(_ env: [String: String]) -> String? {
        if let path = env["PIPPA_PI_WEB"] { return path.isEmpty ? nil : path }
        if let repo = repoRuntime { return repo.appendingPathComponent("pippa-web/index.ts").path }
        return PiConversationDefault.bundledWeb(bundle: Bundle.main.bundleURL).path
    }

    private static var repoRuntime: URL? {
        #if DEBUG
        if Bundle.main.bundleURL.pathExtension != "app" {
            return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("runtime", isDirectory: true)
        }
        #endif
        return nil
    }
}
