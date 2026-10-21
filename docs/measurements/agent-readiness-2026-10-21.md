# Pippa: execution reliability and local-model direction

Research date: 21 October 2026. Starting remote: `601583b6fc9d747cfa7e9893b9226dd4f30d46b3`.
Working branch: `codex/agent-reliability`. This is an engineering assessment, not a model benchmark or release approval.

## What changed upstream

The initial checkout was `release/0.2.1` at `af8327d`, with 103 commits on remote main and three release-specific commits locally. After fetching, work started on a new branch from remote main; the old release branch remains available. Relevant changes already on main include Pi 1.3.0, front-app reading when a question refers to it, Apple Foundation Models for folder classification, download completion fixes, and permission-flow fixes. These are now the baseline, not new work in this patch.

## Confirmed execution defects addressed

1. **Failed tool calls escaped the loop guard.** Pi validates tool names and arguments before `tool_call`; blocked calls also skip `tool_result`. Pippa depended on those hooks alone. Unknown tools, malformed arguments, and repeated attempts to read a PDF as raw bytes could therefore continue without the intended stop. Execution events now cover skipped hooks without counting normal calls twice. Equivalent argument objects use a stable identity; identical changes already in flight are blocked too.
2. **An aborted run could look finished.** Pippa already waited for `agent_settled` and handled prompts consumed by extensions correctly. It discarded the event's `aborted` flag, however. Cancellation between assistant messages can leave the last assistant's stop reason as `toolUse` or `stop`. The flag now reaches the app's stopped-answer handling.
3. **Closed Mail was a dead end.** Inbox search and new or captured-source drafts used the same access check as reading the selected message. When Mail was closed, they returned unavailable even with permission granted. These explicitly requested operations now prepare Mail in the background, with a bounded launch wait and the existing permission gate. Reading the selected message still needs a real selection.
4. **Invalid reader arguments could broaden a read.** A non-string photo query became an omitted query and could read recent photos. Readers now validate their own declared fields and types before permission checks or reads. Null and malformed argument envelopes fail; omitted optional fields remain supported. Schemas advertise the same strict contract.
5. **Stop could leave a native write running without an honest result.** Each request now captures its originating turn, with a locked dispatch lease checked after permission waits and at EventKit/Apple Events dispatch. Stop invalidates undispatched writes. The process endpoint is revoked and replaced before a later Pi process can work, so a delayed old request cannot borrow the next turn. Confirmed results remain confirmed; unconfirmed dispatched writes remain uncertain. Stable operation identifiers let late confirmations update the original answer, even after switching conversations. Read receipts, document ledgers and the front-app identity are also bound to the original turn.
6. **Recovery could lose useful state.** A Stop arriving while file changes were being journaled could discard their Undo receipt; the answer now retains it. A response ending at the model's length limit is explicitly incomplete, and an empty answer enters failure recovery instead of disappearing as a success.
7. **Useful actions were hidden.** Generic welcome content competed with selected content, and the three-suggestion cap also removed supported tools from the overflow menu. Contextual starters now lead when content is supplied, and the menu retains all applicable actions while two suggestions stay prominent.
8. **Uncertain native outcomes looked successful to the loop guard.** Pippa's MCP result can carry `done: false, state: unclear` without a transport error. The guard now treats this as uncertainty and blocks an identical same-turn mutation without claiming completion. Follow-up prompts receive bounded, persisted native receipts, so Pi's synthetic “Operation aborted” or “No result provided” history cannot be treated as proof that nothing changed.

These fixes address reproduced failure paths. They do not establish that every user report had the same cause.

## Follow-up: native tool admission and partial effects

The first implementation and evolution plan were committed and pushed on `codex/agent-reliability`; checkpoint `12dbc05` also incorporates remote main through `093ea7d`, including the source-fidelity and English usability-fixture updates.

**A missing MCP connector was a concrete cause of unavailable Mac actions.** Pippa starts Pi with `--no-extensions`. In the pinned Pi 1.3.0, that also disables the built-in MCP connector. Registering Pippa's server alone therefore did not make its tools available. A real Pi subprocess reproduced the missing-tool state.

Pippa now loads the pinned SDK's public MCP connector with an empty shared configuration and registers only its own endpoint. Before admitting a user prompt to a fresh Pi process, it confirms the extension command's ownership and requires a nonce-bound receipt proving all 11 native tools are active. Startup has bounded deadlines and cancellation cleanup. Missing tools produce an actionable localized failure. Direct native utilities remain independent; admission currently checks the full native inventory, not the subset needed by an individual task.

