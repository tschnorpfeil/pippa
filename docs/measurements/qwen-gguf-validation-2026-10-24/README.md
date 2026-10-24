# Qwen3.6 GGUF follow-up — 24 October 2026

## Question and conditions

The preceding oMLX comparison did not establish that K2 was the best local model. The follow-up tests the previously strong **Qwen3.6 35B-A3B UD-Q3_K_XL GGUF** under the same seven coding tasks and limits: Apple M6 with 24 GiB RAM, Pi 1.4.0, Node 24.22.1, medium thinking, 4,096 output tokens per request and a 300-second task timeout. The four stock coding tools and task checkers are unchanged. Tests run serially, with one loaded benchmark model. A task passes only when its executable checker passes, Pi exits successfully, and there is no terminal model error or timeout.

The archived model's SHA256 was verified as `a832b9689925f1bd335bbe985cdfb06c36bf2cf268f4f8f6eceafa3ceb515617`. Its pinned revision is `a483e9e6cbd595906af30beda3187c2663a1118c` in `unsloth/Qwen3.6-35B-A3B-GGUF`.

## Coding results

| Profile | Passed | Median task time | Total task time |
|---|---:|---:|---:|
| Qwen3.6 GGUF Q3, llama.cpp b11503 (Pippa build) | **7/7** | **34.5 s** | **250.7 s** |
| Qwen3.6 GGUF Q3, official b11503, shipped profile | **7/7** | **91.6 s** | **853.8 s** |
| K2 Horizon 7B MLX 4-bit (preceding run) | 5/7 | 46.5 s | 417.7 s |
| Qwen3.6 NexVeridian MLX 3-bit (preceding run) | 4/7 | 22.9 s | 207.6 s |
| Saluki 27B GGUF IQ2 (preceding run) | 6/7 | 81.9 s | 841.7 s |

Qwen GGUF passed T1–T7 in 21.6, 34.5, 55.1, 23.3, 28.2, 40.2 and 47.8 seconds. T6 includes both visible and hidden parser checks. Recovered tool errors include failing initial fixture tests and are not automatically model failures. A fast failed task is not a performance win; all failures and timeouts remain in the timing summaries.

These are profile comparisons, not a controlled experiment isolating GGUF versus MLX. Quantization, sampling, context and server implementations differ. Qwen uses 32K context, Saluki 16K. The first Qwen run uses Pippa's b11503 binary with its unrelated K2 parser patch; the installer ships the verified official prebuilt b11503 binary. The full suite was repeated with that actual shipped profile: all seven tasks passed again, in 91.6, 84.3, 102.4, 56.0, 74.8, 258.7 and 186.0 seconds. This slower run followed a 30K-context stress test. System load and swap increased; the installed oMLX server reported zero loaded models. Memory pressure, cache settings, runtime build and sample variation are possible contributors, but these measurements do not isolate a cause. Slow results remain included. The default prioritizes the repeated correctness result; consistent speed superiority is not established. Desktop load and cache state are not randomized, and prior runs were performed earlier on this Mac. No claim of statistical significance or universal superiority follows from these samples.

A separate T1 control after restarting the official server passed in **25.6 seconds** (versus 91.6 seconds for T1 immediately following the long-context test). It supports a state-dependent slowdown, but one control cannot attribute it to a particular cache setting or prove that restarting fixes all workloads. It does not replace the slower full-suite result.

## Deployment profile

A new Apple-Silicon installation selects Qwen3.6 GGUF with llama.cpp. Medium thinking, 32K context, 4,096 output tokens, one slot, Q8 key/value caches and temperature 0.6 / top-p 0.95 / top-k 20 / min-p 0 match the coding profile. For sustained use on 24 GiB, the shipped profile additionally caps llama.cpp's prompt cache at **1 GiB** and context checkpoints at **four**, instead of the defaults used in the initial comparison. The official-runtime confirmation is reported separately because of those changes.

The installer keeps private pinned Node and Pi runtimes, authenticated loopback service startup, SHA256 model verification, provider/settings preservation, a real random-file read and answer before and after restart, and rollback after ordinary activation failures. It needs neither Pippa nor a compiler. Existing oMLX installations retain their engine and profile; K2 remains an explicit smaller option. Existing legacy router installations keep their existing maintenance path. Cross-engine replacement requires separate installation directories rather than silently rewriting an active setup.

## What this comparison does not show

