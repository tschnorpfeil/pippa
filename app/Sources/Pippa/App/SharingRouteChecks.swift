import Foundation
import PiRPC
import PippaCore

/// Also run by `Pippa --check-approvals`: what the chat may hand to which route (issue #193), without Pi or a window.
/// `PiSession.message` is the last check before a Pi process starts; `ChatModel.outgoing` decides what the composer sends.
@MainActor
enum SharingRouteChecks {
    static func run() -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print("\(ok ? "PASS" : "FAIL") \(name)")
            if !ok { failures += 1 }
        }
        let mailTurn = ChatMessage(role: .assistant, text: "Local mail result", provenance: [.mail])
        let followUp = ChatMessage(role: .assistant, text: "Repeats the earlier answer", provenance: [])
        let legacyAnswer = ChatMessage(role: .assistant, text: "Old answer with no tool trace")
        let onlineReply = ChatMessage(role: .assistant, text: "Separate online history", provenance: [.photos], destination: "Fixture AI")
        let localSources = ChatModel.localHistorySources(in: [mailTurn, onlineReply, followUp][...])
        var sharing = SourceSharing(); sharing.mail = .localOnly
        check(localSources == [.mail] && !sharing.mayOffer(localSources), "a tool-free local follow-up inherits Mail provenance across an intervening online answer")
        check(!sharing.mayOffer(ChatModel.localHistorySources(in: [legacyAnswer, followUp][...])), "legacy local history without source metadata needs every source on Ask")

        var retry = Conversation(id: "local-retry", title: "Fixture", updated: Date(), messages: [
            ChatMessage(role: .user, text: "Read the mail"), mailTurn])
        retry.removeTurnForRetry()
        retry.messages.append(followUp)
        let reloaded = try? JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(retry))
        check(reloaded?.localSources(through: 0) == [.mail], "replacing a local turn for Retry preserves its sources after a reload")

        let gpt = PiModelSelection(providerID: "openai", modelID: "gpt-fixture", providerName: "OpenAI")
        // Recipients are digests of the effective endpoint and account (`PiRecipient`); these stand in for two accounts.
        let openai = ShareDestination(gpt, recipient: "account-a")
        let anthropic = ShareDestination(PiModelSelection(providerID: "anthropic", modelID: "claude-fixture", providerName: "Anthropic"), recipient: "account-c")
        let local = PiSession.LaunchRoute(key: "local|m").with(.init())
        let online = PiSession.LaunchRoute(key: "pi|openai|gpt-fixture").online(openai, .init(), rules: SourceSharing())
        let approval = ShareApproval(destination: openai, question: "Check", parts: [.init(title: "Lease.pdf", sources: [.documents], text: "DOC-MARKER")])
        func approvedRoute(_ destination: ShareDestination, rules: SourceSharing = SourceSharing(), handoff: Bool = false) -> PiSession.LaunchRoute {
            var route = PiSession.LaunchRoute(key: "pi|fixture").online(destination, .init(), rules: rules,
                                                                       scope: PiSession.approvedScope(approval, handoff: handoff))
            route.handoff = handoff
            return route
        }
        func changed(_ failure: PiSession.Failure?) -> Bool { if case .destinationChanged = failure { true } else { false } }
        func refused(_ outgoing: PiSession.Outgoing, _ route: PiSession.LaunchRoute) -> PiSession.Failure? {
            do { _ = try PiSession.message(outgoing, route: route); return nil } catch { return error as? PiSession.Failure }
        }

        let prompt = ChatModel.prompt("Sort these", files: ["/Users/fixture/Documents/Lease.pdf"], frontApp: "Mail", undone: ["Dentist"])
        check(refused(.local(prompt), online).map { if case .needsReview = $0 { true } else { false } } == true,
              "a prompt with file paths and the app in front never goes to an online AI")
        check((try? PiSession.message(.typed("Hello"), route: online)) == "Hello", "typed words go to the online AI as they are")
        check((try? PiSession.message(.approved(approval), route: approvedRoute(openai))) == approval.message,
              "an approval goes out exactly as approved, in a session of its own")
        check(changed(refused(.approved(approval), online)),
              "an approval never goes into the conversation's typed session, so later questions cannot carry it again")
        let elsewhere = PiSession.LaunchRoute(key: "pi|anthropic|claude-fixture").online(anthropic, .init(), rules: SourceSharing())
        check(refused(.approved(approval), elsewhere).map { if case .destinationChanged = $0 { true } else { false } } == true,
              "an approval for one provider is refused when another one would receive it")
        let otherAccount = ShareDestination(gpt, recipient: "account-b")
        check(changed(refused(.approved(approval), approvedRoute(otherAccount))),
              "same Pi provider id with another endpoint, key or sign-in: the approval is refused")
        check(changed(refused(.approved(ShareApproval(destination: ShareDestination(gpt), question: "Check", parts: [])),
                              approvedRoute(ShareDestination(gpt)))),
              "a recipient whose endpoint or account cannot be determined never receives an approval")
        var noDocuments = SourceSharing(); noDocuments.documents = .localOnly
        check(refused(.approved(approval), approvedRoute(openai, rules: noDocuments)).map { if case .needsReview = $0 { true } else { false } } == true,
              "a rule set to “Only on this Mac” after the review stops the approved message when it is sent")
        let typedA = PiSession.LaunchRoute(key: "pi|openai|gpt-fixture|account-a").online(openai, .init(), rules: SourceSharing())
        let typedB = PiSession.LaunchRoute(key: "pi|openai|gpt-fixture|account-b").online(otherAccount, .init(), rules: SourceSharing())
        check(typedA.sessionScope == online.sessionScope && typedA.sessionScope != typedB.sessionScope && typedA.key != typedB.key,
              "typed words keep one session per recipient and account; a new account starts with fresh context")
        // GitHub Copilot: a renewal can route the same sign-in to another proxy endpoint (`PiRecipient.Identity`).
        let copilot = PiModelSelection(providerID: "github-copilot", modelID: "copilot-fixture", providerName: "GitHub Copilot")
        let reviewed = ShareDestination(copilot, identity: .init(recipient: "proxy-individual", account: "account-d"))
        let moved = ShareDestination(copilot, identity: .init(recipient: "proxy-business", account: "account-d"))
        let copilotApproval = ShareApproval(destination: reviewed, question: "Check", parts: [])
        let typedBefore = PiSession.LaunchRoute(key: "pi|github-copilot|proxy-individual").online(reviewed, .init(), rules: SourceSharing())
        let typedAfter = PiSession.LaunchRoute(key: "pi|github-copilot|proxy-business").online(moved, .init(), rules: SourceSharing())
        check(changed(refused(.approved(copilotApproval), approvedRoute(moved))) && typedBefore.sessionScope == typedAfter.sessionScope
              && typedBefore.key != typedAfter.key && (try? PiSession.message(.typed("Hello"), route: typedAfter)) == "Hello",
              "an endpoint the sign-in moved to needs a fresh review; typed words keep the account's session in a fresh Pi")
        check(PiSession.sameRecipient(typedA, typedA) && !PiSession.sameRecipient(typedA, typedB)
              && !PiSession.sameRecipient(approvedRoute(openai), approvedRoute(openai, rules: noDocuments)),
              "the check just before sending notices another account or changed rules")
        check(refused(.approved(approval), local).map { if case .destinationChanged = $0 { true } else { false } } == true,
              "an approval is not replayed to the AI on this Mac either")
        check((try? PiSession.message(.local(prompt), route: local)) == prompt, "the AI on this Mac still gets files and the app in front")

        check(online.sessionScope == openai.sessionTag && elsewhere.sessionScope == anthropic.sessionTag && local.sessionScope == nil
              && online.capabilities.online != nil && online.capabilities.memory == false && online.key != elsewhere.key,
              "each online AI has its own session and launch key; the AI on this Mac keeps the conversation's own")
        var strict = SourceSharing(); strict.calendar = .localOnly
        let stricter = PiSession.LaunchRoute(key: "pi|openai|gpt-fixture").online(openai, .init(), rules: strict)
        check(stricter.key != online.key && stricter.egress?.tools.contains("calendar_add") == false,
              "a changed sharing rule starts the online AI's Pi afresh with fewer tools")
        let handoff = approvedRoute(openai, handoff: true)
        check(handoff.sessionScope?.hasPrefix("handoff-") == true && handoff.key != online.key
              && (try? PiSession.message(.approved(approval), route: handoff)) == approval.message,
              "a single question gets a fresh session of its own")
        let connection = ModelConnection(provider: .compatible, endpoint: URL(string: "https://llm.example.invalid/v1"), modelID: "m-fixture")
        let legacy = ShareDestination(connection, recipient: PiRecipient.fingerprint(connection, key: "KEY-ONE"))
        let legacyApproval = ShareApproval(destination: legacy, question: "Check", parts: [])
        var legacyRoute = PiSession.LaunchRoute(key: "handoff|online", online: (connection, "KEY-ONE"))
            .online(legacy, .init(), rules: SourceSharing(), scope: PiSession.approvedScope(legacyApproval, handoff: true))
        legacyRoute.handoff = true
        let rekeyed = ShareDestination(connection, recipient: PiRecipient.fingerprint(connection, key: "KEY-TWO"))
        var rekeyedRoute = legacyRoute; rekeyedRoute.destination = rekeyed
        check((try? PiSession.message(.approved(legacyApproval), route: legacyRoute)) == legacyApproval.message
              && changed(refused(.approved(legacyApproval), rekeyedRoute)),
              "a single question to an older connection works, and a changed key refuses it")

        check(ChatModel.outgoing("Hi", files: [], frontApp: "Mail", undone: ["x"], online: true) == .typed("Hi"),
              "online: the app in front and undo notes stay here")
        check(ChatModel.outgoing("Hi", files: ["/Users/fixture/a.pdf"], frontApp: nil, undone: [], online: true) == nil,
              "online: attached files mean review first, nothing is sent")
        check(ChatModel.outgoing("Hi", files: ["/Users/fixture/a.pdf"], frontApp: "Mail", undone: [], online: false)
              == .local(ChatModel.prompt("Hi", files: ["/Users/fixture/a.pdf"], frontApp: "Mail")),
              "on this Mac: unchanged")

        // Mac access (issue #196): the person's grant for one verified recipient, never inferred, with a session of its own.
        let legacySettings = try? JSONDecoder().decode(InferenceSettings.self, from: Data(#"{"policy":"localOnly"}"#.utf8))
        check(legacySettings?.macAccess == nil && InferenceSettings().allowsMacAccess(openai) == false,
              "Mac access is off by default, also for settings saved before it existed")
        let privatemode = ShareDestination(PiModelSelection(providerID: "privatemode", modelID: "glm-5.3", providerName: "Privatemode"),
                                           recipient: "account-p")
        var granted = InferenceSettings(piModel: gpt); granted.macAccess = openai
        let otherModel = ShareDestination(PiModelSelection(providerID: "openai", modelID: "gpt-other", providerName: "OpenAI"), recipient: "account-a")
        check(granted.allowsMacAccess(openai) && !granted.allowsMacAccess(otherAccount) && !granted.allowsMacAccess(otherModel)
              && !granted.allowsMacAccess(privatemode) && !granted.allowsMacAccess(nil),
              "Mac access holds only for the recipient it was given to: another account, model or provider name gets none")
        var unverifiedGrant = InferenceSettings(piModel: gpt); unverifiedGrant.macAccess = ShareDestination(gpt)
        check(!unverifiedGrant.allowsMacAccess(ShareDestination(gpt)), "a recipient Pippa cannot verify never has Mac access")
        check(granted.disconnected(provider: "openai").macAccess == nil && granted.disconnected(provider: "anthropic").macAccess == openai,
              "signing out of the provider removes its Mac access")
        var choices = granted; choices.capabilities = .init(local: .init(web: true, memory: false), online: .init(web: false, memory: true))
        check(PiSession.macAccess(granted, openai, approved: false, handoff: false) != nil
              && PiSession.macAccess(granted, openai, approved: true, handoff: false) == nil
              && PiSession.macAccess(granted, openai, approved: true, handoff: true) == nil
              && PiSession.macAccess(granted, otherAccount, approved: false, handoff: false) == nil
              && PiSession.macAccess(choices, openai, approved: false, handoff: false) == .init(web: false, memory: false),
              "Mac access for the person's own words only; approvals and single questions keep the limits; web as online, notes as on this Mac")

        let trusted = PiSession.LaunchRoute(key: "pi|openai|gpt-fixture|account-a").online(openai, .init(), rules: SourceSharing(), macAccess: .init())
        check(trusted.hasMacAccess && trusted.egress == nil && trusted.destination == openai
              && trusted.capabilities == local.capabilities && PippaPiLaunch.tools(trusted.capabilities) == PippaPiLaunch.tools(local.capabilities)
              && ["read", "bash", "write", "mcp__pippa__*"].allSatisfy(PippaPiLaunch.tools(trusted.capabilities).contains)
              && PippaPiLaunch.nativeTools(trusted.capabilities) == PiNativeReadiness.tools,
              "with Mac access the online AI gets the tools of the AI on this Mac, and is still shown as the online AI")
        check((try? PiSession.message(.local(prompt), route: trusted)) == prompt && changed(refused(.approved(approval), trusted)),
              "with Mac access files and the app in front go as on this Mac; an approval still needs its own session")
        let trustedB = PiSession.LaunchRoute(key: "pi|openai|gpt-fixture|account-b").online(otherAccount, .init(), rules: SourceSharing(), macAccess: .init())
        check(trusted.sessionScope == openai.macAccessTag && trusted.sessionScope != typedA.sessionScope && trusted.sessionScope != nil
              && trusted.sessionScope != trustedB.sessionScope && trusted.key != typedA.key,
              "Mac access has its own session per recipient: revoking it or another account never reuses that history")
        check(!PiSession.sameRecipient(trusted, typedA) && !PiSession.sameRecipient(typedA, trusted)
              && refused(.local(prompt), typedA).map { if case .needsReview = $0 { true } else { false } } == true,
              "Mac access revoked or granted while Pi starts: the check before sending refuses the message")
        let unverifiedRoute = PiSession.LaunchRoute(key: "pi|openai").online(ShareDestination(gpt), .init(), rules: SourceSharing(), macAccess: .init())
        check(!unverifiedRoute.hasMacAccess && unverifiedRoute.egress != nil && unverifiedRoute.capabilities.online != nil,
              "an unverified recipient keeps the limits even if Mac access were passed")
        let dummyPaths = PippaPiLaunch.Paths(
            extensionsDirectory: URL(fileURLWithPath: "/tmp/ext", isDirectory: true), webExtension: nil,
            sessionDirectory: URL(fileURLWithPath: "/tmp/sessions", isDirectory: true), skillsDirectory: nil,
            memoryFile: URL(fileURLWithPath: "/tmp/mem.md"), digestDirectory: URL(fileURLWithPath: "/tmp/digests", isDirectory: true)
        )
        let dummyLauncher = PippaPiLaunch.Launcher(executable: URL(fileURLWithPath: "/usr/bin/env"), launcherArguments: [], piArguments: [], environment: [:])
        let dummyMCP = (endpoint: PippaPiLaunch.MCPEndpoint(url: URL(string: "http://127.0.0.1:1/mcp")!, token: "tok"),
                        extension: URL(fileURLWithPath: "/tmp/ext/mcp.ts"))
        func launchedMaxCalls(_ route: PiSession.LaunchRoute) -> String? {
            PippaPiLaunch.configuration(launcher: dummyLauncher, workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
                                        paths: dummyPaths, sessionID: "s", language: "de", environment: route.budgetEnvironment,
                                        mcp: dummyMCP, capabilities: route.capabilities).environment["PIPPA_MAX_CALLS"]
        }
        check(launchedMaxCalls(trusted) == "80" && launchedMaxCalls(local) == nil && launchedMaxCalls(online) == nil
              && launchedMaxCalls(handoff) == nil && launchedMaxCalls(unverifiedRoute) == nil,
              "PIPPA_MAX_CALLS=80 goes only to a verified online route with Mac access; local, restricted online and handoff keep the default")
        func launchedExposure(_ route: PiSession.LaunchRoute) -> String? {
            var mcp = dummyMCP
            mcp.endpoint.exposure = route.mcpExposure
            return PippaPiLaunch.configuration(launcher: dummyLauncher, workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true),
                                               paths: dummyPaths, sessionID: "s", language: "de", environment: route.budgetEnvironment,
                                               mcp: mcp, capabilities: route.capabilities).environment["PIPPA_MCP_EXPOSURE"]
        }
        check(launchedExposure(trusted) == "direct+codemode" && [local, online, handoff, unverifiedRoute].allSatisfy { launchedExposure($0) == "direct" },
              "only an online AI with Mac access gets Pi's codemode tool; this Mac, the limited online AI and single questions keep direct tools only")
        return failures == 0 ? 0 : 1
    }

    /// The last step before Pi's first request (`PiSession.admitted`), with the settings in a temporary folder and a
    /// stand-in for the already running Pi that counts every prompt it is given. Reading the route again awaits the
    /// provider's files and the Keychain; Mac access revoked meanwhile must send nothing, from the window, the Island
    /// (both `.local` through ChatModel.send) and `Pippa --ask` (`.typed`).
    static func admission() async -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print("\(ok ? "PASS" : "FAIL") \(name)")
            if !ok { failures += 1 }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-admission-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let gpt = PiModelSelection(providerID: "openai", modelID: "gpt-fixture", providerName: "OpenAI")
        let openai = ShareDestination(gpt, recipient: "account-a")
        var granted = InferenceSettings(piModel: gpt); granted.macAccess = openai
        var revoked = granted; revoked.macAccess = nil
        let latest = { InferenceSettings.load(from: folder) }
        func save(_ settings: InferenceSettings) { try? settings.save(to: folder) }
        let session = PiSession()
        /// What `launchRoute` does: the settings first, the route from them, and the revision of that moment.
        func read() -> PiSession.LaunchRoute {
            let settings = latest()
            var route = PiSession.LaunchRoute(key: "pi|openai|gpt-fixture|account-a")
                .online(openai, settings.capabilities.online, rules: settings.sharing,
                        macAccess: PiSession.macAccess(settings, openai, approved: false, handoff: false))
            route.admission = .init(settings: settings, revision: session.settingsRevision)
            return route
        }
        let prompt = ChatModel.prompt("Sort these", files: ["/Users/fixture/Documents/Lease.pdf"], frontApp: "Mail")

        /// One turn: `warm` is the route the running Pi was started for; the re-read takes its settings, then waits
        /// (provider files, Keychain) while `meanwhile` runs on the main actor.
        func turn(_ outgoing: PiSession.Outgoing, meanwhile: () async -> Void, duringSend: @escaping () -> Void = {}) async -> (sent: [String], error: PiSession.Failure?) {
            save(granted)
            let warm = read()
            let text = (try? PiSession.message(outgoing, route: warm)) ?? ""
            var sent: [String] = []
            var waiting: CheckedContinuation<Void, Never>?
            let attempt = Task { @MainActor () -> PiSession.Failure? in
                do {
                    _ = try await session.admitted(warm, text: text, outgoing: outgoing, reread: {
                        let route = read()
                        await withCheckedContinuation { waiting = $0 }
                        return route
                    }, latest: latest, send: { text in sent.append(text); duringSend(); return 0 })
                    return nil
                } catch { return error as? PiSession.Failure ?? .setup(String(describing: error)) }
            }
            while waiting == nil { await Task.yield() }
            await meanwhile()
            waiting?.resume()
            let error = await attempt.value
            return (sent, error)
        }
        func refused(_ result: (sent: [String], error: PiSession.Failure?)) -> Bool { result.sent.isEmpty && result.error != nil }

        let unchanged = await turn(.local(prompt)) {}
        check(unchanged.sent == [prompt] && unchanged.error == nil, "nothing changed: the running Pi gets the prompt once")
        let native = PippaMCPTurn()
        PippaMCPService.begin(native)
        let stopped = await turn(.local(prompt)) { await session.stop() }
        check(native.writes.snapshot.cancelled, "Stop cancels native read/write dispatch before awaiting Pi")
        PippaMCPService.end(native)
        check(refused(stopped), "Stop while the final reread is suspended prevents dispatch")
        let local = PiSession.LaunchRoute(key: "local|fixture").with(.init(web: false, memory: false))
        let changedLocal = local.with(.init(web: false, memory: true))
        do {
            _ = try await session.admitted(local, text: prompt, outgoing: .local(prompt),
                                           reread: { changedLocal }, latest: latest, send: { _ in 0 })
            check(false, "changed local capabilities refuse the unsent question")
        } catch {
            check(error as? PiSession.Failure == .settingsChanged, "changed local capabilities report an AI settings change")
        }
        let window = await turn(.local(prompt)) { save(revoked); session.settingsChanged() }
        check(refused(window) && window.error == .needsReview,
              "window and Island: Mac access revoked while the route is read again, the running Pi gets nothing")
        let headless = await turn(.typed("Hello")) { save(revoked); session.settingsChanged() }
        check(refused(headless) && headless.error == .destinationChanged, "Pippa --ask: the same revocation sends nothing either")
        let elsewhere = await turn(.local(prompt)) { save(revoked) }
        check(refused(elsewhere), "revoked by another Pippa process (only on disk): nothing is sent")
        let signedOut = await turn(.local(prompt)) { save(granted.disconnected(provider: "openai")); session.settingsChanged() }
        check(refused(signedOut), "signed out of the provider meanwhile: nothing is sent")
        let rules = await turn(.local(prompt)) { var stricter = granted; stricter.sharing.mail = .localOnly; save(stricter) }
        check(refused(rules), "a sharing rule saved meanwhile: nothing is sent")
        let saved = await turn(.local(prompt)) { session.settingsChanged() }
        check(refused(saved), "any change saved in this process meanwhile: nothing is sent")
        var revision = 0
        let admitted = await turn(.local(prompt), meanwhile: {}, duringSend: { save(revoked); session.settingsChanged(); revision = session.settingsRevision })
        check(admitted.sent == [prompt] && admitted.error == nil,
              "revoked after the prompt was admitted: that answer goes on, as Settings says (the next question)")
        save(revoked)
        let next = read()
        check(revision == session.settingsRevision && !next.hasMacAccess && (try? PiSession.message(.local(prompt), route: next)) == nil,
              "the next question reads the revoked settings: the limits, and files and the app in front need review")
        return failures == 0 ? 0 : 1
    }
}