The real Pi fixture includes colliding and unrelated global/project MCP configurations. It confirms that these files remain unchanged, unrelated HTTP and stdio servers never start, and readiness sends no model request. This establishes discovery and isolation, not real macOS permission or application behavior.

**An error is not evidence that nothing changed.** Receipts now distinguish confirmed completion, a known block before execution, failure after an attempt, and an unconfirmed result. Missing, malformed or contradictory native replies remain unconfirmed, and identical mutations are blocked within that turn. Classification uses the full result before display truncation and accepts actual JSON booleans only.

Shell errors, timeouts and Stop now preserve available original-file copies and emit restoration records even when execution failed. Real Pi tests change a synthetic file before each failure and verify both the changed file and its original backup. This extends the existing bounded backup coverage; it does not provide transactional rollback for arbitrary shell effects or durable duplicate prevention across turns or app restarts.

The independent review also identified an existing automatic-replay hazard: after a permission error, granting access reran the entire shell command, including any earlier successful clauses. That replay is removed. The tool preserves the original failure, retains the grant for the current answer, and instructs the agent to inspect partial effects before issuing only the remaining work. A real sandbox test verifies one append, an unchanged denied destination, and a separate successful remaining write with its backup and no repeated permission question. This prevents the wrapper's automatic replay; it does not mechanically prove arbitrary model-generated follow-up commands safe.

The companion [Rakazo assessment](rakazo-assessment-2026-10-21.md) identifies useful memory, reusable-routine and evaluation patterns. Those are sequenced in the [evolution plan](../pippa-next-evolution-2026-10-21.md); neither source inspection nor a stored routine establishes measured self-improvement.

## Fast everyday actions

Two new bilingual text actions are available: **Fix Spelling** and **Make a Checklist**. Alongside **Make Shorter**, **Improve Text**, and **Summarize**, they can run on Apple's on-device model when the user explicitly chooses the action and supplies a small text selection.

The fast path is limited to 1,000 UTF-8 bytes, no attached files, and an available system model. Eligible buttons remain usable while the full model is being set up. Larger selections and agent work continue through Pi. A refusal, timeout, incomplete output or generation error falls through to the same Pi skill. Results are buffered until an explicit completion marker is present, because Apple's response-token limit can end generation normally without an error. Stop cancels the active quick task. The exact latest result is retained for follow-ups such as “save that”; older context remains bounded. These actions produce text to copy, not system reminders or sent messages.

Existing deterministic workflows remain valuable defaults: photos to PDF, image conversion and compression, calendar summaries, spreadsheet arithmetic and folder tidying. Their native execution and receipts should be reused when expanding the catalog.

Two additional code-based actions now use the existing results, password, cancellation and Undo paths:

- **Extract Text** exports PDF text and image OCR to a new `.txt`, with explicit page/source labels. Blank and unreadable pages are identified; a wholly blank source fails explicitly. Size, page and text limits reject the source rather than silently cutting the export short.
- **Remove Location** creates an upright PNG from pixels, preserving transparency while excluding location, camera and XMP metadata. The original remains intact. Multiframe images are rejected rather than silently flattened.

These are deterministic exports; OCR remains recognition that the user should check against the original. Neither workflow uses a general agent or a model download.

Location removal preserves the display color profile for fidelity. It removes the location/camera tags and XMP covered by the checks; it is not a general anonymization guarantee for arbitrary data embedded in color profiles.

Native follow-up evidence is captured when a message is sent. A later OS result updates its original UI receipt immediately and enters the following prompt. This is not cross-turn exactly-once execution: unresolved OS outcomes still require checking the actual app. A persistent idempotency ledger and a tested reconciliation interface remain separate work.

## Current projects worth following

