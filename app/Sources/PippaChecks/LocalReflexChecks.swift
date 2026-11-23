import Foundation
import PippaCore

/// Offline checks for the Tier-0 local reflex layer (`LocalReflex.swift`).
func runLocalReflexChecks() async {
    await checkAsync("LocalReflex: happy-path title generation returns clean title") {
        let stub = StubReflexModel(available: true) { _, language in
            language.hasPrefix("de") ? "Frist für Widerspruch" : "Lease Notice Period"
        }
        let en = await stub.conversationTitle(for: "Find my lease and tell me the notice period", language: "en")
        let de = await stub.conversationTitle(for: "Welche Frist gilt für den Widerspruch?", language: "de")
        return stub.isAvailable
            && en == "Lease Notice Period"
            && de == "Frist für Widerspruch"
            && stub.receivedLanguages == ["en", "de"]
    }

    await checkAsync("LocalReflex: unavailable model returns nil without invoking generator") {
        let stub = StubReflexModel(available: false) { _, _ in "Should Not Run" }
        let result = await stub.conversationTitle(for: "Check my calendar this week", language: "en")
        return !stub.isAvailable && result == nil && stub.callCount == 0
    }

    await checkAsync("LocalReflex: refusal and empty outputs sanitize to nil while legitimate policy titles stay") {
        let badOutputs = [
            "",
            "   \n\t  ",
            "...",
            "---",
            "I'm sorry, I cannot assist with that request.",
            "I cannot generate a title for this prompt.",
            "This request may contain sensitive content.",
            "As an AI, I cannot help with that.",
            "Es tut mir leid, ich kann dabei nicht helfen.",
            "Ich kann keinen Titel für diesen Inhalt erstellen.",
            "Untitled",
            "No title",
            "Kein Titel",
        ]
        for raw in badOutputs {
            if LocalReflexTitleSanitizer.sanitize(raw) != nil { return false }
        }
        let stub = StubReflexModel(available: true, title: "I'm sorry, I cannot assist with that.")
        let refused = await stub.conversationTitle(for: "Health insurance letter", language: "en")
        let legitimate = LocalReflexTitleSanitizer.sanitize("Insurance Policy Renewal")
        return refused == nil && legitimate == "Insurance Policy Renewal"
    }

    await checkAsync("LocalReflex: markdown, quotes, and newlines are stripped and titles cap at 60 chars") {
        let formatted = "\n  ### **\"Lease `Notice` Period\"**  \nHere is a short title for you."
        let cleaned = LocalReflexTitleSanitizer.sanitize(formatted)

        let germanQuotes = "  „Frist für *Widerspruch*“\nZweite Zeile"
        let cleanedDE = LocalReflexTitleSanitizer.sanitize(germanQuotes)

        let longWords = "Quarterly financial review and tax deduction summary for rental property management expenses"
        let cappedWords = LocalReflexTitleSanitizer.sanitize(longWords)

        let longSingleToken = String(repeating: "x", count: 95)
        let cappedToken = LocalReflexTitleSanitizer.sanitize(longSingleToken)

        let stub = StubReflexModel(available: true, title: "  # `\"Calendar Check\"`\nExtra line ")
        let fromStub = await stub.conversationTitle(for: "What is on my calendar?", language: "en")

        return cleaned == "Lease Notice Period"
            && cleanedDE == "Frist für Widerspruch"
            && fromStub == "Calendar Check"
            && (cappedWords?.count ?? 99) <= LocalReflexTitleSanitizer.maxTitleLength
            && cappedWords?.isEmpty == false
            && cappedWords?.contains("\n") == false
            && cappedToken?.count == LocalReflexTitleSanitizer.maxTitleLength
    }

    await checkAsync("LocalReflex: overlong prompt (>2000 chars) is truncated before passing to model") {
        let hugePrompt = String(repeating: "a", count: 2500) + " tail-that-must-not-pass"
        let stub = StubReflexModel(available: true) { prompt, _ in
            prompt.count <= LocalReflexTitleSanitizer.maxInputLength ? "Long Document Summary" : "Too Long"
        }
        let title = await stub.conversationTitle(for: hugePrompt, language: "en")
        let passed = stub.receivedPrompts.first
        return title == "Long Document Summary"
            && passed?.count == LocalReflexTitleSanitizer.maxInputLength
            && passed?.contains("tail-that-must-not-pass") == false
    }

    await checkAsync("LocalReflex: timeout and thrown errors return nil cleanly") {
        enum SampleError: Error { case guardrail }
        let failing = StubReflexModel(available: true) { _, _ in throw SampleError.guardrail }
        let failedResult = await failing.conversationTitle(for: "Summarize this letter", language: "en")

        let slow = StubReflexModel(available: true, timeout: .milliseconds(80)) { _, _ in
            try await Task.sleep(for: .seconds(5))
            return "Late Title"
        }
        let timedOut = await slow.conversationTitle(for: "Slow request", language: "en")
        return failedResult == nil && timedOut == nil
    }

    check("LocalReflex: manual-rename guard never overwrites user-renamed conversations") {
        let unchanged = ConversationTitlePolicy.shouldApplyRefinedTitle(
            current: "Find my lease and tell me the notice period",
            initial: "Find my lease and tell me the notice period",
            refined: "Lease Notice Period"
        )
        let renamedByUser = ConversationTitlePolicy.shouldApplyRefinedTitle(
            current: "Apartment Lease 2026",
            initial: "Find my lease and tell me the notice period",
            refined: "Lease Notice Period"
        )
        let emptyRefined = ConversationTitlePolicy.shouldApplyRefinedTitle(
            current: "Find my lease",
            initial: "Find my lease",
            refined: "   "
        )
        let refusedRefined = ConversationTitlePolicy.shouldApplyRefinedTitle(
            current: "Find my lease",
            initial: "Find my lease",
            refined: "I'm sorry, I cannot assist with that."
        )
        let identical = ConversationTitlePolicy.shouldApplyRefinedTitle(
            current: "Lease Notice Period",
            initial: "Lease Notice Period",
            refined: "Lease Notice Period"
        )
        return unchanged && !renamedByUser && !emptyRefined && !refusedRefined && !identical
    }

    await checkAsync("LocalReflex: AppleFoundationReflex honors PIPPA_NO_SYSTEM_MODEL in checks") {
        let reflex = AppleFoundationReflex(timeout: .milliseconds(200))
        let result = await reflex.conversationTitle(for: "Check my calendar", language: "en")
        return !reflex.isAvailable && result == nil
    }
}
