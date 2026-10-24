# Local runtime validation — 24 October 2026

Apple M6, 24 GiB unified memory, macOS 27.0.1. Pi 1.4.0; oMLX 0.7.0 for MLX profiles; Pippa's patched llama.cpp b11503 for Saluki. These are practical checks on a working Mac, not a general model leaderboard or a clean-machine/reboot certification.

## Identical coding tasks

Seven repository tasks, one attempt per profile, medium thinking, 4,096 generated tokens per request, 300-second task timeout. Same Pi executable, stock coding prompt and four built-in tools. Runs were serial in Qwen/K2/Saluki order; desktop load and cache state were not fully controlled. Profile sampling and context limits differ; this compares usable profiles, not isolated backend implementations. A fast failure is not a performance win. Passing requires the executable task checker, no timeout, successful Pi exit and no terminal model error.

| Profile | Passed | Median task time | Total task time |
|---|---:|---:|---:|
| Qwen3.6 35B A3B, NexVeridian MLX 3-bit | 4/7 | 22.9 s | 207.6 s |
| K2 Horizon 7B, MLX 4-bit | 5/7 | 46.5 s | 417.7 s |
| Underdog Saluki 27B, GGUF IQ2 mix | 6/7 | 81.9 s | 841.7 s |


Qwen failed T4 with malformed model-generated tool syntax and T5 by writing the report into Pi's package directory instead of the working directory. K2 failed T4 by using decimal points rather than the explicitly requested commas. Qwen and K2 exhausted the T6 output budget before producing a solution. Saluki passed the first five tasks and T7, but timed out on T6 with failing visible tests. The failures are retained in the evidence.

The installer profiles allow 8,192 output tokens. T6 was therefore retested separately with that actual budget and a 600-second task limit. These follow-ups are not pooled with the seven-task comparison:

- Qwen3.6 35B A3B, NexVeridian MLX 3-bit: failed, 333.1 seconds. visible tests fail
- K2 Horizon 7B, MLX 4-bit: failed, 600.0 seconds. visible tests fail

The earlier Qwen3.6 UD-Q3_K_XL GGUF score of 20/21 and Qwen3.8 GGUF score of 14/14 belong to different quantizations, runtimes, contexts and repetitions. They cannot be transferred to the MLX weights. Qwen3.6 GGUF was much faster than dense Qwen3.8 in that historical test. No profile is shown to be universally best.

## Profile selection

K2 medium is the conservative default for the new oMLX installation: a 5.1 GB download, substantially more RAM left for desktop applications, and fewer failed coding tasks in this sample than the compact Qwen MLX conversion. Qwen remains an explicit faster 24+ GiB alternative. This is a practical tradeoff, not a statistically established quality ranking or a claim that K2 beats the historically tested Qwen GGUF. Saluki remains the user's Pippa selection; the new installer does not replace it or delete existing K2/Qwen models.

## Standalone installer

An isolated HOME, system-only initial PATH and private dependencies exercised Node bootstrap, pinned Pi, the signed oMLX runtime, checksum-verified model snapshots, authenticated inference, a real random-file read, and the same test after server restart. Both MLX profiles passed installation. This used the existing Mac with verified downloaded assets; it was not another physical Mac or a newly installed macOS.

Lifecycle checks passed: two simultaneous starts produced one listener; doctor performed a real Pi tool call; a deliberately injected post-activation Pi failure returned nonzero, emitted no Ready message, restored the original configuration/key/wrappers/shell configuration byte for byte and restored the running service. LaunchAgent and manual start/restart/stop passed. No actual login or reboot was performed.

The restart test exposed a launchd race: the TCP listener closed before the old job disappeared. The installer now waits for job removal as well as port release. A separate test caught HOME inheritance in the LaunchAgent; HOME and PATH are now explicit. Engine changes across an existing installation and missing model selectors are refused. The repository suite passes 71 tests, including actual Pi runtime checks.

