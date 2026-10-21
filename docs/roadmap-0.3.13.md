# Pippa 0.3.13: finish everyday work with less effort

Release plan · 21 October 2026 · **Proposed work, not released functionality**

**The next release should make one everyday job excellent: turn photos and PDFs into a file ready to send, while making existing Mac actions easier to recover and inspect.** Judge success by the usable result and the effort required to get it. Keep three priorities; complete their gates before widening the scope.

### Implementation checkpoint: native reliability first

The first 0.3.13 change is an explicit **Check status** action for an unresolved, journaled reminder and **Open Reminders** for inspection. Status checking only reads native state; it does not repeat the request, ask for permission or create a reminder. It stays attached to the original conversation through navigation and concurrent replies. Missing or ambiguous evidence stays unconfirmed.

Skipping onboarding permissions does not disable contextual access requests: the existing chat tools explain and request an undecided permission when needed, then continue the same authorized operation after a grant. A previously denied Calendar, Reminders or Mail write now offers **Open System Settings** on its receipt while keeping the conversation open. This opens the relevant privacy pane only; it does not repeat the task or treat a Settings visit as a grant.

Mail hardening bounds new-compose Apple Events, verifies reply fields after the save attempt and refuses to choose an original from an incomplete search. A new compose window remains distinct from a saved reply draft. Native Mail acceptance is still required before advertising these fixes as verified behavior.

The accompanying signed, instrumented reminder harness exercises real native saves across process exit, after-save interruption, reconciliation, deduplication and guarded cleanup. Its evidence is deliberately separate from exact shipped-build UI acceptance. New permission-resume behavior is deferred until a fresh-profile test can be obtained; the file preparation and contextual-entry priorities below remain upcoming work.

## Starting point: 0.3.12 is released

