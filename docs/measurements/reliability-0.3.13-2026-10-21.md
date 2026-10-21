# Pippa 0.3.13 native reliability checkpoint

This is an unreleased implementation checkpoint for the first priority in the [0.3.13 roadmap](../roadmap-0.3.13.md), not a claim that the whole roadmap or its release gates are complete.

## Changes

- A journaled, uncertain reminder exposes **Check status** and **Open Reminders**. The check reads the exact original operation and destination; it cannot request permission, repeat Pi or write a reminder. Missing, ambiguous or inaccessible evidence remains unconfirmed. A deleted conversation stays deleted; a newer confirmation cannot be overwritten by stale evidence. A new conversational reply may continue while the check completes.
- Denied native Calendar, Reminders and Mail writes expose **Open System Settings** for their typed integration. Opening Settings preserves the conversation and does not grant access or retry an operation. Completed, canceled, unrelated or uncertain receipts do not acquire that repair action.
- Permissions skipped in onboarding already have a contextual chat path. The existing host explains an undecided permission, requests it and continues the same operation after a grant. New regression cases verify grant ordering, same-intent deduplication, Later, denial, previous denial and Stop at both explanation and request boundaries. These cases use a synthetic permission adapter; no fresh TCC claim is made.
- New Mail compose events have explicit timeouts. Reply fields must read back after the save attempt before the existing saved-draft outcome can be reported. Fallback original-message search rejects incomplete results and malformed mailbox/message lists; it cannot silently drop candidates and claim uniqueness. A new compose window remains distinct from a saved reply draft. No message is sent and there is no automatic replay.
- A compile-time-only, signed [native integration harness](native-integration-acceptance.md) provides a reproducible reminder create/restart/readback/deduplication and after-save interruption/reconciliation sequence. It uses an isolated journal and fingerprint-guarded synthetic cleanup. Distribution checks reject its property-list or executable markers.

## Verification scope

The pinned Pi 1.3.0 runtime suite passed **90/90**, with no failures or skips. Four new scripted-provider cases prove that a useful independent read can finish after a denied, unavailable, confirmed or uncertain native result. The model receives the earlier outcome; a confirmed or uncertain write executes once despite an attempted duplicate. These are lifecycle fixtures, not model-reasoning benchmarks.

The English and German debug-app reminder fixtures passed **11/11 each** at 400 points. They exercise the real conversation controller through a second streaming turn, duplicate clicks and late status updates, and render idle, checking and denied-access states. Captures were visually inspected; German reminder buttons stack when necessary. The macOS 15 workflow runs these fixtures on every matching code change. Synthetic app captures do not establish native permission behavior or VoiceOver completion.

Focused reminder status/Settings checks passed **9/9**. Localization validation passed for **1,436 keys**. The packaging and acceptance runner checks passed **17/17**. Full native checks, ordinary production-build exclusion and signed integration results are recorded with the matching candidate before this checkpoint is considered validated.

## Gates that remain distinct

Fresh-profile permission allow/deny/revocation, exact shipped-build interaction, real Mail reply acceptance, physical 8-/16-GB hardware, account synchronization and observed-user usability are not established by synthetic checks or an instrumented reminder candidate. New generic permission continuation remains deferred. The expanded file preparation flow and contextual-entry priorities are still upcoming. A public 0.3.13 release also requires matching green CI, signed/notarized distribution verification and an update installation test.
