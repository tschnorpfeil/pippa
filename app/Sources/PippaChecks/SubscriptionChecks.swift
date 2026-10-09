import Foundation
import PippaCore

/// ChatGPT subscription through Pi's own sign-in (PiSubscriptionAuth + runtime/pippa-auth/pi-auth.mjs). Here with a
/// stand-in helper: no network, no real sign-in (that one is the live test with the person's own click).
func runSubscriptionChecks() async {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pippa-subscription-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    guard let nodePath = ProcessInfo.processInfo.environment["PIPPA_NODE_BINARY"]
            ?? ["/opt/homebrew/bin/node", "/usr/local/bin/node", NSHomeDirectory() + "/.local/bin/node"].first(where: FileManager.default.isExecutableFile)
    else { print("  (subscription checks skipped: no node)"); return }
    func helper(_ body: String) -> PiSubscriptionAuth {
        let url = dir.appendingPathComponent("helper-\(UUID().uuidString).mjs")
        try? ("const out = v => process.stdout.write(JSON.stringify(v) + '\\n');\nconst [, , release, command] = process.argv;\n" + body)
            .write(to: url, atomically: true, encoding: .utf8)
        return PiSubscriptionAuth(node: URL(fileURLWithPath: nodePath), release: dir, helper: url, environment: ["PATH": "/usr/bin:/bin"])
    }

    await checkAsync("Subscription status: read from Pi through the helper, never a token") {
        let auth = helper("out({signedIn: true, kind: 'subscription', defaultModel: 'gpt-x', models: ['gpt-x', 'gpt-y']});")
        let status = try await auth.status()
        let none = try await helper("out({signedIn: false, kind: 'apiKey', defaultModel: 'gpt-x', models: []});").status()
        return status == .init(signedIn: true, kind: "subscription", defaultModel: "gpt-x", models: ["gpt-x", "gpt-y"])
            && !none.signedIn && none.kind == "apiKey"
    }
    await checkAsync("Sign-in: only OpenAI's page is opened in the browser; done returns the new status") {
        let opened = LockedBox<[String]>([])
        let auth = helper("""
            out({event: 'open', url: 'https://evil.example/login'});
            out({event: 'open', url: 'https://auth.openai.com/oauth/authorize?state=x'});
            out({event: 'done', signedIn: true, kind: 'subscription', defaultModel: 'gpt-x', models: ['gpt-x']});
            """)
        let status = try await auth.signIn { url in opened.mutate { $0.append(url.absoluteString) } }
        return status.signedIn && opened.value == ["https://auth.openai.com/oauth/authorize?state=x"]
    }
    await checkAsync("Sign-in errors keep their meaning; cancelling ends the helper") {
        func failure(_ code: String) async -> PiSubscriptionAuth.Failure? {
            do { _ = try await helper("out({event: 'error', code: '\(code)'});").signIn { _ in }; return nil }
            catch { return error as? PiSubscriptionAuth.Failure }
        }
        let busy = await failure("port_busy"), missing = await failure("pi_missing"), other = await failure("failed")
        let hanging = helper("out({event: 'open', url: 'https://auth.openai.com/x'}); setInterval(() => {}, 1000); process.on('SIGTERM', () => { out({event: 'error', code: 'cancelled'}); process.exit(0); });")
        let task = Task { try await hanging.signIn { _ in } }
        try await Task.sleep(for: .milliseconds(600))
        task.cancel()
        let cancelled: PiSubscriptionAuth.Failure?
        do { _ = try await task.value; cancelled = nil } catch { cancelled = error as? PiSubscriptionAuth.Failure }
        return busy == .portBusy && missing == .unavailable && other == .failed && cancelled == .cancelled
    }
    check("Subscription errors: expired sign-in and limit are recognized, anything else stays a general error") {
        PiSubscriptionAuth.problem(in: "401 Unauthorized: token expired") == .signedOut
            && PiSubscriptionAuth.problem(in: "invalid_grant: refresh token revoked") == .signedOut
            && PiSubscriptionAuth.problem(in: "No API key found for openai.\n\nUse /login to log into a provider") == .signedOut
            && PiSubscriptionAuth.problem(in: "429 Too Many Requests: usage limit reached") == .limit
            && PiSubscriptionAuth.problem(in: "socket hang up") == nil
    }
    check("Sign-in page check: https on openai.com or chatgpt.com only") {
        PiSubscriptionAuth.isSignInPage(URL(string: "https://auth.openai.com/oauth/authorize")!)
            && !PiSubscriptionAuth.isSignInPage(URL(string: "http://auth.openai.com/x")!)
            && !PiSubscriptionAuth.isSignInPage(URL(string: "https://auth.openai.com.evil.example/x")!)
    }
    check("Settings: the subscription is stored as its model only, off by default, older files load as off") {
        let base = dir.appendingPathComponent("settings-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let fresh = InferenceSettings.load(from: base)
        try? InferenceSettings(policy: .localOnly, connection: nil, subscriptionModel: "gpt-x").save(to: base)
        let on = InferenceSettings.load(from: base)
        try? Data(#"{"policy":"localOnly"}"#.utf8).write(to: base.appendingPathComponent("inference-settings.json"))
        let old = InferenceSettings.load(from: base)
        let text = (try? String(contentsOf: base.appendingPathComponent("inference-settings.json"), encoding: .utf8)) ?? ""
        return fresh.subscriptionModel == nil && on.subscriptionModel == "gpt-x" && old.subscriptionModel == nil && !text.contains("token")
    }
}
