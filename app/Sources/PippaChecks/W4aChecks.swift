import Foundation
import PippaCore

// What stays in the product no longer depends on the old conversation core. Letter suggestions and "Check online"
// run as fixed flows with structured calls (LetterModel, LocalModelJSON), skills live in runtime/pippa-skills,
// web access is the Pi package pi-web-access in runtime/pippa-web.
// Runs with PIPPA_W4A_CHECKS=1 and in the full run. No model, no Pi, no network.
func runW4aChecks() async {
    print("\n— Without the old conversation core —")
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let read = { (path: String) in (try? String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)) ?? "" }

    // MARK: Locations

    check("Cleanup: skills live in runtime/pippa-skills (15), runtime/pi/skills no longer exists") {
        let folders = ((try? fm.contentsOfDirectory(atPath: repo.appendingPathComponent("runtime/pippa-skills").path)) ?? []).filter { !$0.hasPrefix(".") }
        return folders.count == 15 && !fm.fileExists(atPath: repo.appendingPathComponent("runtime/pi/skills").path)
            && PippaSkill.bundledDirectory().standardizedFileURL == PippaSkill.repositoryDirectory.standardizedFileURL
            && PippaSkill.bundled.count == 15
    }
    check("Cleanup: web access is the Pi package pi-web-access in runtime/pippa-web, no own fetch process") {
        let manifest = read("runtime/pippa-web/package.json")
        return fm.fileExists(atPath: repo.appendingPathComponent("runtime/pippa-web/index.ts").path)
            && fm.fileExists(atPath: repo.appendingPathComponent("runtime/pippa-web/package-lock.json").path)
            && !fm.fileExists(atPath: repo.appendingPathComponent("runtime/pippa-web/src/fetcher.mjs").path)
            && !fm.fileExists(atPath: repo.appendingPathComponent("app/Sources/PippaCore/Lookup").path)
            && manifest.contains("\"pi-web-access\": \"0.38.0\"")
            && PiConversationDefault.bundledWeb(bundle: URL(fileURLWithPath: "/A/Pippa.app")).path == "/A/Pippa.app/Contents/Resources/pippa-web/index.ts"
    }
    check("Cleanup: build-app.sh bundles web access, skills and payload, but no old runtime any more") {
        let build = read("scripts/build-app.sh"), verify = read("scripts/verify-app.sh")
        return build.contains("scripts/bundle-web.sh") && build.contains("runtime/pippa-skills\" \"$APP/Contents/Resources/pippa-skills\"")
            && !build.contains("bundle-pi-runtime") && !build.contains("pi-runtime") && !build.contains("LEGACY")
            && verify.contains("[[ ! -e \"$APP/Contents/Resources/pi-runtime\" ]]") && verify.contains("Contents/Resources/pippa-skills")
            && verify.contains("expected_skills") && verify.contains("runtime/pippa-web/package-lock.json")
            && read("app/Sources/Pippa/App/BundleVerification.swift").contains("pi-payload/release")
            && !read("app/Sources/Pippa/App/BundleVerification.swift").contains("\"Contents/Resources/pi-runtime\"")
            // The release probe checks only what bundle-web.sh ships (the removed fetcher made every release fail).
            && !read("app/Sources/Pippa/App/BundleVerification.swift").contains("fetcher.mjs")
            && read("app/Sources/Pippa/App/BundleVerification.swift").contains("node_modules/pi-web-access/dist/index.js")
    }
    // What stays does not name the old core (types in AnswerTypes/ToolBridgeTypes, comparison in GermanText).
    check("Cleanup: remaining parts without PiRuntimeClient, ContextSelection, LocalEngine.chat and pi-runtime") {
        let kept = ["app/Sources/PippaCore/LocalModelJSON.swift", "app/Sources/PippaCore/Skills.swift",
                    "app/Sources/PippaCore/SourceFidelity.swift", "app/Sources/PippaCore/PiShownContext.swift", "app/Sources/PippaCore/PiReadLedger.swift",
                    "app/Sources/PippaCore/AnswerTypes.swift",
                    "app/Sources/PippaCore/ToolBridgeTypes.swift", "app/Sources/Pippa/App/BundleVerification.swift", "app/Sources/Pippa/App/PiRPCChat.swift",
                    "app/Sources/Pippa/App/PiRPCChat+Shown.swift"]
        let bad = kept.filter { path in
            // Code only, no comments (those name the origin).
            let text = read(path).components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            return text.isEmpty || text.contains("PiRuntimeClient") || text.contains("ContextSelection.") || text.contains(".chat(")
                || text.contains("\"Contents/Resources/pi-runtime") || text.contains("PIPPA_PI_RUNTIME")
        }
        if !bad.isEmpty { print("   ", bad) }
        return bad.isEmpty
    }
    check("Cleanup: the letter checks online through Pi (skill online-pruefen), no fixed model flow, no engine.chat") {
        let letter = read("app/Sources/Pippa/App/LetterController.swift")
        return letter.contains("\"online-pruefen\"") && !letter.contains("proposeLetterActions(") && !letter.contains("engine.checkOnline(")
            && !letter.contains("takeProposedActions") && !letter.contains("takeCitations")
            && !letter.contains("engine.chat(") && !letter.contains("LEGACY")
    }

    // The old core is gone entirely; nothing in the code names it any more (comments may name the origin).
    check("Cleanup: runtime/pi, old scripts and types of the old core no longer exist") {
        let gone = ["runtime/pi", "scripts/bundle-pi-runtime.sh", "scripts/check-pi-contract.sh", "app/Sources/PippaNativeChecks",
                    "app/Sources/PippaCore/PiRuntimeClient.swift", "app/Sources/PippaCore/ChatShim.swift", "app/Sources/PippaCore/ContextSelection.swift",
                    "app/Sources/PippaCore/QuickAnswerBoundary.swift", "app/Sources/PippaCore/PiPlan.swift", "app/Sources/Pippa/App/InferenceRouting.swift"]
        let left = gone.filter { fm.fileExists(atPath: repo.appendingPathComponent($0).path) }
        let banned = ["PiRuntimeClient", "ChatShim", "ContextSelection", "QuickAnswerBoundary", "PIPPA_LEGACY_CHAT", "InferenceRoute",
                      "configureInference", "takeProposedPlan", "takeProposedActions", "takeCitations", "forgetChat", "steerChat", "PIPPA_PI_RUNTIME"]
        var named: [String] = []
        let sources = repo.appendingPathComponent("app/Sources")
        for case let url as URL in fm.enumerator(at: sources, includingPropertiesForKeys: nil) ?? FileManager.DirectoryEnumerator()
        where url.pathExtension == "swift" && !["W4aChecks.swift", "R6Checks.swift"].contains(url.lastPathComponent) {
            let code = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for word in banned where code.contains(word) { named.append(url.lastPathComponent + ": " + word) }
        }
        let ci = read(".github/workflows/ci.yml")
        if !left.isEmpty || !named.isEmpty { print("   ", left, named) }
        return left.isEmpty && named.isEmpty && !ci.contains("runtime/pi\n") && !ci.contains("PIPPA_INFERENCE_FIXTURE")
            && !read("app/Package.swift").contains("PippaNativeChecks")
    }

    // MARK: LocalModelJSON (without a server)

    check("LocalModelJSON builds the request like the old core (schema grammar, 0.1, thinking off, limit ¼ of context)") {
        guard let body = try? LocalModelJSON.body(modelID: "m", system: "S", user: "U", schema: #"{"type":"object"}"#, name: "x_1", contextWindow: 16384),
              let messages = body["messages"] as? [[String: String]], let format = body["response_format"] as? [String: Any],
              let schema = format["json_schema"] as? [String: Any] else { return false }
        return messages.count == 2 && messages[0]["content"]?.hasSuffix(#"Return only JSON matching this schema: {"type":"object"}"#) == true
            && messages[1]["content"] == "U" && body["max_tokens"] as? Int == 4096 && body["temperature"] as? Double == 0.1
            && (body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"] == false
            && schema["name"] as? String == "x_1" && schema["strict"] as? Bool == true && LocalModelJSON.maxTokens(contextWindow: 8192) == 2048
    }
    check("LocalModelJSON rejects requests that are too long, wrong names and truncated answers") {
        let long = String(repeating: "ä", count: 9000)   // 18,000 bytes > 2 × 8192
        let tooLong = (try? LocalModelJSON.body(modelID: "m", system: "S", user: long, schema: "{}", name: "x", contextWindow: 8192)) == nil
        let badName = (try? LocalModelJSON.body(modelID: "m", system: "S", user: "U", schema: "{}", name: "a b", contextWindow: 8192)) == nil
        let ok = #"{"choices":[{"finish_reason":"stop","message":{"content":"{\"a\":1}"}}]}"#
        let cut = #"{"choices":[{"finish_reason":"length","message":{"content":"{\"a\":"}}]}"#
        return tooLong && badName && (try? LocalModelJSON.content(of: Data(ok.utf8))) == Data(#"{"a":1}"#.utf8)
            && (try? LocalModelJSON.content(of: Data(cut.utf8))) == nil && (try? LocalModelJSON.content(of: Data("{}".utf8))) == nil
    }

    // MARK: Connection test (settings) without the old core

    check("Connection test: right address, key only in the header, fixed sentence, status → plain-language sentence") {
        guard let openAI = try? ModelConnectionTest.request(ModelConnection(provider: .openAI, modelID: "gpt-x"), apiKey: "sk-1"),
              let anthropic = try? ModelConnectionTest.request(ModelConnection(provider: .anthropic, modelID: "claude-x"), apiKey: "ak-1"),
              let local = try? ModelConnectionTest.request(ModelConnection(provider: .compatible, endpoint: URL(string: "http://127.0.0.1:8080/v1")!, modelID: "m"), apiKey: "")
        else { return false }
        let body = String(decoding: openAI.httpBody ?? Data(), as: UTF8.self)
        let auth = { (f: AnswerFailure?) -> AnswerFailureCode? in if case .pi(let code, _) = f { code } else { nil } }
        return openAI.url?.absoluteString == "https://api.openai.com/v1/chat/completions" && openAI.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1"
            && anthropic.url?.path == "/v1/messages" && anthropic.value(forHTTPHeaderField: "x-api-key") == "ak-1"
            && anthropic.value(forHTTPHeaderField: "anthropic-version") != nil && anthropic.value(forHTTPHeaderField: "Authorization") == nil
            && local.url?.absoluteString == "http://127.0.0.1:8080/v1/chat/completions" && local.value(forHTTPHeaderField: "Authorization") == nil
            && !body.contains("sk-1") && body.contains("Connection test")
            && ModelConnectionTest.failure(status: 200) == nil && auth(ModelConnectionTest.failure(status: 401)) == .authFailed
            && auth(ModelConnectionTest.failure(status: 404)) == .providerRejected && auth(ModelConnectionTest.failure(status: 503)) == .providerUnreachable
            && !read("app/Sources/PippaCore/LocalEngine.swift").contains("client.testConnection()")
    }
}
