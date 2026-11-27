import Foundation
import PiRPC
import PippaCore

/// Pippa's one connection to Pi: starts the pinned Pi over RPC with Pippa's tools, the app's MCP server and the local
/// model server (or the online AI), one Pi session per conversation, and streams Pi's events back. Pi decides what to
/// do; nothing here reads or rewrites the person's message or Pi's answer.
@MainActor
final class PiSession {
    static let shared = PiSession()

    /// Who can answer while Pippa works. The window can; `Pippa --ask` cannot, so it neither opens a dialog nor grants anything.
    enum Interaction {
        case window
        /// Existing grants only. Pi's questions are declined (`declined` says that one was asked), never answered with yes.
        case headless(declined: @Sendable (PiUIRequest) -> Void)

        /// Whether Pippa's tools may show a permission prompt for access that was never decided (`PippaMCPHost.askForAccess`).
        var asksForAccess: Bool { if case .window = self { true } else { false } }

        var uiHandler: PiUIHandler {
            switch self {
            case .window: { request in await Confirmations.ask(request) }
            case .headless(let declined): { request in declined(request); return Self.decline(request) }
            }
        }

        /// A confirmation is denied; a choice or a typed answer is cancelled. Nothing is approved on the person's behalf.
        static func decline(_ request: PiUIRequest) -> PiUIResponse { request.method == "confirm" ? .confirmed(false) : .cancelled }
    }

    var interaction = Interaction.window {
        didSet { PippaMCPService.asksForAccess = interaction.asksForAccess }
    }

    /// What goes to Pi as the person's message. Which one may go where is decided here, after the route is read from
    /// disk and before Pi starts (`message(_:route:)`), so a route that changed meanwhile never receives the wrong one.
    enum Outgoing: Equatable {
        /// For the AI on this Mac: the person's words with their files and the app in front (`ChatModel.prompt`).
        /// Refused for an online AI unless the person allowed it Mac access (issue #196).
        case local(String)
        /// Exactly what the person typed, nothing added. Any route.
        case typed(String)
        /// What the person reviewed and approved for one online AI. Only to exactly that destination and account, in a
        /// Pi session of its own: later questions in the conversation never carry it again.
        case approved(ShareApproval)
    }

    enum Failure: LocalizedError, Equatable {
        case setup(String)
        case nativeTools(String)
        case model(String)
        /// Files, the app in front or other Mac content would go to an online AI without the person's review.
        case needsReview
        /// The approved destination is no longer the one Pippa would send to. Nothing was sent.
        case destinationChanged
        case settingsChanged

        var errorDescription: String? {
            switch self {
            case .needsReview: T("Pippa uses an online AI now. Nothing was sent; check what you want to share and send again.", table: "App")
            case .destinationChanged: T("The online AI changed since you checked. Nothing was sent; check again for the new one.", table: "App")
            case .settingsChanged: T("The AI settings changed. Nothing was sent. Send your question again when you’re ready.", table: "App")
            case .setup: T("Pippa isn't set up yet. Open Settings to finish setting up her AI.", table: "App")
            case .nativeTools: T("Pippa couldn't start her Mac tools. Quit Pippa and open her again.", table: "App")
            case .model(let message): message
            }
        }
    }

    private var client: PiRPCClient?
    private var pendingPrompt: PiRPCPromptAdmission?
    private var startupTask: Task<(PiRPCClient, LaunchRoute, String), Error>?
    private var preloadTask: Task<Void, Never>?
    private var lastPrewarmAttempt: ContinuousClock.Instant?
    private var sessionID: String?
    private var launchKey: String?
    private var needsFreshClient = false
    private var localServer: OMLXServer?
    private var localPlan: PiLocalServer.Plan?
    /// The online Pi's private agent folder (`PiRecipientSnapshot`); `nil` for the AI on this Mac.
    private var snapshot: PiRecipientSnapshot?
    /// Turn preparations still running after Stop: a renewal that has started is stored, and its folder then removed.
    /// Quit waits for them (`shutdown`).
    private var preparations: [UUID: Task<Void, Never>] = [:]
    /// Counts every saved change of the AI settings in this process (`settingsChanged`, on the main actor). A route read
    /// before a change is never admitted (`admit`).
    private(set) var settingsRevision = 0
    /// The Pi session scope of the running answer when Continue may pick it up later (`resumeScope(_:)`), else `nil`.
    var answerScope: String?
    /// The running answer takes a follow-up from the person (`steer`): a typed conversation turn admitted under
    /// `turnSettingsRevision`. Never a single question, an approved message, or a turn after the settings changed.
    private var turnSteerable = false {
        didSet { if turnSteerable != oldValue { onSteeringChange?() } }
    }
    /// Told when `canSteer` changes, so the window shows or hides its Send beside Stop.
    var onSteeringChange: (() -> Void)?
    private var turnSettingsRevision: Int?
    private var steeringClient: PiRPCClient?
    /// A follow-up was sent during this turn, so Stop must clear Pi's queue before aborting.
    private var steeredInTurn = false