[Pippa 0.3.12, build 727](https://github.com/tschnorpfeil/pippa/releases/tag/v0.3.12-727), from source `3dcb738e26d1257ad56eb9114b9583c9696e05d3`, already includes native-tool admission, durable reminder recovery, restricted drafting, source-aware retry, attached-source grounding checks and Photos/PDF actions before model setup. Reuse these foundations rather than introducing another agent loop.

The [published validation record](https://github.com/tschnorpfeil/pippa/releases/download/v0.3.12-727/validation.json) records 797 native checks, 37 RPC checks, 24/24 first-use checks in each of English and German on macOS 15, accepted notarization and a real Sparkle installation from build 709 to 727. Calendar and reminder acceptance used signed build 722 on a 24 GB Mac. Those observations must not be relabeled as final-build native acceptance.

Physical 8 GB and 16 GB Macs, a fresh permission profile, manual Mail draft acceptance and real app restart/readback remain unverified. Mail UI automation timed out; that is not an established product failure. These accepted 0.3.12 limits remain visible until actual evidence closes them. Automated tests do not establish everyday success rates or repeat use.

## 1. Make existing Mac actions recoverable and inspectable

**User flow:** “Remind me tomorrow at 9 to call the dentist.” If permission is missing, Pippa explains the one needed access, keeps the request and destination, and offers a single continuation after permission repair. The final result names the reminder and its date. If dispatch may already have happened, Pippa verifies the earlier operation before offering another attempt.

- Extend the existing reminder journal and request identity into the permission-repair experience. Retain the original date interpretation, source and list. Revalidate them after returning from Settings; request a new decision only if a material detail changed.
- Show blocked, uncertain and confirmed outcomes consistently in the conversation. An uncertain result gets an inspection/recheck action. A confirmed result exposes the exact native item where supported; otherwise name the app, list and item precisely. Offer Undo only when the existing reversal checks allow it.
- Close the remaining signed-app acceptance gaps for reminders, Calendar and Mail using synthetic items and a dedicated account/profile. For Mail, distinguish a saved draft, an open compose window and an unconfirmed text insertion. No send action is part of this release.
- Exercise Pi's response to unavailable tools, denied access and a failed first approach. Preserve completed effects and choose only an alternative within the original request and authority; avoid repeated failing calls or a generic “can't do that.”

**Gate:** on the exact release candidate, verify grant, denial, revocation, Stop before/after dispatch, lost reply, app restart, changed destination and changed source. The expected native item is independently observed; there is no false completion or duplicate in the defined cases. Missing or ambiguous readback remains uncertain. A new permission-resume claim requires a real fresh-profile test; if that cannot be obtained, defer that new behavior and document the remaining limit. Mail and Calendar fixes must pass their own native acceptance before being advertised.

**Scope boundary:** durable recovery remains focused on `reminder_add`. Do not promise automatic recovery for every Calendar, Mail or shell operation. A confirmed local item does not prove account synchronization or remote delivery.

## 2. Complete “make these files ready to send”

**User flow:** drop photos or PDFs → choose Combine or Make smaller → see the input order and a compact output preview → receive a named, openable file with its actual size. Open, Save, Show in Finder and supported Undo remain available. The original files remain intact.

- Connect existing native tools into one short preparation flow. Support input ordering for combination; leave a full PDF page editor for later. Keep the ordinary path to one action after choosing the files.
- Show a size goal only when reducing a PDF. Try a bounded set of quality settings, report the achieved size, and explain when the requested size cannot be met without further quality loss. Let the person inspect the output before choosing a lower-quality result.
- Verify the output can be reopened, has the expected page count/order and retains visible content. Keep scanned pages visible even when OCR is unavailable. Optional OCR failure should produce a useful file with an honest note when the transformation itself succeeded.
- Preserve the result and chosen inputs after a failed Save or a canceled destination picker. A changed or unreadable input produces one specific repair; a retry does not overwrite another completed result.

**Gate:** freeze 30 synthetic file cases before tuning, split across English and German UI. Cover mixed scanned/text PDFs, rotations, large images, duplicate names, unreadable inputs, an unreachable size goal, Stop and failed Save. All supported cases must produce a verified result or the specified safe failure, without losing the originals. Check keyboard and VoiceOver completion on macOS 15 without Apple Intelligence as well as the newer supported test OS. Report actual hardware and limits with the results.

**Why first:** this job works without a model download, has an outcome a person can inspect immediately and avoids relying on language generation for exact file operations. Letter understanding and reminder creation remain available, but their complete linked workflow is the next increment after this one passes.

## 3. Make entry, context and the next action obvious

**User flow:** invoke Pippa with selected text or drop files → see the source → choose one of at most three relevant actions → use the result. “Make it shorter” operates on the current result; a new frontmost window must not silently replace the original source.

- Reuse the existing entry points and show contextual choices, rather than adding another dashboard or setup step. Keep the source and selected action visible through permission waits, cancellation and retry.
- Use the same result language across native file actions, quick text and Pi: what completed, what remains, and the one useful next action. Keep low-level tool names and model routing out of ordinary flows.
- Make existing small-text actions easier to discover: correct spelling, shorten, improve, summarize and make a checklist. Preserve their bounded Apple-model path, complete-output checks and Stop behavior. When it is unavailable, retain the input and offer the existing local-AI route or setup at the point it is needed.
- Validate natural follow-ups on held-out phrasings and mixed supported tasks. Reuse verified context and results; ask only for a missing detail that changes the outcome. Keep insertion tied to a verified destination, with Copy as the clear fallback.

**Gate:** observe at least six people unfamiliar with Pippa completing their own file task or text action. Record first useful result, unnecessary questions, wrong context, unclear status and abandoned attempts. Target at least five unaided completions within five minutes after app open; count setup failures and abandonments. This small usability gate is for finding friction, not an adoption or success-rate claim. Keep the larger cohort in the [evolution plan](pippa-next-evolution-2026-10-21.md#8-measure-usefulness-and-trust) for broader promotion.

## Execution routes and performance targets

| Work | Route | Required fallback or verification |
|---|---|---|
| Combine/reduce PDFs, file identity, output size, result delivery | Native code | Verify output; bound quality attempts; preserve inputs and artifacts |
| Reminder creation and reconciliation | Typed native adapter plus durable journal | Preserve uncertainty; never replay merely because a lookup found nothing |
| Five existing small-text transformations | Apple Foundation Models when available, within the existing 1,000-byte selection limit | Accept complete output only; retain the source on failure or Stop |
| Open-ended requests, longer text and supported multi-step work | Existing pinned Pi core and local model | Read needed sources, validate tool results, revise a failed approach within scope |

Do not add a second planner, silently send content online or change the default models in 0.3.13. Apple Foundation Models availability is checked at runtime and currently requires macOS 26 or later; native file actions must continue to work on macOS 15 without it. A language model may propose a date or fact, but code and source evidence must establish what is safe to act on.

These are **targets to measure**, not performance claims:

- Visible acknowledgement within 200 ms for the measured entry/action paths.
- Native conversion p95 within five seconds for a frozen two-photo fixture, each image at most 6 megapixels. Measure the full operation including optional OCR, and report its contribution, image formats and hardware; larger inputs get separate results.
- Warm Apple-model text transformations p95 within five seconds for the eligible short-text fixture set. Report cold runs, fallback frequency and incomplete outputs separately; do not hide failures by dropping them from the denominator.
- For Pi tasks, first establish cold/warm time to a correct usable result, unnecessary tool calls and user interventions. Optimize those measurements before setting a credible numerical budget.

Physical 8/16 GB testing remains a priority for recruitment, not a result we can simulate into existence. Until devices are available, retain the model policy and publish the exact tested matrix. Do not advertise improved low-memory performance based on a higher-memory Mac or hosted CI.

## Delivery order and explicit deferrals

Run one core track (priority 1) and one experience track (priorities 2 then 3), with an independent acceptance reviewer. Freeze fixtures and the signed-app acceptance script first. Ship the file preparation flow before broadening the native recovery surface. Documentation and website updates can proceed in parallel, describing only available behavior and linking clearly to this proposed work.

Release only with green matching CI, signed/notarized package checks, an update installation test, the new feature gates above and a precise validation record. Any untested scope stays explicit. If a feature misses its gate, fix or omit that feature; do not mark the entire roadmap complete because unit tests passed.

Defer the complete letter → sourced facts → requested reminder/reply workflow, scheduling-email automation, Calendar/Mail crash recovery, new integrations, general GUI control, a new voice stack, model/quantization changes and a task-library redesign. After 0.3.13, prioritize the letter workflow using observed demand and the same outcome contract.

User-controlled learning follows demonstrated repeat use: propose saving an explicit correction such as a preferred list or reply tone, expose its scope and provide edit/forget controls. No silent memory, self-modifying production agent, background monitoring or autonomous execution is introduced by this plan. Improve problem solving now through held-out task cases, bounded repair and verified outcomes; add personal preferences when their benefit can be measured.
