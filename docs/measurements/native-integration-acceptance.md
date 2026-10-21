# Signed native integration acceptance

This probe exercises production reminder dispatch, EventKit adapters and journal reconciliation across real process boundaries. It runs only in an **instrumented, Developer-ID-signed development candidate**, built with `PIPPA_NATIVE_ACCEPTANCE`. Normal builds do not contain its entry point or implementation. This is not shipped-build UI, fresh macOS permission, Mail, account synchronization, model or Pi transport acceptance.

## Build and review

```sh
PIPPA_NATIVE_ACCEPTANCE=1 \
PIPPA_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)' \
scripts/build-app.sh

python3 scripts/check-native-acceptance.py
```

The build uses `.build/native-acceptance-swift` and writes `dist/native-acceptance/Pippa.app`. It cannot use `PIPPA_SKIP_BUILD=1` or distribution mode. Its signed property list and executable explicitly identify the instrumentation; normal distribution verification rejects either marker. Before/after source manifests record the commit, dirty state, patch hash including untracked sources, and application source hash. The runner rejects application changes during compilation.

Without `--run-native`, the runner only verifies the candidate signature and describes the fixed scenarios. Review the implementation and authorize the synthetic native changes before running:

```sh
python3 scripts/check-native-acceptance.py --run-native \
  --output "$PWD/.build/native-acceptance-NEW-RUN"
```

The output parent must exist and the run directory must be new. It is private to its owner. The candidate's ordinary settings, conversation store and execution journal are not opened. The fixture constructs its host with an isolated journal from the outset; it does not override `HOME` or start a listener. Existing Reminders permission is required. Missing or denied permission produces a blocked result without requesting access or resetting TCC.

## Fixed scenarios

1. Create one synthetic reminder through the real `tools/call` dispatcher, active write turn and app-owned request origin. Use a random title prefixed `PIPPA-NATIVE-ACCEPT-`, fixed synthetic notes, and no due date or alarm.
2. Exit the process. A new process reloads the journal and looks up the original UUID marker in its original native target. The identity and durable completion must agree.
3. Another process repeats the same request origin. It must return the original completion without another native write or journal revision.
4. Remove only the original unchanged synthetic item through the product's fingerprint/modification guard. Verify its exact marker is absent.
5. In a separate fixture, delegate to the real native save and terminate the process immediately after it returns, before journal completion. Persist only synthetic identity evidence before interruption.
6. A fresh process runs production reconciliation. Require the original native identity, completed state, a newer revision, `recovered == true`, and zero native writes. Repeat readback, deduplication and guarded cleanup.

Only the original target list is consulted for marker reconciliation; native results from unrelated reminders are not written to reports. The default list may synchronize through its configured account. This probe makes no offline or synchronization claim. It does not query personal mailboxes, invoke an external accessibility helper, grant permissions or alter privacy settings.

Each phase has a bounded deadline. The runner stops only its own process group on timeout. Any proven native save triggers a cleanup attempt even if later checks fail. Changed items are retained, and unavailable permissions or inconclusive cleanup remain failures with the evidence preserved. If the process fails before recording a returned native identity, do not assume that no native effect occurred; inspect the isolated journal before any retry.

## Evidence and remaining gates

`report.json` records the instrumented bundle hash/build, source provenance, actual OS and physical RAM, per-process identities, exact synthetic operation/native/target IDs, journal revisions, permission status and write counts. Raw personal record text and native error details are omitted. A successful cleanup can be verified even if the interrupted journal never reached completion; this does not convert a failed recovery into a pass.

A passing report establishes signed native integration across process loss and restart on that host. It does **not** close ordinary shipped-app interaction, fresh-profile permission allow/deny, physical 8-/16-GB behavior, Mail reply identity, provider behavior or end-to-end agent success-rate gates. Keep those statuses explicit in release evidence.
