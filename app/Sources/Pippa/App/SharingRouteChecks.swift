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
        let openai = ShareDestination(PiModelSelection(providerID: "openai", modelID: "gpt-fixture", providerName: "OpenAI"))
        let anthropic = ShareDestination(PiModelSelection(providerID: "anthropic", modelID: "claude-fixture", providerName: "Anthropic"))
        let local = PiSession.LaunchRoute(key: "local|m").with(.init())
        let online = PiSession.LaunchRoute(key: "pi|openai|gpt-fixture").online(openai, .init(), rules: SourceSharing())
        let approval = ShareApproval(destination: openai, question: "Check", parts: [.init(title: "Lease.pdf", sources: [.documents], text: "DOC-MARKER")])
        func refused(_ outgoing: PiSession.Outgoing, _ route: PiSession.LaunchRoute) -> PiSession.Failure? {
            do { _ = try PiSession.message(outgoing, route: route); return nil } catch { return error as? PiSession.Failure }
        }

        let prompt = ChatModel.prompt("Sort these", files: ["/Users/fixture/Documents/Lease.pdf"], frontApp: "Mail", undone: ["Dentist"])
        check(refused(.local(prompt), online).map { if case .needsReview = $0 { true } else { false } } == true,
              "a prompt with file paths and the app in front never goes to an online AI")
        check((try? PiSession.message(.typed("Hello"), route: online)) == "Hello", "typed words go to the online AI as they are")
        check((try? PiSession.message(.approved(approval), route: online)) == approval.message, "an approval goes out exactly as approved")
        let elsewhere = PiSession.LaunchRoute(key: "pi|anthropic|claude-fixture").online(anthropic, .init(), rules: SourceSharing())
        check(refused(.approved(approval), elsewhere).map { if case .destinationChanged = $0 { true } else { false } } == true,
              "an approval for one provider is refused when another one would receive it")
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
        let handoff = PiSession.LaunchRoute(key: "handoff|openai|gpt-fixture")
            .online(openai, .init(), rules: SourceSharing(), scope: "handoff-" + approval.id.uuidString.lowercased())
        check(handoff.sessionScope?.hasPrefix("handoff-") == true && handoff.key != online.key,
              "a single question gets a fresh session of its own")

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
