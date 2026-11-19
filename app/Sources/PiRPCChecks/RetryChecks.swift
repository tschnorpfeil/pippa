import Foundation
import PiRPC

/// What the fake Pi sends when the provider answers "429 Too Many Requests" (Pi 1.5 docs json.md, agent-session.js):
/// the failed assistant message, `auto_retry_start` before each wait and `auto_retry_end` once the tries end.
func emitRetryFixture(_ name: String) {
    let limit = "429 Too Many Requests: rate limit exceeded"
    func failed() {
        emit(["type": "message_end", "message": ["role": "assistant", "content": [], "stopReason": "error", "errorMessage": limit]])
    }
    func scheduled(_ attempt: Int, _ delay: Int) {
        emit(["type": "auto_retry_start", "attempt": attempt, "maxAttempts": 4, "delayMs": delay, "errorMessage": limit])
    }
    switch name {
    case "retry-recovered":
        failed(); scheduled(1, 15_000)
        assistant("Done", stop: "stop")
        emit(["type": "auto_retry_end", "success": true, "attempt": 1])
        emit(["type": "agent_settled", "aborted": false])
    case "retry-exhausted":
        failed(); scheduled(1, 15_000); failed(); scheduled(2, 30_000); failed()
        emit(["type": "auto_retry_end", "success": false, "attempt": 2, "finalError": limit])
        emit(["type": "agent_settled", "aborted": false])
    default:
        // Waits until Stop: `abort_retry`, then `abort`.
        failed(); scheduled(1, 60_000)
    }
}

@MainActor func runRetryChecks(_ client: PiRPCClient) async throws {
    let limit = "429 Too Many Requests: rate limit exceeded"
    func collect(_ prompt: String) async throws -> [PiRPCEvent] {
        var events: [PiRPCEvent] = []
        for try await event in try await client.prompt(prompt) { events.append(event) }
        return events
    }
    let recovered = try await collect("retry-recovered")
    check("A wait before Pi tries again reaches the app with attempt, attempts and delay, and its successful end",
          recovered == [
              .assistantEnded(text: "", stopReason: "error", error: limit),
              .retryScheduled(attempt: 1, maxAttempts: 4, delayMs: 15_000, error: limit),
              .textDelta("Done"), .assistantEnded(text: "Done", stopReason: "stop", error: nil),
              .retryEnded(success: true, attempt: 1, finalError: nil), .settled(aborted: false)
          ])
    let exhausted = try await collect("retry-exhausted")
    check("When the tries run out, the app gets each wait and the last error",
          exhausted.filter { if case .retryScheduled = $0 { true } else { false } }
              == [.retryScheduled(attempt: 1, maxAttempts: 4, delayMs: 15_000, error: limit),
                  .retryScheduled(attempt: 2, maxAttempts: 4, delayMs: 30_000, error: limit)]
          && exhausted.suffix(2) == [.retryEnded(success: false, attempt: 2, finalError: limit), .settled(aborted: false)])

    var stopped: [PiRPCEvent] = []
    for try await event in try await client.prompt("retry-wait") {
        stopped.append(event)
        if case .retryScheduled = event { try await client.abort() }
    }
    let count = try await client.command(["type": "fixture_abort_retry_count"])
    let sent = try count.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Int] }?["count"]
    check("Stop during the wait sends abort_retry, ends the wait and settles the answer as stopped",
          sent == 1 && stopped.contains(.retryEnded(success: false, attempt: 1, finalError: "Retry cancelled"))
          && stopped.last == .settled(aborted: true))
    let after = try await collect("next-prompt")
    check("A stopped wait releases the client for the next question",
          after.last == .settled(aborted: false))
}
