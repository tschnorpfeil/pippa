import Foundation
import PippaCore

/// Values between host and model (ToolBridgeTypes.swift): ChatContext defaults, lookup status names,
/// inserting into Mail only with permission and without sending.
func runAgentBridgeChecks() async {
    check("Agent bridge: ChatContext without arguments shows nothing and allows no online lookup") {
        let plain = ChatContext()
        let selected = ChatContext(files: [], selectedText: "x", workflowSummary: "")
        return plain.files.isEmpty && plain.onWork == nil && plain.maximumFileCount == 20
            && selected.maximumFileCount == 19
    }
    await checkAsync("Agent bridge: inserting creates only an unsent reply window, and only with permission for Mail") {
        let draft = MailDraft(messageID: "bridge@example.invalid", to: "a@b.de", toName: nil, subject: "x", body: "y")
        let granted = DemoIntegrations(granted: true)
        let engine = LocalEngine(baseDirectory: dir("bridge-insert"), modelEnabled: false, integrations: granted)
        let result = try await engine.insertMailReply(draft)
        guard result == .reply, granted.insertedDrafts == [draft] else { return false }
        let closed = DemoIntegrations()
        let without = LocalEngine(baseDirectory: dir("bridge-insert-denied"), modelEnabled: false, integrations: closed)
        var refused = false
        do { _ = try await without.insertMailReply(draft) } catch PippaError.accessDenied { refused = true }
        let stub = StubEngine(delay: 0, integrations: DemoIntegrations(granted: true))
        let stubResult = try await stub.insertMailReply(draft)
        // Without a model: keeping warm starts nothing.
        await engine.keepWarmAfterCall()
        return refused && closed.insertedDrafts.isEmpty && stubResult == .reply && stub.integrations.insertedDrafts.count == 1
            && LlamaServer.afterCallSeconds == 1200
    }
}