The larger Unsloth mixed-3-bit Qwen candidate (17.4 GB download) failed a cold install smoke under memory pressure and was rejected. The 15.2 GB NexVeridian profile passed the same installation and a 20,438-input-token retrieval: correct key, 39.9 seconds including model loading, peak physical process footprint about 16.2 GiB. System swap was already in use and grew by about 414 MiB during that check. A 32,768-token window is configured; a fully filled 32K window was not separately validated. Do not infer performance on older chips or exact memory headroom with other applications.

## Pippa responsiveness and correctness

The ten-task Saluki-medium comparison tested the old prompt/tool set against a combined candidate with narrower declarations and two extra prompt instructions. Median total time was 62.9 seconds before versus 84.2 seconds for the candidate, including timeouts (one versus two). The combined candidate was rejected: the extra prompt instructions were removed. A three-task scope-only follow-up was mixed (summary 60.9 → 59.4 s; web 51.4 → 70.6 s; document plus web 52.8 → 53.0 s). Single samples do not establish end-to-end acceleration.

A separate cold-input check used an unpredictable first system prefix, disabled thinking, exactly one output token and zero reported cached tokens. Three interleaved samples per arm measured **18.2 → 8.5 seconds median**, with **23 → 7 tools** and approximately **3,206 → 1,620 input tokens**. These captured candidate payloads include the subsequently removed short prompt addition; this measures input overhead, not full answer or GUI latency. An earlier attempt accidentally retained max_completion_tokens and generated multiple tokens; it is excluded.

The final filter narrows only clearly read-only document/web requests, retains an expansion tool, restores all permitted declarations on demand, keeps previously exposed tools, and does not modify registration or permissions. Unknown requests, native actions, skills, steering and draft-only launches retain their approved capabilities. The loader itself is omitted when all tools are already visible. Real-Pi tests cover MCP discovery, expansion, policy boundaries and the prompt budget.

A deterministic search defect was also fixed: English invoice queries now use the same bounded invoice/Rechnung category as German queries; insurance/Versicherung works the same way. In the real Spotlight fixture, invoice candidates increased from 1 to 6 and insurance from 0 to 5, matching their German equivalents. Other query words and year constraints remain required. This does not make an unindexed scan searchable or guarantee completeness. The search tool description no longer tells the model to omit Rechnung when invoices are the requested category.

The final German and English invoice follow-ups use a 300-second task limit (the earlier paired comparison used 180 seconds), so their completion times are not a controlled before/after comparison. They exercise the final search and tool-filter code.

The old automatic web grader expects inline links although Pippa deliberately displays source cards separately. Missing inline links are not counted as a product defect in this interpretation. The document-plus-web task still omitted the requested lookup; invoice completeness and unsupported qualifications require manual review. Model errors and long reasoning remain; no universal claim that Pippa is as fast or as accurate as terminal Pi follows from these tests.

## Evidence

Adjacent JSON contains the coding summaries, profile-budget follow-up, accepted cold-input samples, Pippa timings, search results and final invoice follow-up. Personal path prefixes are replaced; provider credentials and private agent directories are excluded. Raw events, failed attempts, logs and an HTML report remain in the local build workspace. Existing model selections are preserved.

## Delivery verification

The final source passed 106 Pippa runtime tests, 887 core checks and 45 PiRPC checks. Seven native-admission tests also passed against the signed app bundle. The Developer ID build passed the bundle/runtime verification and was installed locally with the previous application backed up. The three live Pi/Pippa model configuration files retained their hashes. Pippa source changes remain local; no Pippa release was published.

The installer is committed as `4b0a601` on `codex/standalone-omlx-setup`, with [draft PR #1](https://github.com/tschnorpfeil/pi-local-agent/pull/1). All three GitHub checks passed (unit tests, catalog and Ubuntu end-to-end integration). The default branch was not changed.
