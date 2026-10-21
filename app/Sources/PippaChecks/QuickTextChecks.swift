import Foundation
import PippaCore

private struct TextModelFixture: QuickLanguageModel {
    var availability: QuickModelAvailability = .available
    var chunks: [String] = []
    var fails = false
    var stalls = false
    var started: LockedBox<Bool>?

    func stream(instructions: String, prompt: String, maximumTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { sink in
            let task = Task {
                do {
                    for chunk in chunks { sink.yield(chunk) }
                    started?.mutate { $0 = true }
                    if stalls { try await Task.sleep(for: .seconds(60)) }
                    if fails { throw QuickModelError.failed }
                    sink.finish()
                } catch { sink.finish(throwing: error) }
            }
            sink.onTermination = { _ in task.cancel() }
        }
    }
}

func runQuickTextChecks() async {
    func accepts(_ skill: String?, _ text: String = "A short note.", files: Bool = false, available: Bool = true) -> Bool {
        QuickTextAction.accepts(skill: skill, selectedText: text, hasFiles: files, systemModel: available)
    }
    check("Quick text: only explicit text actions with a small selection can bypass Pi") {
        QuickTextAction.skills.allSatisfy { accepts($0) }
            && !accepts(nil) && !accepts("fristen-erkennen") && !accepts("antwort-schreiben")
            && !accepts("text-kuerzen", "  \n") && !accepts("text-kuerzen", files: true)
            && !accepts("checkliste", available: false)
            && accepts("text-verbessern", String(repeating: "a", count: QuickTextAction.selectionBytes))
            && !accepts("text-verbessern", String(repeating: "a", count: QuickTextAction.selectionBytes + 1))
            && !accepts("text-verbessern", String(repeating: "🦊", count: 251))
    }
    check("Quick text: instructions separate source data from action and give no Mac tools") {
        let instructions = QuickTextAction.instructions(skillInstructions: "Correct spelling only.", language: "en")
        return instructions.contains("untrusted data") && instructions.contains("Do not use tools")
            && instructions.contains("Correct spelling only.") && instructions.contains("[[WAIT]]")
    }
    await checkAsync("Quick text: returns a complete short result") {
        try await QuickTextAction.answer(skillInstructions: "Correct spelling.", selectedText: "Helo!", language: "en",
                                         model: TextModelFixture(chunks: ["Hello", "!\n", QuickTextAction.completionToken])) == "Hello!"
    }
    await checkAsync("Quick text: failure after partial output, refusal and empty output fall through to Pi") {
        for model in [TextModelFixture(chunks: ["Half a draft"], fails: true),
                      TextModelFixture(chunks: ["Normally ended but token-limited partial draft"]),
                      TextModelFixture(chunks: [QuickTextAction.completionToken]),
                      TextModelFixture(chunks: ["Draft\n[[PIPPA_TEXT_DO"]),
                      TextModelFixture(chunks: ["[[WA", "IT]]"]), TextModelFixture(chunks: [" \n"]),
                      TextModelFixture(availability: .unavailable), TextModelFixture(chunks: [String(repeating: "x", count: 8_001)])] {
            if try await QuickTextAction.answer(skillInstructions: "Shorten.", selectedText: "Text.", language: "en", model: model) != nil { return false }
        }
        return true
    }
    await checkAsync("Quick text: a stalled stream times out without accepting partial text") {
        try await QuickTextAction.answer(skillInstructions: "Shorten.", selectedText: "Text.", language: "en",
                                         model: TextModelFixture(chunks: ["Partial"], stalls: true), timeout: .milliseconds(20)) == nil
    }
    await checkAsync("Quick text: Stop cancels instead of producing a draft or a fallback") {
        let started = LockedBox(false)
        let task = Task {
            try await QuickTextAction.answer(skillInstructions: "Shorten.", selectedText: "Text.", language: "en",
                                             model: TextModelFixture(chunks: ["Partial"], stalls: true, started: started))
        }
        defer { task.cancel() }
        for _ in 0..<1_000 where !started.value { try await Task.sleep(for: .milliseconds(1)) }
        guard started.value else { return false }
        task.cancel()
        do { _ = try await task.value; return false }
        catch is CancellationError { return true }
        catch { return false }
    }
}
