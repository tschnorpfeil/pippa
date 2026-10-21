# Pippa 0.3.12 candidate: execution and first useful work

Assessment date: 21 October 2026. Branch: `codex/agent-reliability`, following pushed checkpoint `9600c53`.
This records implementation and verification of a release candidate. It does not establish product-wide success rates or user retention.

## Implemented

**Durable reminder creation.** `reminder_add` writes intent, originating conversation/request, immutable destination list, dispatch state and native identity into the existing `journal.sqlite`. The app supplies request identity; document text and model arguments cannot choose it. The native reminder carries a UUID marker for read-only reconciliation. A repeated completed request returns its prior completion, while separately submitted requests remain distinct intent. Unresolved work blocks additional reminders in that conversation. A missing or ambiguous marker never authorizes another save.

Journal transitions use short SQLite transactions and monotonic revisions. Pending and final receipts carry the same operation identity. Startup recovery and late callbacks update every matching receipt under the original conversation, so a newer retry cannot hide an older confirmed completion. Older recovery snapshots cannot replace newer state; deleted conversations remain deleted. Recovery never asks for Reminders permission or modifies the native app. Recovered identity does not prove unchanged content and does not gain Undo eligibility.

**Enforced drafting scope.** Draft/letter skills launch Pi with an immutable, app-selected scope: three local file readers plus eight native readers. Native writers remain registered but hidden. An independent tool-call guard rejects shell, writes, memory changes, web lookup and native mutations, and the app's native dispatch gate enforces the same restriction. Scope changes replace the Pi process. Before user work, read-only extension commands attest registration and active scope without calling a model.

Standard tasks retain broader file/network abilities. Generic shell app-control grants are removed, common app-automation utilities are refused and sandboxed Apple Events remain denied. Pi's direct RPC shell bypass is disabled. This is not a universal no-send confinement guarantee for arbitrary standard-mode code with approved network access. See [the documented action boundary](../development.md#architecture).

**Immediate native work.** Setup offers Photos/PDFs before model download consent. Native results expose Open, Save, Show in Finder and supported Undo. A failed Save retains the exact artifact and receipt. An explicit retry retains the ordered source selection and permits a deliberately repaired input; it never runs automatically. Result caveats persist with the specific artifact, including after reopening.

**Bounded optional PDF text recognition.** Creating or reducing PDFs shares a five-second budget for optional OCR, including across pages, with at most three outstanding Vision requests. Stop cancels waiting and requests Vision cancellation; late results cannot alter a finished artifact. A skipped text layer produces an explicit localized note. The budget covers OCR waiting, not image decoding, PDF rendering or total task time. The caller still polls synchronously; this is not a complete asynchronous conversion redesign. Document-reading OCR retains its existing behavior.

**Source-aware conversational retry.** Try Again retains the original native intent, chosen skill and adapter. It revalidates regular-file metadata, selection and focus. Changed, unreadable, folder, symlink or live-app sources require a fresh request. Metadata fingerprints do not prove identity against deliberately preserved file timestamps. Completed partial work remains protected by native operation evidence.

## Verification

- Full native suite with normal OCR: **776 passed**, zero failures. Includes six history/recovery checks, three source-retry checks, sixteen durable-reminder cases and the existing native file, Undo, permission and cancellation coverage.
- Full runtime suite: **86 passed**, zero failures or skips, against exact Pi 1.3.0. Includes hostile draft attempts, deliberately widened inventory, direct RPC shell refusal and real sandbox app-control attempts.
- Swift RPC suite: **37 passed**, including immutable scope, registered/active native inventory, command ownership, deadlines and cancellation.
- Sixteen synthetic reminder scenarios cover permission waits, Stop before/after dispatch, restart, lost replies, failed dispatch/completion commits, stable IDs, revisions, multiple journal connections, normalized arguments and conservative date validation.
- Native first-use app fixture: **24/24 English and 24/24 German** on macOS 27.0.1. A real external accessibility client exposed all result actions. Final result/recovery captures fit a 700-point workspace; Open/Save and Finder/Undo use two compact rows.
- Two synthetic photos became a usable two-page PDF in **5.07 seconds English / 5.06 seconds German** without a model. The pre-fix English run exceeded its 30-second safety limit; a German pre-fix run took approximately 27 seconds. These are small synthetic observations on one Mac, not representative p50/p95 or a macOS 15 benchmark.
- Real conversation-controller retry fixture: **9/9**, including persisted intent, retained draft skill, a separately submitted identical request, changed file and unverified live-app context.
- Full debug app build, 1,425-key bilingual string validation, ten Python release/fixture checks and whitespace checks passed. Local source and outcome review findings were fixed before packaging.

Packaging is performed from the clean commit containing this assessment. `scripts/release.sh` verifies the signed bundle, notarized DMG, update signature and Gatekeeper result, and records the exact source commit and asset hashes under `dist/releases/<tag>/`. The same four native-readiness scenarios can run against the packaged Node, Pi and extension files using the command in [development checks](../development.md#checks). Package validation establishes the shipped runtime path, not the live TCC acceptance gates below.

## Remaining acceptance gates

- Exercise the Developer-ID-signed app's real macOS permission dialogs and observed Mail/EventKit effects with dedicated test data/accounts. Synthetic writers cannot establish TCC behavior or account synchronization.
- Verify native first use on macOS 15 without Apple Intelligence, and advertised memory tiers; this host runs macOS 27.0.1.
- Run the planned held-out model/hardware/language matrix and observed-user pilot before claiming task success or retention targets. No model artifacts or defaults changed here.
- Broader native recovery, safe cross-route permission resume, reusable routines and editable scoped memory remain later roadmap work. Recovery in this candidate covers `reminder_add`; an unresolved absence can remain blocked, and explicit past-date retries conservatively fail validation while preserving the original completion record.

Release notes: [0.3.12](../releases/0.3.12.md). Sequence and product gates: [evolution plan](../pippa-next-evolution-2026-10-21.md).