Terminal coding tasks and Pippa everyday tasks are different suites. Their pass counts and times cannot measure UI overhead or establish that Pippa makes Pi worse. Pippa supplies its own system prompt, tool schemas, tool-scoping extension, document/native bridges and shown context to the same Pi engine. A frontend-parity experiment must hold the task, model, history, prompt, tools, inference settings and runtime constant and separately measure inference, tool and rendering time. These runs qualify model profiles within each workload, not frontend equivalence.

## Pippa qualification

The same ten Pippa tasks are run against Qwen GGUF and Saluki using the final Pippa prompt/tool/filter/search code, deterministic documents and mocked native/mail/web tools. Both use medium thinking, 4,096 output tokens and a 180-second task limit. A separate Qwen thinking-off run explores a usable Pippa profile and must not be pooled with the medium comparison. The fixtures do not send real mail or exercise live websites.

Manual review checks factual details and actual tool calls in addition to the historical keyword grader. Missing inline links alone do not fail an answer because Pippa displays source cards. Incorrect invoice totals, missed requested lookups, wrong draft threading, changed document facts and empty answers do fail. A coding win does not by itself authorize claiming an improvement in Pippa.

The accompanying evidence records the final validation and selection decision.

## Installer validation

- **75 automated tests passed, zero skipped**, including actual Pi-runtime tests.
- A disposable HOME with system-only PATH completed installation, a random-file Pi read and exact answer, authenticated API checks and the same smoke after restart. Node and weights were supplied as local verified caches; the official llama.cpp artifact and pinned Pi were installed through the real installer. This is not a completely erased Mac or a zero-cache test of every download.
- Two simultaneous starts produced one listener. LaunchAgent and manual lifecycle checks, doctor and restart passed.
- An injected Pi failure after activation failed the installer without a success message, restored the prior configuration/wrappers/key byte for byte, and restored the previous running server. Doctor passed after rollback.
- A **30,044-input-token** uncached request retrieved its random reference exactly, taking **163.8 seconds**. System swap was already in use: 8,249.75 MiB before and 8,610.94 MiB after. Process physical-footprint counters do not capture all file-backed GGUF/Metal residency and must not be treated as the model's total RAM requirement. This shows functional long-context support, not consistently interactive performance at 32K on 24 GiB.

## Pippa result and selection

| Profile | Manual passes | Median task time | Empty answers / timeouts |
|---|---:|---:|---:|
| Qwen3.6 Q3, medium | 3/10 | 28.9 s | 1/10 |
| Saluki IQ2, medium, production sampling | 6/10 | 69.9 s | 2/10 |
| Qwen3.6 Q3, thinking off (separate exploration) | 6/10 | 34.5 s | 0/10 |

The rule declared before reviewing the thinking-off run required at least Saluki's manual pass count, a lower median, and no regression in the selected-thread mail and dated-reminder tasks. Qwen thinking-off meets that rule. **Pippa's 24 GiB-and-up default becomes Qwen3.6 Q3 with thinking off; terminal Pi uses medium.** The smaller Mac defaults remain unchanged. Qwen medium is unsuitable as Pippa's default in this sample despite its strong terminal coding result.

The off profile still misses preparation details in the German summary, guesses insurance categories, skips the requested web lookup alongside a policy, and gives the wrong paid total in the English invoice task (in German). Its passing German invoice answer gives the correct five amounts and total, explicitly excludes the utility statement, but incorrectly introduces the six retrieved documents as six invoices. That count/label defect is recorded; it is not scored as a wrong paid total. Both native actions pass after the mail task recovers an invalid reply reference. Saluki also retains errors; six of ten is not a claim that either model is consistently correct.

The first Saluki attempt accidentally used llama.cpp's default sampling. It was excluded in full and rerun with the exact production sampling parameters. Only the corrected run appears in the comparison. No prompt, fixture, or answer was repaired during the measured runs. The thinking-off exploration uses the official runtime and bounded-cache deployment profile, so it cannot isolate thinking alone from all other runtime effects.

The sanitized [per-task evidence](results.json) records answers, tool calls, grading and inference controls. Raw events and excluded attempts are retained locally; credentials and raw model reasoning are not published.

## Evidence

[Sanitized results](results.json) include per-task answers, controls, checks and manual grading. Local raw events, excluded attempts and logs are retained in `.build/qwen-gguf-validation`. Account-derived paths and signatures are sanitized; provider secrets and model reasoning streams are excluded.
