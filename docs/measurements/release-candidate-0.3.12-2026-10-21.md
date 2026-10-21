# Pippa 0.3.12 candidate: execution and first useful work

Assessment date: 21 October 2026. Branch: `codex/agent-reliability`. The exact source commit belongs to each packaged candidate's validation record.
This records implementation and verification of a release candidate. It does not establish product-wide success rates or user retention.

## Implemented

**Durable reminder creation.** `reminder_add` writes intent, originating conversation/request, immutable destination list, dispatch state and native identity into the existing `journal.sqlite`. The app supplies request identity; document text and model arguments cannot choose it. The native reminder carries a UUID marker for read-only reconciliation. A repeated completed request with the same normalized reminder arguments returns its prior completion, while separately submitted requests remain distinct intent. Unresolved work blocks additional reminders in that conversation. A missing or ambiguous marker never authorizes another save.

Journal transitions use short SQLite transactions and monotonic revisions. Pending and final receipts carry the same operation identity. Startup recovery and late callbacks update every matching receipt under the original conversation, so a newer retry cannot hide an older confirmed completion. Older recovery snapshots cannot replace newer state; deleted conversations remain deleted. Recovery never asks for Reminders permission or modifies the native app. Recovered identity does not prove unchanged content and does not gain Undo eligibility.

**Enforced drafting scope.** Draft/letter skills launch Pi with an immutable, app-selected scope: three local file readers plus eight native readers. Native writers remain registered but hidden. An independent tool-call guard rejects shell, writes, memory changes, web lookup and native mutations, and the app's native dispatch gate enforces the same restriction. Scope changes replace the Pi process. Before user work, read-only extension commands attest registration and active scope without calling a model.

Standard tasks retain broader file/network abilities. Generic shell app-control grants are removed, common app-automation utilities are refused and sandboxed Apple Events remain denied. Pi's direct RPC shell bypass is disabled. This is not a universal no-send confinement guarantee for arbitrary standard-mode code with approved network access. See [the documented action boundary](../development.md#architecture).

**Immediate native work.** Setup offers Photos/PDFs before model download consent. Native results expose Open, Save, Show in Finder and supported Undo. A failed Save retains the exact artifact and receipt. An explicit retry retains the ordered source selection and permits a deliberately repaired input; it never runs automatically. Result caveats persist with the specific artifact, including after reopening.