| Project | Verified development | Implication for Pippa |
|---|---|---|
| [Pi 1.3.0](https://github.com/earendil-works/pi/releases/tag/v1.3.0) | Released 15 October; malformed final tool JSON is rejected instead of partially executed, resumed active tools are restored, internal versions are pinned. Earlier 1.2 MCP fixes also matter. | Keep the current pin and test the actual RPC/extension contract. More model prompting cannot repair a missing lifecycle event. |
| [Pi RPC contract](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md) | Prompt acknowledgement, intermediate `agent_end`, final `agent_settled`, and handled prompts are distinct. | Preserve settlement semantics through retries, continuation and cancellation. Protocol tests now cover these cases. |
| [Peekaboo 4.9.6](https://github.com/openclaw/Peekaboo/releases/tag/v4.9.6) | Released 20 October; recent work includes process identity, verified window operations and cancellation. | Borrow exact app/window identity, fresh snapshots and verified postconditions before adding general click/type automation. |
| [Peekaboo automation contract](https://github.com/openclaw/Peekaboo/blob/main/docs/automation.md) | Distinguishes failures before dispatch from partial or uncertain mutations. | A timed-out action must not automatically be repeated if it may already have changed the Mac. |
| [Peekaboo permissions](https://github.com/openclaw/Peekaboo/blob/main/docs/permissions.md) | Permissions can differ between GUI parent, CLI and Bridge host. | Diagnose the process that actually performs an operation, then show the corresponding repair action. |
| [Apple Foundation Models](https://developer.apple.com/foundation-models-framework/) | Current macOS 27-era direction includes Dynamic Profiles, provider integration, Vision capabilities, evaluations and the `fm` CLI. | Evaluate behind availability checks. Keep current macOS 15 support and macOS 26 conditional Apple-model support. |
| [Apple utilities](https://github.com/apple/foundation-models-utilities) | Open-source skill and context-management utilities. | Useful for future constrained native workflows; not a reason to introduce a second general agent loop today. |
| [MLX Swift LM 3.32.3](https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.32.3) | Foundation Models integration, guided generation and fixes around tools/cancellation/cache continuation. | A separate native-runtime evaluation candidate; changing engines and models together would obscure results. |
| [llama.cpp 0.7.0](https://github.com/ggml-org/llama.cpp/releases/tag/v0.7.0) | Released 15 October; cache/slot work and speculative decoding changes, including a new default server port. | Retain an explicit port and run transcript/cache compatibility tests before replacing Pippa's patched build. |
| [MacAgentBench](https://github.com/JetAstra/MacAgentBench) | 676 tasks across 25 apps, with programmatic outcome checks and intermediate checkpoints. | Build a small Pippa-specific task suite with real postconditions, rather than judging polished final prose. |
| [Hermes](https://github.com/NousResearch/hermes-agent) | Reusable skills and searchable session memory are central to its design. | Study workflow discovery and recovery. Treat “self-improving” as a product claim until measured. |

## Local-model recommendation

Keep **Qwen3.5-9B Q4** as the standard on Macs with at least 16 GB, with the existing **4B** choice for 8 GB. A larger model cannot fix missing tools, ignored cancellation or misleading success handling.

The attached quantization document proposes a useful controlled comparison:

| Candidate | Role | Evidence and limit |
|---|---|---|
| Existing Qwen3.5-9B Q4 | Product baseline | Keep its exact catalog artifact and product settings. |
| Existing Qwen3.8-27B UD-Q3_K_XL | Same-family control | Needed to distinguish a quantization improvement from simply moving from 9B to 27B. |
| [ISTA GSQ-RCO IQ3_S](https://huggingface.co/ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF) | Proposed 27B candidate | Model card lists about 11.8 GB of weights. “Task-lossless” refers to the publisher's benchmark results, not Pippa task completion or total Mac memory. |

The document's discipline is appropriate: fixed artifacts, 16K compatibility smoke before 32K, Q8 KV as baseline, synthetic tasks, identical 27B settings, measured time to correct completion, and explicit memory pressure. Its 90-run comparison is a proposed experiment; **no such inference runs were performed in this work**. External file hashes in the attachment are not a substitute for hashing downloaded weights. The default and the “More thorough” gate remain unchanged.

[Qwen's model card](https://huggingface.co/Qwen/Qwen3.8-27B) also distinguishes thinking enabled/disabled from `reasoning_effort` and preserved thinking history. Pippa's current Qwen compatibility route should not be described as full support for those newer controls without a transcript test.

### Underdog: a separate, useful experiment

[Conway's Underdog Saluki 27B 1.0](https://huggingface.co/ConwayResearch/Underdog-Saluki-27B-1.0) is a different concrete candidate: approximately 7.89 GB, mixed IQ2, based on Qwen3.8-27B, with stock llama.cpp support. The publisher recommends thinking off and temperature zero for direct tool calls. It reports 88/120 BFCL-derived tasks, 42/100 parallel tasks, and formatting failures in roughly one-fifth of parallel replies. Those are publisher results, not Pippa measurements. Evaluate serial tool reliability and German document fidelity before speed.

[Husky](https://husky.underdog.ai/) is separate: a model-specific Woof inference engine. Its September report uses one M5 Max and a small task set. The headline speedup is a peak editing case with Flash, not a general Mac-agent throughput guarantee. Warm prefix caches and edit-specific speculation are interesting; a public engine repository was not located in this research pass.

## Next product work, in priority order

1. **Broaden real Mac acceptance coverage.** The cancellation checks use synthetic integrations and the real Apple Events queue. Exercise signed-app permission prompts and observable Mail/EventKit outcomes on supported macOS versions before release, including cancellation while the OS is already applying a change.
2. **One useful recovery action per failure.** Distinguish permission missing, app unavailable, invalid input, unsupported capability and uncertain outcome. Offer “Allow access”, “Open Mail”, “Choose a file” or “Try again” only when appropriate. Preserve the original request and resume it after recovery.
3. **Continue the discoverable workflow catalog.** Next candidates include PDF page extraction, revealing a found file, recent-download search and clipboard cleanup. Add constrained Apple-model extraction of tasks/dates with evidence spans; let code validate dates and amounts before offering a reminder. Use Pi for ambiguous and multi-step tasks.
4. **Measure the complete experience.** For each workflow, test fresh install, denied permission, closed app, malformed tool arguments, tool timeout, Stop, retry, and undo. Record first useful visible feedback, task completion time, verified state and recovery cost. Include “claimed success without state change” as a release-blocking failure.
5. **Then compare models and runtimes.** Run the attached 9B/27B/GSQ matrix first. Evaluate Saluki separately with its prescribed tool settings. Consider newer llama.cpp or MLX only in independently pinned experiments.

The UI should lead with the task and result: a few relevant actions, progress from real tool events, an inspectable result, and an obvious next step. Model selection and implementation details belong in diagnostics or settings, not the everyday workflow.

## Initial implementation verification (`2e67358`)

- Exact pinned Pi 1.3.0: 61 runtime tests passed, none failed or skipped, including four real RPC loop/recovery scenarios and native uncertainty handling.
- PiRPCChecks: 7 protocol checks passed using a subprocess fixture, including cancellation between messages and successful reuse afterward.
- App debug build passed; English/German string validation passed.
- Full native suite: 743 checks passed, none failed, using the normal OCR engine and synthetic fixtures. Coverage includes permission/queue cancellation, late receipts, stale endpoint revocation, current-topic execution evidence, OCR exports and metadata removal. The sandbox denied Vision/ModelManager service access in an initial run; a CI-only fast-OCR override also altered a date. Normal unrestricted runs passed without weakening assertions.
- Synthetic app captures passed the conversation and Stop fixtures. Visual inspection at 400×700 confirmed all five selected-text actions are visible. Stop before the scheduled answer prevents engine invocation; Stop during change journaling retains one Undo receipt. Captures use invented data and do not establish signed-app TCC behavior.
- A separate synthetic live probe verified exact OCR text/amount/date and an Apple-model spelling correction with the completion marker. This establishes a working service path, not representative latency or quality across all five text actions.
- No production model download, real Mail delivery, release, deployment, or model-default change occurred.

Apple documents the response-limit behavior used by the new completion guard: [maximumResponseTokens](https://developer.apple.com/documentation/foundationmodels/generationoptions/maximumresponsetokens).

## Follow-up verification

- Full runtime suite against the exact Pi 1.3.0 payload: **75 passed, zero failures or skips**. Includes native discovery with the production tool allowlist and extensions, conflicting configuration, authentication failure, lost native replies, and real sandbox partial-effect/exit/timeout/Stop scenarios.
- PiRPCChecks: **30 passed**, including absent or malformed result envelopes, strict boolean evidence, full native replies before truncation, startup deadlines, cancellation and a fresh successful request after earlier admission failures.
- Full native suite with the normal OCR engine: **745 passed, zero failures**. The first follow-up run caught one older receipt assertion that still expected failure to mean no effect; it was updated to preserve the distinction between failed and blocked outcomes, and the complete suite passed again.
- Full app debug build, English/German string validation (1,404 keys), whitespace checks and local document links passed. The seven upstream Python usability-fixture tests also passed before the checkpoint push.
- Independent source review covered outcome handling and native-tool admission. Its additional finding about shell permission replay was fixed and covered by an actual partial-effect regression test.
- Signed-app TCC flows, live Mail/EventKit mutations, restart reconciliation, the proposed model matrix and observed-user acceptance remain unvalidated by this follow-up. No release or model-default change was made.
