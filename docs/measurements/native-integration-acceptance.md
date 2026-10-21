# Signed native integration acceptance

This probe exercises production reminder dispatch, EventKit adapters and journal reconciliation across real process boundaries. It runs only in an **instrumented, Developer-ID-signed development candidate**, built with `PIPPA_NATIVE_ACCEPTANCE`. Normal builds do not contain its entry point or implementation. This is not shipped-build UI, fresh macOS permission, Mail, account synchronization, model or Pi transport acceptance.

## Build and review

```sh
PIPPA_NATIVE_ACCEPTANCE=1 \
PIPPA_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' \
scripts/build-app.sh

python3 scripts/check-native-acceptance.py
```

The build uses `.build/native-acceptance-swift` and writes `dist/native-acceptance/Pippa.app`. It cannot use `PIPPA_SKIP_BUILD=1` or distribution mode. Its signed property list and executable explicitly identify the instrumentation; normal distribution verification rejects either marker. The instrumented entry point rejects missing or invalid probe arguments instead of starting normal app behavior or installation. Before/after source manifests record the commit, dirty state, patch hash including untracked sources, and application source hash. The runner rejects application changes during compilation.

Without `--run-native`, the runner only verifies the candidate signature and describes the fixed scenarios. Review the implementation and authorize the synthetic native changes before running:

```sh
python3 scripts/check-native-acceptance.py --run-native \
  --output "$PWD/.build/native-acceptance-NEW-RUN"
```

The output parent must exist and the run directory must be new. It is private to its owner. The runner launches the exact signed bundle through LaunchServices (`open -n -W`); directly executing its binary can attribute TCC access to the terminal or parent process. The candidate's ordinary settings, conversation store and execution journal are not opened. The fixture constructs its host with an isolated journal from the outset; it does not override `HOME` or start a listener. Existing Reminders permission is required. Missing or denied permission produces a blocked result without requesting access or resetting TCC.

## Fixed scenarios

1. Create one synthetic reminder through the real `tools/call` dispatcher, active write turn and app-owned request origin. Use a random title prefixed `PIPPA-NATIVE-ACCEPT-`, fixed synthetic notes, and no due date or alarm.
2. Exit the process. A new process reloads the journal and looks up the original UUID marker in its original native target. The identity and durable completion must agree.
3. Another process repeats the same request origin. It must return the original completion without another native write or journal revision.
4. Remove only the original unchanged synthetic item through the product's fingerprint/modification guard. Verify its exact marker is absent.
5. In a separate fixture, delegate to the real native save and terminate the process immediately after it returns, before journal completion. Persist synthetic identity evidence and the explicit interruption intent before termination. LaunchServices confirms app closure; its launcher status is **not** reported as the app's exit code or a kernel-observed termination signal.
6. A fresh process runs production reconciliation. Require the original native identity, completed state, a newer revision, `recovered == true`, and zero native writes. Repeat readback, deduplication and guarded cleanup.

Only the original target list is consulted for marker reconciliation; native results from unrelated reminders are not written to reports. The default list may synchronize through its configured account. This probe makes no offline or synchronization claim. It does not query personal mailboxes, invoke an external accessibility helper, grant permissions or alter privacy settings.

Each phase has a bounded deadline. A private launch token and app process-start record tie each phase to its process. On timeout, the runner only stops the app if its PID, exact executable/arguments/token and previously observed process start still match; unavailable ownership evidence fails without killing another app. The runner also stops its own `open` launcher. Any proven native save triggers a cleanup attempt even if later checks fail. Changed items are retained, and unavailable permissions or inconclusive cleanup remain failures with the evidence preserved. Initial absence from the original marker/list lookup is inconclusive because the item may have moved or its marker may have changed; cleanup fails closed. If the process fails before recording a returned native identity, do not assume that no native effect occurred; inspect the isolated journal before any retry.

## Evidence and remaining gates

`report.json` records the instrumented bundle hash/build, source provenance, actual OS and physical RAM, per-process identities and launch tokens, exact synthetic operation/native/target IDs, journal revisions and permission status. Its `nativeWrites` counter measures reminder creation calls through the writer; cleanup deletions are verified separately by guarded removal and absence. Raw personal record text and native error details are omitted. A successful guarded removal can be verified even if the interrupted journal never reached completion; this does not convert a failed recovery into a pass.

