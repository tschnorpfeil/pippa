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
        return failures == 0 ? 0 : 1
    }
}
