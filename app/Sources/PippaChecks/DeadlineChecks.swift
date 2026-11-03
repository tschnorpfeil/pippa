import Foundation
import PippaCore

private actor CancellationReceipt {
    private var cancelled = false
    func mark() { cancelled = true }
    func value() -> Bool { cancelled }
}

func runDeadlineChecks() async {
    await checkAsync("Deadline: timeout cancels losing work") {
        let receipt = CancellationReceipt()
        let answer = await firstAnswer(within: 0.02, fallback: false) {
            do { try await Task.sleep(for: .seconds(30)) }
            catch { await receipt.mark() }
            return true
        }
        for _ in 0..<100 {
            if await receipt.value() { return !answer }
            try await Task.sleep(for: .milliseconds(2))
        }
        return false
    }
    await checkAsync("Deadline: caller cancellation returns fallback promptly") {
        let task = Task { await firstAnswer(within: 30, fallback: false) {
            try? await Task.sleep(for: .seconds(30))
            return true
        } }
        task.cancel()
        return await task.value == false
    }
}