    static var sessionDirectory: URL { Pippa.supportDirectory.appendingPathComponent("pi-sessions", isDirectory: true) }
    static var settingsDirectory: URL { Pippa.supportDirectory }
    /// One folder per Pippa process, so `Pippa --ask` and the window never remove each other's live snapshot.
    static var snapshotRoot: URL { Pippa.supportDirectory.appendingPathComponent("pi-recipients", isDirectory: true) }
    static var snapshotDirectory: URL { snapshotRoot.appendingPathComponent(String(getpid()), isDirectory: true) }

    /// The local server, so quitting can stop it without the main actor.
    var ownedServer: OMLXServer? { localServer }

    // MARK: Asking

    /// Sends `outgoing` to Pi in the session for `conversation` and its destination and calls `onEvent` for every event
    /// until Pi settles. `turn` binds the app's MCP tools to this answer: writes outside an answer are refused.
    /// `handoff`: one approved question to the recipient for single questions while conversations stay on this Mac, in a
    /// fresh session of its own. `onStarting`: `true` while the AI on this Mac starts and loads into memory before the
    /// question goes out, then `false`.
    func ask(_ outgoing: Outgoing, conversation: String, handoff: Bool = false, onStarting: @escaping (Bool) -> Void = { _ in },
             onEvent: @escaping (PiRPCEvent) -> Void) async throws {
        let turn = PippaMCPTurn(conversation: conversation)
        PippaMCPService.begin(turn)
        defer { PippaMCPService.end(turn) }
        var settled = false
        defer { if !settled { needsFreshClient = true; PippaMCPService.invalidateEndpoint() } }
        defer { onStarting(false) }
        answerScope = nil
        steeredInTurn = false
        endSteering()
        defer { steeredInTurn = false; endSteering() }
        let admission = PiRPCPromptAdmission()
        pendingPrompt = admission
        defer { if pendingPrompt === admission { pendingPrompt = nil } }
        let startup = Task { try await prepare(outgoing, conversation: conversation, handoff: handoff, onStarting: onStarting) }
        startupTask = startup
        let client: PiRPCClient
        let route: LaunchRoute
        let text: String
        do { (client, route, text) = try await withTaskCancellationHandler { try await startup.value } onCancel: { startup.cancel() } }
        catch { startupTask = nil; throw error }
        startupTask = nil
        onStarting(false)
        answerScope = Self.resumeScope(route)
        // An online AI with the tools of the AI on this Mac sorts a whole inbox: a larger Mail budget for this answer.
        turn.setExtendedBudget(route.hasMacAccess)
        try Task.checkCancellation()
        let stream: AsyncThrowingStream<PiRPCEvent, Error>
        // The settings revision the prompt was admitted under (`admit` runs right before `send`, without awaiting).
        var admittedRevision: Int?
        do {
            stream = try await admitted(route, text: text, outgoing: outgoing,
                                        reread: { try await self.launchRoute(outgoing, handoff: handoff) },
                                        admission: admission, send: {
                                            admittedRevision = self.settingsRevision
                                            return try await client.prompt($0, admission: admission)
                                        })
        } catch PiRPCError.commandFailed(_, let message) {
            if route.piModel != nil, let problem = PiProviderClient.problem(in: message) {
                throw Failure.model(ChatModel.limitMessage(problem))
            }
            throw Failure.model(ChatModel.modelError(message, online: route.online != nil || route.piModel != nil))
        }
        if Self.steerable(outgoing, handoff: handoff), let admittedRevision, await client.isAnswering {
            allowSteering(client, revision: admittedRevision)
        }
        for try await event in stream {
            onEvent(event)
            if case .settled = event { settled = true }
        }
    }

