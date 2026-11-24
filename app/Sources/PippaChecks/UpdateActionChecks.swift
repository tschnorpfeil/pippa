import PippaCore

/// "Check for Updates …" after a silently downloaded update: install it instead of asking a stalled Sparkle.
func runUpdateActionChecks() {
    func decide(_ state: UpdateState, controller: Bool = true, canCheck: Bool = true, answering: Bool = false) -> UpdateCheckDecision {
        UpdateCheckDecision.decide(hasController: controller, state: state, canCheckForUpdates: canCheck, isAnswering: answering)
    }
    var ready = UpdateState()
    ready.readyToInstall(version: "1.0.6")

    check("Updates: no controller is unavailable, even with a waiting update") {
        decide(UpdateState(), controller: false) == .unavailable && decide(ready, controller: false) == .unavailable
    }
    check("Updates: a waiting update installs instead of checking, even while Sparkle is stalled") {
        decide(ready, canCheck: false) == .installReady(version: "1.0.6", needsConfirmWhileAnswering: false)
            && decide(ready) == .installReady(version: "1.0.6", needsConfirmWhileAnswering: false)
    }
    check("Updates: a waiting update asks first while Pippa answers") {
        decide(ready, canCheck: false, answering: true) == .installReady(version: "1.0.6", needsConfirmWhileAnswering: true)
    }
    check("Updates: free Sparkle without a waiting update checks now") {
        decide(UpdateState()) == .checkNow && decide(UpdateState(), answering: true) == .checkNow
    }
    check("Updates: a running cycle without a waiting update is busy, not a silent no-op") {
        var checking = UpdateState()
        checking.checkStarted()
        return decide(UpdateState(), canCheck: false) == .busy && decide(checking) == .busy && checking.isChecking
    }
    check("Updates: a ready update clears the checking flag") {
        var state = UpdateState()
        state.checkStarted()
        state.readyToInstall(version: "2.0")
        return !state.isChecking && !state.isInstalling && state.readyVersion == "2.0"
    }
    check("Updates: a finished or aborted cycle clears checking and keeps the waiting update") {
        var plain = UpdateState()
        plain.checkStarted()
        plain.cycleEnded()
        var waiting = ready
        waiting.checkStarted()
        waiting.cycleEnded()
        return plain == UpdateState() && decide(plain) == .checkNow
            && waiting.readyVersion == "1.0.6" && !waiting.isChecking
            && decide(waiting) == .installReady(version: "1.0.6", needsConfirmWhileAnswering: false)
    }
    check("Updates: a started install is busy, and waits again when the cycle ends without relaunch") {
        var installing = ready
        installing.installStarted()
        let busy = installing.isInstalling && decide(installing) == .busy
        installing.cycleEnded()
        return busy && !installing.isInstalling
            && decide(installing) == .installReady(version: "1.0.6", needsConfirmWhileAnswering: false)
    }
    check("Updates: starting an install without a waiting update changes nothing") {
        var state = UpdateState()
        state.installStarted()
        return state == UpdateState()
    }
}
