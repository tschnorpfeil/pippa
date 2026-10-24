# K2/oMLX versus Pippa Qwen: measurement protocol

Requested comparison: the installed K2 Horizon 7B MLX model at low and medium effort versus Pippa's current Qwen3.5 9B Q4_K_M setup, on this Mac.

- Apple M6, 24 GiB unified memory, macOS 27.0.1; a working desktop with existing swap use. No other person's apps or inference requests are terminated.
- Pi 1.4.0, the checkout's pinned version, for every arm. Same current Pippa prompts, file tools, policy, assist, memory/context extensions and skills. No personal memories or context files.
- Ten existing `model-compare/tasks.mjs` tasks, repeated three times per arm. Round order: low/medium/Qwen, medium/Qwen/low, Qwen/low/medium.
- Existing 20-document synthetic PDF corpus, real Spotlight file search, deterministic document/mail/calendar/reminder mocks. The current web tool names and declarations use the existing saved web pages; no live search variability or personal app effects.
- K2 uses the installed oMLX 0.7.0 endpoint and installed roughly 5 GB four-bit conversion. Qwen uses the pinned llama.cpp b11503 build, 32K context, one slot, Q8 KV, and Pippa's sampling: temperature 0.6, top-p 0.95, top-k 20, min-p 0. K2 keeps its existing server sampling (temperature 0.6, top-p 0.95).
- Every model request has a 4,096 output-token budget, matching Pippa's Qwen configuration. This is lower than the separate terminal K2 configuration's 8,192. The per-task timeout is 180 seconds; truncated and timed-out work counts against quality.
- Request payloads verify actual `chat_template_kwargs.reasoning_effort` low/medium for K2 and `enable_thinking` for Qwen; no reliance on the displayed setting label. The user's saved Qwen thinking level was checked and is `medium`, with no model sampling override.
- Model loading happens before task timing. A unique fixed-length system prefix (`[Benchmark UUID-arm-round]`) per block limits reuse of the task-specific prompt, without deleting the user's cache. It does not eliminate every shared prefix: K2's template places tool instructions before the supplied system message, and oMLX reported 1,536 cached tokens on the first request of each block, versus zero for each freshly launched Qwen server. This is a model-visible addition to the Pippa prompt, and could affect behavior. Later tasks in each block can reuse that block's prefix. The first invoice task therefore has unequal initial cache state across stacks; subsequent tasks are cache-reuse opportunities, not guaranteed hits. Switching from German to English also changes the system prompt. The same task is not tested twice consecutively as a paired cold/warm microbenchmark.
- Only one model runs inference at a time. K2 is unloaded before Qwen starts; its original loaded state is restored at the end.
- Timings start when the harness sends Pi the task and include Pi startup, model calls and tools. Record first generated token, first answer-text token, total task time, tool calls, model requests, usage, cache counts where reported, and errors. First answer text can be an intermediate statement; it does not establish correctness or task completion.

## Quality review

Automatic grades are retained as diagnostics. The final grade requires reading the final answer and relevant tool results/arguments; the automatic checks are too permissive for fabricated facts. Review is performed by the same assistant, not an independent human or independent blinded judge.

- **Yes:** requested outcome is complete, grounded in fixture evidence, in the requested language, and any requested action was actually confirmed by the mock.
- **Partial:** useful correct work, but a material omission, unsupported factual addition, wrong language, or an uncompleted portion of the request remains.
- **No:** no usable answer, wrong central result, no requested action, or failure/timeout without a usable completed outcome.
- Mark unsupported concrete facts separately, even when the remainder earns partial credit. Distinguish wrong facts from cautious uncertainty or a clearly labeled assumption.
- The `unsupported` flag in the review data includes wrong calculations, wrong dates, incorrect totals, unsupported additions and false completion claims. The report calls this a factual-error flag, not a formal hallucination metric. It is not severity-weighted: it includes wrong central totals and false completion claims as well as incorrect secondary details, such as translating hallway painting as garden painting.
- Unrequested file mutations disqualify full credit even if the tool rejects them. Attempts and confirmed effects are distinguished; fixture PDF hashes are checked to detect changes that could contaminate later tasks.
- Invoice tasks require the five 2024 invoices, total EUR 865.30 and identifiable supporting files/vendors, excluding offers and service-charge statements.
- Lease comparison requires the correct two documents, EUR 250 monthly/EUR 3,000 annual advance and EUR 270 balance; the advance credited agrees with the lease. The source cost total is EUR 3,270; it must be accurate if quoted, but need not be restated to answer whether the credited advance matches.
- Letter summaries require the window replacement and returning the form by 20 November 2026. Material invented cancellation dates invalidate full credit: the letter gives a receipt-relative rule, not a known receipt date. The source says furniture need not be dismantled; broadening this into no furniture moving/removal earns partial credit consistently across all arms, even when the main dates are correct.
- Insurance overview follows the existing threshold of at least five of six policies, excluding non-insurance decoys; fewer can receive partial credit. Amounts attributed to policies must be read, not inferred from file names.
- Web answers must use the saved evidence. No inline citations are required because the current Pippa prompt explicitly leaves sources to the UI; the original automatic rubric still checks links and may undergrade these answers.
- Insurance cancellation requires reading the policy and searching the saved web pages, correctly explaining the 31 August deadline, whether the current year's deadline has passed, and text-form cancellation.
- Mail task requires one accepted unsent reply draft with the supplied reading, no invented identity/date/recipient details, and no claim of sending.
- Reminder task requires one accepted reminder for 27 November 2026, grounded in the shown letter. A calendar event alone does not fully satisfy a reminder request.

Three repeats of ten tasks are a small, correlated sample. These results compare these complete configured stacks on these tasks; they do not isolate engine speed, quantization quality, or general model intelligence. Smoke tests are excluded from the scored run.

## Instrumentation notes

The first attempted Qwen block returned HTTP 401 before inference because the shell's inherited `LLAMA_API_KEY` enabled authentication on the benchmark-owned llama.cpp server. Those ten requests are retained under `diagnostics/invalid-auth/` and excluded from every score and timing. The runner was stopped, the immediately following unfinished K2-medium block was quarantined, and the server launcher was fixed to remove that inherited credential for its own isolated process. Completed K2-low and K2-medium round-one blocks were retained; the run resumed at Qwen round one in the original order. The metadata preserves both execution attempts.

The legacy mail mock describes every accepted draft as in-thread, including new-message drafts, and does not fully validate new-message recipients. Manual review therefore uses `reply_to`, recipient arguments and the draft body to score reply correctness. A final thread claim copied from that inaccurate mock receipt is not counted as an independent model fabrication. A submitted `to: selected` is not a valid substitute for `reply_to: selected`. This limitation applies equally to all arms; no mock behavior was changed between scored blocks.

The user date is supplied by the current Pippa context extension (for example `[2026-10-23, Friday]` in captured user messages), although an older comment in `tasks.mjs` says the date is absent. Review of the cancellation deadline uses the captured date.

The saved web pages use `.example` domains and are visibly synthetic. K2-medium round three explicitly rejected those placeholders before supplying unsupported prices and procedures. This means the web task tests compliance with fixture evidence and tool use, not real-world research accuracy; model sensitivity to synthetic evidence can affect the comparison. Fixture fee values must not be used as current public-service guidance.
