# Pippa 0.3.13 release acceptance

Assessment date: 21 October 2026. Release preparation is in progress. The prepared release's `commit.txt` and `validation.json` identify its exact source, build, package hashes, matching CI and update result. Earlier checks are identified by their own candidate; they are not silently carried forward as tests of the shipped binary.

## Release scope

This release focuses on inspecting uncertain reminders, repairing access from the conversation, conservative Mail result reporting, and consistent file/photo permission repair. It keeps the existing Pi core, local model defaults and native file tools. The broader file-preparation redesign, new linked letter workflow and six-person usability study remain later work; this release does not claim that the original 0.3.13 roadmap is complete.

The native reliability increment is merged as `04135a1` (PR #125). File/photo permission repair adds typed access evidence across native readers and the real Pi folder tool. Final source-matching CI, ordinary signed packaging and the real update installation are release gates, recorded in the published validation record.

## Evidence already established

- **Real reminder integration:** the signed instrumented 0.3.13 build 731 passed two scenarios across nine distinct app processes on macOS 27.0.1 with 24 GiB physical RAM. A completed request survived fresh-process readback and deduplication. A save followed by process loss was reconciled from an unresolved journal without a second save. Both unchanged synthetic reminders were removed with guarded cleanup and verified absence. Existing permission was granted; no permission prompt or TCC reset occurred. [Exact evidence and provenance](native-integration-acceptance.md#full-launchservices-run-passed-2026-10-21).
- **Evidence boundary:** that run used a separately instrumented candidate based on `b3ff1e4` plus a recorded patch. It does not certify shipped-build UI, fresh permission decisions, account synchronization, or the app's kernel termination signal. LaunchServices observed app closure; its launcher exit status was not treated as the app's signal status.
- **Mail safety checks:** automated checks cover bounded compose events, reply field verification after the save attempt and refusal to choose an original from an incomplete or malformed search. Native Mail compose/reply behavior remains unverified on this host. A previous UI automation attempt stalled without establishing a completion; this is not an established product failure.
- **Previous release:** 0.3.12 build 727 passed its signed/notarized package checks and a real Sparkle upgrade from 709. The preserved copied host at `dist/update-probe/host/Pippa.app` is build 727; the installed `/Applications/Pippa.app` is still build 722. Use the copied 727 host for the next update test. Earlier Calendar and reminder UI observations belong to build 722.

## Current-source local acceptance

- All 826 native checks passed on the current source.
- 94 runtime extension tests passed, including a real pinned Pi 1.3 process receiving an actual synthetic filesystem denial. That test uses a scripted provider and does not establish macOS TCC behavior or model quality.
- 42 Pi RPC checks passed, including permission evidence validation before display truncation and rejection of malformed or unrelated tool results.
- 14 focused native permission checks passed: contextual PhotoKit requests, partial photo results, cancellation, typed repair destinations, history compatibility, and real synthetic file/parent permission denials.
- English and German controller fixtures each passed 30 assertions. They use the actual conversation controller and repair button action with a synthetic URL opener, verify retained conversation/source and no automatic replay, and render all seven states at 400 points. German file and partial-photo captures were visually checked. These are not fresh operating-system permission prompts.
- Translation validation passed for 1,447 keys; all 20 release-script Python tests passed.

## Release gates

| Check | Required evidence |
| --- | --- |
| Final source and CI | Clean, frozen commit; main CI and macOS 15 workflow green for that exact commit; final native/RPC/runtime counts recorded from their logs. |
| File/photo access repair | Focused current-controller checks for contextual permission request, denied/restricted repair, retained conversation/source, cancellation and no automatic replay after merely opening Settings. |
| Ordinary package | Developer ID signature and Hardened Runtime; expected entitlements; no acceptance marker/code; pinned helpers and resources; ordinary signed-bundle runtime probe; mounted DMG contains the same signed app. |
| Distribution | Accepted notarization, stapled ticket, Gatekeeper acceptance, checksum-matching stable and versioned DMGs, and valid Sparkle signature/appcast metadata. |
| Real update | Copy of build 727 discovers, downloads and installs the prepared target through the loopback Sparkle probe. Its final build and code-signature hash must match the packaged app. Preserve the old proof and installed app. |
| Publication | Publish the matching versioned DMG, stable `Pippa.dmg`, appcast, checksums and validation record together; verify the public latest feed and downloadable bytes. |

The existing `scripts/release.sh` already performs packaging, notarization, distribution verification, appcast creation and Sparkle signing. It requires a clean commit, rejects a reused release folder and aborts if the source changes while building. Use its normal distribution path; the instrumented candidate cannot be published.

Known working configuration on this host: `Developer ID Application: Tobias Schnorpfeil (68DJF6VJKS)`, notary profile `pippa-notary`, and Sparkle Keychain account `ed25519`. The profile/account are existing names, not credentials. Pass them explicitly; they are not exported in the current shell. Cached build tools are under `.build/buildtools/bin/` and the source/helper cache is `.build/build-cache`.

## Reproducible update verification

After preparing the new release, preserve `dist/update-probe/` under a new name instead of deleting it. Its `events.log` is the prior 709 → 727 proof, and its `host/Pippa.app` is the intact 727 source for the next copy. Verify that source signature and version before proceeding.

Run `scripts/prepare-update-probe.sh` with that archived host and the new release directory, using `PIPPA_PROBE_AUTOMATIC=1` and the existing Developer ID identity. The script creates a fresh `dist/update-probe`, verifies and copies the old host, checks the release checksums, and rewrites only its private appcast to `127.0.0.1:18765`. Serve its `feed/` locally and launch its signed probe app through LaunchServices. Observe a bounded run; do not repeatedly relaunch a failed probe.

Require the ordered log events `build 727, target <build>`, `UPDATE FOUND`, `DOWNLOADED`, `INSTALLING`, then `UPDATE INSTALLED`. The final copied host must have the target version/build and the same code-signature hash as `dist/Pippa.app`. An `UPDATE INSTALLED` line alone is insufficient because a host already at the target exits immediately with that line. Keep the install log and final signature/hash checks with the validation record.

Sparkle stores check state in the host's preferences domain even when updating a copy. Preserve the existing preference file before the probe and restore only that saved test baseline afterward; do not overwrite concurrent user changes. The user's installed app is never the update target.

## Accepted limits and deferred evidence

Physical 8 GiB and 16 GiB Macs and a fresh macOS permission profile are unavailable. The user explicitly authorized publication with these limits documented. Hosted macOS 15 CI and injected memory policy tests do not substitute for those devices or fresh TCC allow/deny decisions. Model defaults are unchanged; no new low-memory performance claim is made.

Native Mail acceptance remains open and is documented as an unverified limit for this release. No personal mailbox/account enumeration, sending, account creation or permission reset is performed. A future test needs a dedicated synthetic local mailbox or test account with a known original Message-ID and locator, plus exact guarded draft cleanup. The current adapter may search other mailboxes when the original locator is missing, so an ad hoc fixture in a personal store is not an adequate isolated test. Keep the fail-closed changes, but do not advertise them as proven native Mail compatibility.

The signed reminder integration test closes the defined instrumented process-boundary cases; ordinary shipped-app interactions, native Calendar observations for this exact release, and end-to-end agent/provider success remain separate. No claim about product-wide success rate, user retention or an observed-user pilot follows from these finite checks.

Release notes: [0.3.13](../releases/0.3.13.md).