**Bounded optional PDF text recognition.** Creating or reducing PDFs shares a five-second budget for optional OCR, including across pages, with at most three outstanding Vision requests. Stop cancels waiting and requests Vision cancellation; late results cannot alter a finished artifact. When the deadline or worker limit prevents optional OCR, the result includes a localized note. The budget covers OCR waiting, not image decoding, PDF rendering or total task time. The caller still polls synchronously; this is not a complete asynchronous conversion redesign. Document-reading OCR retains its existing behavior.

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
- At source commit `d79aaee`, [macOS 26 CI](https://github.com/tschnorpfeil/pippa/actions/runs/39633804192) passed the 776 native checks, 37 RPC checks and 86 Pi extension tests. Its native checks preserve all five mixed-PDF extraction assertions and now verify visible scan/image content after serialization. Explicit source-document lifetimes were added in the fixture and PDF combiner; the earlier CI failure does not by itself establish why the image or OCR result was lost.

## Hardware, models and evidence limits

The available local host reports Apple M6 (`Mac18,5`), 24 GiB physical memory and macOS 27.0.1 (`26A434`). The English/German first-use observations above are from that host. Neither injected memory values in unit tests nor a hosted macOS VM establish behavior on physical 8 or 16 GiB Macs with ordinary background apps.

The release does not change model defaults or artifacts:

| Physical memory policy | Default | Pinned download | Context policy |
|---|---|---|---|
| 8 GiB | Qwen3.5 4B Q4_K_M, thinking off | 2,740,937,888 bytes | 16,384 |
| 16 GiB | Qwen3.5 9B Q4_K_M, medium thinking | 5,680,522,464 bytes | 16,384; four context checkpoints; RAM cache disabled |
| 24 GiB or more | Qwen3.5 9B Q4_K_M, medium thinking | 5,680,522,464 bytes | 32,768 |

The larger Qwen3.6 35B option remains hidden (`thoroughTested = false`). `scripts/check-default-models.py` passes for all table entries, including that developer-only row. The 776-check suite verifies tier selection, Intel refusal, missing-pin refusal, previous-model fallback, preserved old files, explicit download consent and no-model native tools. Those are policy and synthetic lifecycle checks, not inference quality or physical-memory measurements.

A focused real-model probe used the already cached, SHA256-verified 4B artifact, Pi 1.3.0, the packaged llama-server and an isolated home. Its tools could read only the exact generated fixture; it had no native app integration or network tool. No model was downloaded. The initial 3,331-character German attachment produced invented facts without a reader call; post-answer host snapshots did not establish that Pi had seen the source.

The attached-source correction now records exact pre-generation text and successful reader results. Clearly requested plain UTF-8 text can be supplied within one 8,192-byte turn budget; the inline opt-out is preserved. Required sources without evidence replace the answer with a code-produced recovery, including buffered stopped text. Confirmed actions and Undo remain separate, and no turn is replayed. A bounded per-session cache re-injects prior text only when regular-file metadata still matches; it is neither durable memory nor a content hash. Content-intent detection is conservative, and this does not establish correctness of every answer or an arbitrary typed-path request without attached context.

The exact German long-attachment retest passed: **LINDE-9361, EUR 47.30, 6 November 2026**, in **3.898 seconds** after model readiness. The prompt exposed 3,412 UTF-8 bytes; no additional reader was needed, the source was unchanged, and review found no missing evidence. Local report: `.build/release-model-smoke-Ht83tT/report.json`. Focused source regressions passed **21/21**, existing R6 checks passed **21/21** outside the sandbox, and the full app compiled. A sandbox-only R6 run could not reproduce short-PDF text extraction; the unrestricted synthetic run passed unchanged. This restricted-reader probe is not a full-app success-rate measurement or physical 8 GiB performance evidence.

Packaging is performed from the clean commit containing this assessment. `scripts/release.sh` verifies the signed bundle, notarized DMG, update signature and Gatekeeper result, and records the exact source commit and asset hashes under `dist/releases/<tag>/`. The same four native-readiness scenarios can run against the packaged Node, Pi and extension files using the command in [development checks](../development.md#checks). Package validation establishes the shipped runtime path, not the live TCC acceptance gates below.

## Remaining release acceptance

- Exercise the Developer-ID-signed app's real macOS permission dialogs and observed Mail/EventKit effects with dedicated test data/accounts. Synthetic writers cannot establish TCC behavior or account synchronization.
- Verify native first use on macOS 15 without Apple Intelligence, and advertised memory tiers; this host runs macOS 27.0.1.
- The reproduced attached-source grounding failure is corrected and locally verified as above. Final CI must include the source-exposure regressions; this evidence does not support a universal factual-accuracy claim.
- Any source changes after candidate build 722 require fresh matching CI and package verification; its earlier signature/notarization cannot validate a later binary.

## Later product and claim gates

- The planned 450-run held-out model/hardware/language matrix and observed-user pilot gate the staged hero-workflow success and retention claims in the evolution plan. They are separate from this release's compatibility and known-defect checks; this assessment makes no such success or retention claim.
- Broader native recovery, safe cross-route permission resume, reusable routines and editable scoped memory remain later roadmap work. Recovery in this candidate covers `reminder_add`; an unresolved absence can remain blocked, and explicit past-date retries conservatively fail validation while preserving the original completion record.

Release notes: [0.3.12](../releases/0.3.12.md). Sequence and product gates: [evolution plan](../pippa-next-evolution-2026-10-21.md).