    /// The last step before Pi's first request of the turn. Starting Pi takes a moment, so Settings, the provider's
    /// configuration and account and the sharing rules are read again (`reread`); a different recipient or limits send
    /// nothing. Reading them again awaits the provider's files and the Keychain, and the person can change Settings
    /// meanwhile (revoke Mac access, sign out): `admit` then compares the settings that read used with the ones saved
    /// now, without awaiting anything in between, on the main actor where every change is saved. Only an admitted
    /// prompt goes to `send`, the running Pi; a change after admission reaches the next question (the answer that runs
    /// keeps its Pi, `settingsChanged`).
    func admitted<Stream>(_ route: LaunchRoute, text: String, outgoing: Outgoing, reread: () async throws -> LaunchRoute,
                          latest: () -> InferenceSettings = { InferenceSettings.load(from: PiSession.settingsDirectory) },
                          admission: PiRPCPromptAdmission = .init(), send: (String) async throws -> Stream) async throws -> Stream {
        pendingPrompt = admission
        defer { if pendingPrompt === admission { pendingPrompt = nil } }
        try admission.check()
        let now = try await reread()
        try admission.check()
        guard route.destination == now.destination else { throw Failure.destinationChanged }
        guard Self.sameRecipient(route, now), try Self.message(outgoing, route: now) == text else {
            throw now.destination == nil ? Failure.settingsChanged : Failure.needsReview
        }
        try admit(now, outgoing, latest: latest)
        try admission.check()
        return try await send(text)
    }

    /// Whether `route` may still receive the prompt: read from the settings saved now and unchanged in this process since.
    /// Synchronous, so no change of Settings can come in between this check and the prompt being handed to Pi.
    func admit(_ route: LaunchRoute, _ outgoing: Outgoing,
               latest: () -> InferenceSettings = { InferenceSettings.load(from: PiSession.settingsDirectory) }) throws {
        guard let read = route.admission, read.revision == settingsRevision, read.settings == latest() else {
            if route.destination == nil { throw Failure.settingsChanged }
            if case .local = outgoing { throw Failure.needsReview }
            throw Failure.destinationChanged
        }
    }

    private func prepare(_ outgoing: Outgoing, conversation: String, handoff: Bool,
                         onStarting: (Bool) -> Void) async throws -> (PiRPCClient, LaunchRoute, String) {
        var route = try await launchRoute(outgoing, handoff: handoff)
        // Before anything starts: a refused message never reaches a Pi process.
        var text = try Self.message(outgoing, route: route)
        if route.online == nil && route.piModel == nil {
            onStarting(true)
            let server: OMLXServer
            do { server = try await localModelServer(); try await server.ensureRunning() }
            catch let error as Failure { throw error }
            catch { throw Failure.setup(T("The AI on this Mac didn’t start. Try again in a moment.", table: "App")) }
            // Load the weights now, so "starting" covers the load and "thinking" means thinking. A load that fails
            // here fails again with the question, which reports it properly.
            try? await server.prewarm()
        }
        try Task.checkCancellation()
        let pinned = try await pinRecipient(route)
        do {
            if let pinned, route.piModel != nil, (pinned.identity?.recipient ?? "") != route.destination?.recipient {
                // Pi's renewal moved the endpoint the sign-in routes to, or the account changed meanwhile: read the route
                // again. Typed words go on in the account's own session; an approval made for the earlier recipient needs
                // a fresh review (`message` refuses it).
                let again = try await launchRoute(outgoing, handoff: handoff)
                text = try Self.message(outgoing, route: again)
                guard again.piModel == route.piModel, (pinned.identity?.recipient ?? "") == again.destination?.recipient else {
                    throw Failure.destinationChanged
                }
                route = again
            }
            try Task.checkCancellation()
        } catch {
            pinned?.remove()
            throw error
        }
        return (try await ready(conversation: conversation, route: route, pinned: pinned), route, text)
    }

    /// The text Pi receives on `route`, or why nothing may go there.
    static func message(_ outgoing: Outgoing, route: LaunchRoute) throws -> String {
        switch outgoing {
        case .typed(let text): return text
        case .local(let prompt):
            guard route.destination == nil || route.hasMacAccess else { throw Failure.needsReview }
            return prompt
        case .approved(let approval):
            guard let destination = route.destination, destination.isVerified, destination == approval.destination,
                  route.sessionScope == Self.approvedScope(approval, handoff: route.handoff) else { throw Failure.destinationChanged }
            // The rules as they are now: a source set to "Only on this Mac" after the review stops the whole message.
            guard let rules = route.egress?.rules, approval.parts.allSatisfy({ rules.mayOffer($0.sources) }) else { throw Failure.needsReview }
            return approval.message
        }
    }