A passing report establishes signed native integration across process loss and restart on that host. It does **not** close ordinary shipped-app interaction, fresh-profile permission allow/deny, physical 8-/16-GB behavior, Mail reply identity, provider behavior or end-to-end agent success-rate gates. Keep those statuses explicit in release evidence.

## Recorded local attempt: 2026-10-21

The signed 0.3.13 (730) candidate passed signature, instrumentation and unchanged-source checks on macOS 27.0.1 with 24 GiB physical RAM. Direct binary launch reported `notDetermined` and stopped before constructing the journal or dispatching a write: zero native writes, no after-save proof, no permission request, and no cleanup needed. A subsequent LaunchServices probe of the **same signed bundle** reported existing granted access, saved exactly one synthetic reminder through dispatch/journaling, and removed that unchanged reminder in a fresh process with verified absence. The start method changes TCC attribution; the first result does not establish denial for the normally launched app.

The local evidence is `.build/native-acceptance-0.3.13-2026-10-21/`, including the original `report.json` and `completed/create.json`. This initial runner aggregates the blocked case as `fail`; the phase report records the precise `blocked`/`notDetermined` result. The runner now preserves blocked phase details directly in future aggregate reports.

The successful single-create/cleanup LaunchServices evidence is `.build/native-acceptance-0.3.13-launchservices-2026-10-21/report.json`. This initial probe does not by itself establish interruption recovery or same-request deduplication.

Candidate SHA-256: `3fa9e4ac86c9d11854442b337dd9ff725c86bea05e202f4931d69bdadc20eb9f`. The signed manifest records base commit `3cd432c0a095f5d7a31363561b94fbfa730d1a90`, a dirty worktree, patch SHA-256 `ff5bc1d22890a72b49294432fd002b264cae51777015aa032b031952ea2c55bc`, and matching before/after application-source SHA-256 `d9dc245a74a532176790dcf5ca6c139f2943a6eec9b30b35a839a246326a23c9`. This is the instrumented development candidate, not a released build.

## Full LaunchServices run: passed, 2026-10-21

The final signed instrumented **0.3.13 (731)** candidate passed both scenarios on **macOS 27.0.1, 24 GiB**, across **nine distinct app processes**. Exactly two synthetic reminders were created in this full run; both were removed using the original fingerprint/modification guards, with absence verified. Existing Reminders access was granted. No permission prompt or TCC reset occurred.

| Scenario | Observed result |
| --- | --- |
| Completed request, four processes | One native creation; fresh-process exact identity readback; same-request deduplication with zero additional saves and unchanged revision 3; guarded cleanup and verified absence. |
| After-save process loss, five processes | Signed after-save proof and interruption intent; LaunchServices observed app closure; fresh process required an unresolved journal before reconciliation; recovered completion at revision 3; readback and deduplication with zero additional saves; guarded cleanup and verified absence. |

This establishes real native integration across process loss and restart for this candidate. It does not establish the app's kernel termination signal: `open`'s exit code is not used as an app exit code. Ordinary shipped UI, fresh-profile permission decisions, physical 8-/16-GB devices, Mail and end-to-end agent/provider acceptance remain separate gates.

Evidence: `.build/native-acceptance-0.3.13-launchservices-full-2026-10-21/report.json`, with isolated per-phase reports, journals and logs beside it. Signature verification passed before and after the run. Missing and incomplete probe arguments both returned exit code 2 before normal startup. The focused runner suite passed **10/10**; the full Python suite passed **20/20**.

Final candidate SHA-256: `ba40146ab38c7725b4c8e3d0738ebfabddaad6fb4ff3c979503491f10d00c9ad`. Signed source provenance records base commit `b3ff1e4c32a0f6384d2de5aab7bbcbcac4ee4946`, a dirty worktree, and identical before/after application-source SHA-256 `7278f68d55f856334674000222347ad1f28d27772d756b480e9616f582491a87`. Whole-worktree patch SHA-256 values are `6fcd4120e32d0529a3c5432268a79d6ecaffd1cb0d358df2c78cc5e23ccbb4c1` before compilation and `6debf0cbbb07c578d65e398534e682a2c99ff55727e3407fa31c3eae8b2eb90b` afterward; application sources did not change during compilation.