    /// The Pi session an approved message goes to: one per approval, so the conversation's typed session never holds it.
    static func approvedScope(_ approval: ShareApproval, handoff: Bool) -> String {
        (handoff ? "handoff-" : "approved-") + approval.id.uuidString.lowercased()
    }

    /// The session Continue may go back to: typed words to a verified online AI, never an approved message, a single
    /// question, an unverified recipient or the AI on this Mac.
    static func resumeScope(_ route: LaunchRoute) -> String? {
        guard let destination = route.destination, destination.isVerified, !route.handoff, let scope = route.sessionScope,
              scope == destination.sessionTag || scope == destination.macAccessTag else { return nil }
        return scope
    }

    /// The session typed words go to now (as `launchRoute` picks it), for Continue: `nil` for the AI on this Mac or an
    /// unverified recipient.
    static func typedScope(_ settings: InferenceSettings, _ destination: ShareDestination?) -> String? {
        guard let destination, destination.isVerified else { return nil }
        return settings.allowsMacAccess(destination) ? destination.macAccessTag : destination.sessionTag
    }

    /// Two reads of the route name the same recipient, account, model and limits (the session scope may differ only for
    /// an unverified recipient, which gets a fresh session each time).
    static func sameRecipient(_ a: LaunchRoute, _ b: LaunchRoute) -> Bool {
        a.destination == b.destination && a.piModel == b.piModel && a.online?.connection == b.online?.connection
            && a.online?.key == b.online?.key && a.egress == b.egress && a.capabilities == b.capabilities && a.handoff == b.handoff
            && (a.destination != nil || a.key == b.key)
    }

    /// Whether a turn of this kind may take a follow-up while it runs: the person's own words in their conversation's
    /// session, never a single question to another AI or a message the person approved for one recipient.
    static func steerable(_ outgoing: Outgoing, handoff: Bool) -> Bool {
        if handoff { return false }
        if case .approved = outgoing { return false }
        return true
    }

    /// The running answer takes a follow-up now (`steer`).
    var canSteer: Bool { turnSteerable && steeringClient != nil && turnSettingsRevision == settingsRevision }

    /// A short follow-up or correction for the running answer: Pi reads it after its current step. `false` when the
    /// turn does not take one (anymore) or Pi did not accept it; nothing was sent then.
    func steer(_ text: String) async -> Bool {
        guard canSteer, let client = steeringClient else { return false }
        steeredInTurn = true
        // Once Pi accepted it, the follow-up is in, whatever changed meanwhile.
        return (try? await client.steer(text)) ?? false
    }

    /// The running turn on `client`, admitted under `revision`, takes follow-ups until it ends, Stop or a settings
    /// change. A revision older than the current one allows nothing.
    func allowSteering(_ client: PiRPCClient, revision: Int) {
        guard revision == settingsRevision else { return }
        turnSettingsRevision = revision
        steeringClient = client
        turnSteerable = true
    }

    private func endSteering() {
        turnSettingsRevision = nil
        steeringClient = nil
        turnSteerable = false
    }

    /// Stops the running turn and clears any undelivered steering messages from Pi so they never fire on the next
    /// question. Returns cleared undelivered texts so the composer can preserve them.
    @discardableResult
    func stop() async -> [String] {
        let shouldClearQueue = steeredInTurn
        steeredInTurn = false
        endSteering()
        PippaMCPService.cancelNativeTurn()
        pendingPrompt?.cancel()
        preloadTask?.cancel()
        if let startupTask {
            startupTask.cancel()
            await client?.cancelNativeReadiness()
            await client?.shutdown()
            needsFreshClient = true
            return []
        } else if let client {
            var cleared: [String] = []
            do {
                if shouldClearQueue { cleared += try await client.clearQueue() }
                try await client.abort()
                if shouldClearQueue { cleared += try await client.clearQueue() }
                return cleared
            } catch {
                await client.shutdown()
                needsFreshClient = true
                return cleared
            }
        }
        return []
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
        if let sessionID, sessionID == conversation || sessionID.hasPrefix(conversation + ":") {
            await client?.shutdown(); client = nil; self.sessionID = nil
            await retireSnapshot()
        }
        // With the sessions each online AI and each single question had for it.
        PiSessionFiles.trash(conversation: PippaPiLaunch.piSessionID(conversation), in: Self.sessionDirectory) { url in
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        }
    }

    func shutdown() async {
        pendingPrompt?.cancel()
        let starting = startupTask
        starting?.cancel()
        preloadTask?.cancel()
        await client?.cancelNativeReadiness()
        // A cancelled preparation can still be returning from the file copy or starting its client.
        // Let it unwind before looking up the client and recipient folder to retire.
        _ = await starting?.result
        await client?.shutdown()
        client = nil
        await retireSnapshot()
        for preparation in preparations.values { await preparation.value }
    }

    /// After its Pi ended, its private folder goes too.
    private func retireSnapshot() async {
        guard let old = snapshot else { return }
        snapshot = nil
        await Task.detached { old.remove() }.value
    }

    /// Pi's agent folder for the online turn about to start, private to the Pi process that runs it. For a Pi provider,
    /// Pi's own resolver prepares it from the shared folder (`PiRecipientSnapshot.prepare`): a sign-in that would expire
    /// within the turn is renewed there first, under Pi's lock, and the folder's recipient is read from what Pi will use.
    /// `prepare` compares that with the route; any other difference sends nothing.
    private func pinRecipient(_ route: LaunchRoute) async throws -> PiRecipientSnapshot? {
        guard let destination = route.destination else { return nil }
        let env = ProcessInfo.processInfo.environment
        let (roots, agent) = try Self.installation(env)
        let root = Self.snapshotRoot, parent = Self.snapshotDirectory
        if let connection = route.online?.connection, route.piModel == nil {
            // The key itself goes only into Pi's environment (`route.online.key`), checked with the route.
            return try await Task.detached {
                Self.sweepSnapshots(root)
                do { return try PiRecipientSnapshot.create(connection: connection, recipient: destination.recipient, from: agent, in: parent) }
                catch { throw Failure.destinationChanged }
            }.value
        }
        guard let model = route.piModel else { throw Failure.destinationChanged }
        guard let pi = PiProviderClient.bundled(roots: roots, agentDirectory: agent, environment: env, helper: Self.providersHelper, offline: true) else {
            throw Failure.setup("pi-providers.mjs missing")
        }
        // Not cancelled with the question: a renewal that has started must be stored, or the rotated refresh token is lost.
        // Pi bounds it (lock wait, then 15 s for the renewal). Stop does not wait for it; a folder it prepares after Stop
        // is removed, and Quit waits for it (`preparations`).
        let handoff = Handoff<Result<PiRecipientSnapshot, Error>> { late in if case .success(let snapshot) = late { snapshot.remove() } }
        let id = UUID()
        let work = Task.detached {
            Self.sweepSnapshots(root)
            do { handoff.deliver(.success(try await PiRecipientSnapshot.prepare(model: model, from: agent, in: parent, pi: pi))) }
            catch { handoff.deliver(.failure(error)) }
        }
        preparations[id] = Task { await work.value; self.preparations[id] = nil }
        switch try await handoff.value() {
        case .success(let snapshot):
            if Task.isCancelled { snapshot.remove(); throw CancellationError() }
            return snapshot
        case .failure(PiRecipientSnapshot.Failure.signedOut):
            throw Failure.model(T("Reconnect your online AI in Settings.", table: "App"))
        case .failure:
            throw Failure.destinationChanged
        }
    }

    /// Folders of Pippa processes that ended.
    nonisolated static func sweepSnapshots(_ root: URL) {
        for folder in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            guard let pid = Int32(folder.lastPathComponent) else { continue }
            if pid == getpid() || kill(pid, 0) == 0 || errno != ESRCH { continue }
            PiRecipientSnapshot.sweep(folder)
            rmdir(folder.path)
        }
    }

    /// The model's or Pi's settings changed: the next question starts Pi afresh.
    func settingsChanged() {
        endSteering()
        settingsRevision += 1
        needsFreshClient = true
        preloadTask?.cancel()
        lastPrewarmAttempt = nil
    }

    // MARK: Starting Pi

    /// `pinned`: the online turn's prepared folder (`pinRecipient`). A running Pi for the same session and recipient takes
    /// its credential and keeps going; otherwise Pi starts afresh in it.
    private func ready(conversation: String, route: LaunchRoute, pinned: PiRecipientSnapshot?) async throws -> PiRPCClient {
        let session = PippaPiLaunch.sessionID(conversation: conversation, scope: route.sessionScope)
        if !needsFreshClient, let client, sessionID == session, launchKey == route.key,
           await client.isRunning, await client.isAnswering == false {
            if let pinned {
                if let snapshot, (try? snapshot.adopt(pinned)) != nil { return client }
            } else if snapshot == nil { return client }
        }
        PippaMCPService.invalidateEndpoint()
        if let old = client { await old.shutdown(); client = nil }
        await retireSnapshot()
        snapshot = pinned
        let env = ProcessInfo.processInfo.environment
        let extensions = URL(fileURLWithPath: Self.extensionsPath(env), isDirectory: true)
        guard FileManager.default.fileExists(atPath: extensions.appendingPathComponent("pippa-tools.ts").path) else {
            throw Failure.setup("pippa-tools missing at \(extensions.path)")
        }
        try FileManager.default.createDirectory(at: Self.sessionDirectory, withIntermediateDirectories: true)
        let work = PiConversationDefault.workingDirectory(support: Pippa.supportDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let webDirectory = Pippa.supportDirectory.appendingPathComponent("pi-web", isDirectory: true)
        var extra = ["PIPPA_WEB_DIR": webDirectory.path]
        if let online = route.online { extra[PiOnlineProvider.keyVariable] = online.key }
        for key in ["PI_CODING_AGENT_DIR", "PIPPA_TRASH_DIR"] { if let value = env[key] { extra[key] = value } }
        // Matches the extended Mail budget of its answers (`PippaMCPTurn.extendedBudget`): more tool calls per answer.
        extra.merge(route.budgetEnvironment) { $1 }
        // An online Pi reads its provider's configuration and credential only from its own copy: what was checked is
        // what every request of this process reaches, whatever happens to ~/.pi/agent meanwhile.
        if let pinned {
            extra["PI_CODING_AGENT_DIR"] = pinned.directory.path
            // pi-web-access keeps its page cache where it was, not in the short-lived folder.
            extra["PI_WEB_ACCESS_CACHE_ROOT"] = env["PI_CODING_AGENT_DIR"] ?? webDirectory.appendingPathComponent("pi").path
        }
        // No tool the model calls reads or changes Pippa's own folder, Pi's shared agent folder or this pinned copy
        // (runtime/pippa-tools/protected.ts), on every route.
        let agent = try Self.installation(env).agent
        extra.merge(ProtectedPaths.app(extra: [agent] + (pinned.map { [$0.directory] } ?? [])).environment) { $1 }
        let web = Self.webPath(env).flatMap { FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
        let paths = PippaPiLaunch.Paths(extensionsDirectory: extensions, webExtension: web, sessionDirectory: Self.sessionDirectory,
                                        skillsDirectory: PippaSkill.bundledDirectory(),
                                        memoryFile: PiConversationDefault.memoryFile(support: Pippa.supportDirectory),
                                        digestDirectory: PiConversationDefault.digestDirectory(support: Pippa.supportDirectory))
        var launcher = try await Self.launcher(env, modelID: route.piModel?.modelID ?? route.online?.connection.modelID)
        if let online = route.online { launcher.piArguments = PiOnlineProvider.launchArguments(online.connection) }
        if let model = route.piModel { launcher.piArguments = model.launchArguments }
        // An existing session must start in the folder it was created in, or Pi doesn't find it.
        let cwd = PiSessionFiles.pinnedWorkingDirectory(id: PippaPiLaunch.piSessionID(session), in: Self.sessionDirectory) ?? work
        var mcp: (endpoint: PippaPiLaunch.MCPEndpoint, extension: URL)
        do { mcp = try await PippaMCPService.endpoint(extensions: extensions, egress: route.egress) }
        catch { throw Failure.nativeTools(String(describing: error)) }
        mcp.endpoint.exposure = route.mcpExposure
        let language = Bundle.module.preferredLocalizations.first ?? "en"
        let configuration = PippaPiLaunch.configuration(launcher: launcher, workingDirectory: cwd, paths: paths, sessionID: session,
                                                        language: language, environment: extra, mcp: mcp, capabilities: route.capabilities)
        let fresh = PiRPCClient(configuration: configuration)
        try Task.checkCancellation()
        client = fresh
        await fresh.setUIHandler(interaction.uiHandler)
        do {
            try await fresh.start()
            try await fresh.verifyNativeTools(expected: PippaPiLaunch.nativeTools(route.capabilities))
            try Task.checkCancellation()
        } catch {
            PippaMCPService.invalidateEndpoint()
            await fresh.shutdown()
            throw error
        }
        client = fresh; sessionID = session; launchKey = route.key; needsFreshClient = false
        return fresh
    }

    struct LaunchRoute {
        /// Route and optional capabilities: a running Pi is reused only while both match (`ready`).
        var key: String
        var online: (connection: ModelConnection, key: String)?
        var piModel: PiModelSelection?
        var capabilities = PippaPiLaunch.Capabilities.all
        /// The online AI that receives what is sent; `nil` for the AI on this Mac.
        var destination: ShareDestination?
        /// The app MCP server's limits for this Pi process (online only).
        var egress: PippaMCPEgress?
        /// Pi session beside the conversation's own: per online destination and account for typed words, or fresh for
        /// each approved message.
        var sessionScope: String?
        /// The recipient for single questions while conversations stay on this Mac.
        var handoff = false
        /// The settings this route was read from, and when (`PiSession.admit`).
        var admission: Admission?

        /// The capabilities chosen in Settings → AI for this route become part of the key, so a change reaches the next
        /// question, also in an open conversation, while an answer that is running keeps its Pi.
        func with(_ choice: OptionalCapabilities.Choice) -> Self {
            var route = self
            route.capabilities = PippaPiLaunch.Capabilities(web: choice.web, memory: choice.memory)
            route.key += "|" + route.capabilities.key
            return route
        }

        /// An online AI (issue #193): no Mac reading tools, no personal notes, its own session, writers by the sharing
        /// rules. Never inferred from a sign-in: only the active route or an approved single question gets here.
        /// `macAccess`: the person allowed this verified recipient Mac access (issue #196); it gets the tools of the AI on
        /// this Mac with these choices, in a session of its own (`ShareDestination.macAccessTag`). Pippa's approvals and
        /// macOS permissions still apply.
        func online(_ destination: ShareDestination, _ choice: OptionalCapabilities.Choice, rules: SourceSharing,
                    scope: String? = nil, macAccess: OptionalCapabilities.Choice? = nil) -> Self {
            var route = self
            route.destination = destination
            if let macAccess, destination.isVerified {
                route.sessionScope = destination.macAccessTag
                route.capabilities = PippaPiLaunch.Capabilities(web: macAccess.web, memory: macAccess.memory)
            } else {
                let egress = PippaMCPEgress(rules: rules, web: choice.web)
                route.egress = egress
                route.sessionScope = scope ?? destination.sessionTag
                route.capabilities = PippaPiLaunch.Capabilities(web: choice.web, memory: false, online: .init(mcpTools: egress.tools))
            }
            route.key += "|" + route.capabilities.key + "|" + (route.sessionScope ?? "")
            return route
        }

        /// An online AI with the tools of the AI on this Mac (`online(_:_:rules:scope:macAccess:)`).
        var hasMacAccess: Bool { destination != nil && capabilities.online == nil }

        /// How the model reaches Pippa's MCP tools (`PippaPiLaunch.MCPEndpoint.exposure`): an online AI with Mac access
        /// also gets Pi's `codemode` (measured on GLM 5.3, docs/pippa-1.0.md "Codemode"); every other route as before.
        var mcpExposure: String { hasMacAccess ? PippaPiLaunch.MCPEndpoint.directWithCodemode : "direct" }

        /// Pi process environment variables tied to this route's call budget (`runtime/pippa-tools/pippa-assist.ts`).
        var budgetEnvironment: [String: String] { hasMacAccess ? ["PIPPA_MAX_CALLS": "80"] : [:] }
    }

    /// A Pi provider, an existing Keychain connection, or the model on this Mac, as saved in Settings, with the effective
    /// recipient behind it (`PiRecipient`). `handoff`: the approved single question for the saved recipient (a Pi provider
    /// or an older connection), only while it is still that recipient. The session: typed words keep the conversation's
    /// session per recipient and account; each approved message gets a fresh one; an unverified recipient never reuses one.
    private func launchRoute(_ outgoing: Outgoing, handoff: Bool) async throws -> LaunchRoute {
        // Read before anything is awaited, with the revision of that moment (`admit`).
        let settings = InferenceSettings.load(from: Self.settingsDirectory)
        let admission = Admission(settings: settings, revision: settingsRevision)
        var route = try await launchRoute(outgoing, handoff: handoff, settings: settings)
        route.admission = admission
        return route
    }

    /// The settings a route was read from (`LaunchRoute.admission`).
    struct Admission: Equatable {
        var settings: InferenceSettings
        var revision: Int
    }

    private func launchRoute(_ outgoing: Outgoing, handoff: Bool, settings: InferenceSettings) async throws -> LaunchRoute {
        let target = try Self.installation(ProcessInfo.processInfo.environment)
        let modelsJSON = target.agent.appendingPathComponent("models.json")
        let choice = settings.capabilities.online
        var approval: ShareApproval?
        if case .approved(let approved) = outgoing { approval = approved }
        let model: PiModelSelection?
        let connection: ModelConnection?
        if handoff {
            // Only an approved single question, only while conversations stay on this Mac.
            guard approval != nil else { throw Failure.needsReview }
            guard !settings.usesOnlineAI else { throw Failure.destinationChanged }
            model = settings.handoffModel.flatMap { $0.isValid ? $0 : nil }
            connection = settings.handoffModel == nil ? settings.handoffLegacyConnection : nil
            guard model != nil || connection != nil else { throw Failure.destinationChanged }
        } else {
            model = settings.activePiModel
            connection = model == nil ? PiOnlineProvider.activeConnection(settings) : nil
        }
        func scope(_ destination: ShareDestination) -> String {
            if let approval { return Self.approvedScope(approval, handoff: handoff) }
            return destination.isVerified ? destination.sessionTag : "unverified-" + UUID().uuidString.lowercased()
        }
        let prefix = handoff ? "handoff|" : ""
        func macAccess(_ destination: ShareDestination) -> OptionalCapabilities.Choice? {
            Self.macAccess(settings, destination, approved: approval != nil, handoff: handoff)
        }
        if let model {
            await removeOnlineProvider(from: modelsJSON)
            let recipients = PiRecipient(agentDirectory: target.agent)
            let identity = await Task.detached { recipients.identity(model) }.value
            let destination = ShareDestination(model, identity: identity)
            return LaunchRoute(key: prefix + "pi|" + model.providerID + "|" + model.modelID + "|" + destination.recipient,
                               piModel: model, handoff: handoff)
                .online(destination, choice, rules: settings.sharing, scope: scope(destination), macAccess: macAccess(destination))
        }
        guard let connection else {
            await removeOnlineProvider(from: modelsJSON)
            return LaunchRoute(key: "local|" + (try Self.installTarget(ProcessInfo.processInfo.environment)).model)
                .with(settings.capabilities.local)
        }
        let key = try await Task.detached { try ModelCredentialStore.read(connection.id) }.value ?? ""
        _ = try await Task.detached { try PiOnlineProvider.sync(connection, modelsJSON: modelsJSON) }.value
        let destination = ShareDestination(connection, recipient: PiRecipient.fingerprint(connection, key: key))
        let routeKey = [prefix + "online", connection.id.uuidString, connection.provider.rawValue, connection.endpoint.absoluteString,
                        connection.modelID, String(connection.contextWindow), destination.recipient].joined(separator: "|")
        return LaunchRoute(key: routeKey, online: (connection, key), handoff: handoff)
            .online(destination, choice, rules: settings.sharing, scope: scope(destination), macAccess: macAccess(destination))
    }

    /// What the online AI gets with Mac access (issue #196), or `nil` for the limits: only the active recipient the person
    /// allowed it, verified and unchanged, and only for their own words and files. An approved message or a single question
    /// keeps the limits. Web search as chosen for the online AI; personal notes by the switch for this Mac.
    static func macAccess(_ settings: InferenceSettings, _ destination: ShareDestination, approved: Bool,
                          handoff: Bool) -> OptionalCapabilities.Choice? {
        guard !approved, !handoff, settings.allowsMacAccess(destination) else { return nil }
        return .init(web: settings.capabilities.online.web, memory: settings.capabilities.local.memory)
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

    /// Starts the local oMLX server for an isolated read-only routine without touching chat state or any online provider.
    func ensureLocalModelForRoutine() async throws {
        let server = try await localModelServer()
        try await server.ensureRunning()
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

    /// Pi's provider bridge for `prepare`: environment (`PIPPA_PI_PROVIDERS`), in a debug run the repo, else the bundle.
    static var providersHelper: URL? { repoRuntime?.appendingPathComponent("pippa-auth/pi-providers.mjs") }

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
