# Local agent validation and Pippa/Pi comparison

24 October 2026 · Apple M6 · 24 GiB unified memory · macOS 27.0.1 · Pi 1.4.0.

This follow-up covers 20 Saluki/Pippa task attempts, 30 small terminal integration attempts and 12 controlled prompt/tool attempts. Server lifecycle checks and an installer review are reported separately. These are practical local measurements on a working desktop, not a general model leaderboard.

## Does Pippa make Pi worse?

The current defaults differ: terminal Pi starts K2 7B on oMLX with low reasoning; Pippa uses Saluki 27B IQ2 on llama.cpp with medium reasoning. Comparing those defaults does not isolate the application layer.

The controlled comparison holds the Saluki server, reasoning off, sampling, 16K context, 4,096-token output cap, fixture data and user task fixed. Two tasks (letter summary and insurance deadline plus requested lookup) are repeated twice, reversing profile order on the second repeat. All profiles retain Pippa's extensions, bundled skills and fixture isolation. “Stock” changes only Pi's base prompt; “lean stock” additionally exposes five relevant tools rather than 23. This is not an unmodified terminal-versus-GUI end-to-end test.

| Profile | First text, median | Total, median | Correct / partial / failed | Initial prompt tokens |
|---|---:|---:|---:|---:|
| Pippa prompt, 23 tools | 21.8 s | 38.7 s | 1 / 2 / 1 | 3185–3257 |
| Pi base prompt, 23 tools | 23.9 s | 36.6 s | 2 / 0 / 2 | 3266–3338 |
| Pi base prompt, 5 tools | 10.2 s | 28.6 s | 0 / 2 / 2 | 1367–1439 |

The small comparison does not establish a general quality regression from Pippa's base prompt. Reducing advertised tools improved practical latency here, but did not improve factual reliability. Both lean summaries added an unsupported furniture claim; both lean deadline answers were wrong. Full-tool stock Pi also gave wrong deadline answers twice. The current date was present in all requests. The second Pippa deadline answer avoided claiming the deadline was open but failed to answer that part and omitted the lookup, earning partial credit.

Pippa forwards the first text chunk immediately; subsequent UI updates are batched for 80 ms (`ConversationController.swift`). Its prompt discourages progress preambles. It also uses its own tools, skills, working directory, memory and sessions, and disables project context files. Those are meaningful behavioral differences. Memory, old conversations, real app tools, native GUI startup and rendering latency were not measured by this fresh-session ablation. A loop brake is useful: in the terminal Saluki-off ledger attempt without it, the same successful read repeated 39 times before timeout.

No production prompts, tool lists or rendering behavior were changed during this diagnostic experiment. See [complete answers, grades and source findings](pippa-vs-pi.json).

## Identical small terminal tasks

Six tasks per profile: exact JSON, file-based arithmetic, a real code correction, a two-file rename, absent information, and an instruction embedded inside untrusted document data. Code results were executed with Node. The document test checks the factual amount and absence of unauthorized writes, not exact prose brevity. This is one attempt per task/profile, not a general coding or security benchmark.

| Profile | Core checks passed | Median total |
|---|---:|---:|
| k2-low | 5/6 | 3.9 s |
| k2-medium | 6/6 | 11.2 s |
| qwen-medium | 5/6 | 9.9 s |
| saluki-medium | 6/6 | 22.6 s |
| saluki-off | 5/6 | 23.5 s |

The expected ledger result was 35.00. K2-low excluded the explicitly requested credit and returned 40.00; Qwen returned 34.00. Saluki-off timed out after repeated reads. K2-medium and Saluki-medium passed all six checks; a sample this small cannot establish the best model for 24 GiB.

## Saluki on the ten Pippa tasks

| Reasoning | Correct / partial / failed | Median total | 180 s timeouts |
|---|---:|---:|---:|
| medium | 5 / 3 / 2 | 87.5 s | 2 |
| off | 5 / 2 / 3 | 27.6 s | 0 |

These runs use the same ten-task rubric as the earlier [K2/Qwen comparison](../omlx-compare-2026-10-23/README.md), but a different run order and cache treatment and Saluki's installed 16K context. Do not pool the timing results. Reasoning-off used the installed sampling configuration, not separately tuned off sampling. The test establishes successful integration with significant remaining quality limitations, not Saluki's superiority. All 54 model requests received HTTP 200; two medium tasks nevertheless failed to finish before the task timeout.

## Lifecycle and configuration

Two simultaneous cold Pi starts both answered correctly and created exactly one Saluki server. A subsequent controlled stop and restart succeeded. These are process restart tests, not a Mac reboot. Qwen started through its own provider; K2 was loaded for tests and restored to its originally unloaded state. Saluki was restored and remains Pippa's selected model. All three live configuration files retained their original hashes. All 20 fixture PDFs remained unchanged. Local endpoints require authentication and bind loopback. No personal mail, reminders or calendar items were changed.

## pi-local-agent review

Reviewed checkout: `<home>/Projects/pi-local-agent`, matching GitHub HEAD `0eda551660b532402cae81be88cedc9e32d72165`. All 64 tests passed with Pi 1.4.0. No installer implementation changes or publication were made.

The repository is not yet the requested standalone oMLX installer:

1. It currently supports llama.cpp/GGUF only. On this 24 GiB Mac its static catalog selects Qwen3.6 35B Q3, not one of the current MLX profiles.
2. A failed real Pi smoke test still ends with success/exit zero. Reproduced with an intentionally insufficient context using an artificial model in an isolated fresh HOME.
3. A disabled `-builtin:llama.cpp` extension survives settings merge while the installer selects that provider as default. Reproduced with real Pi returning `Unknown provider`.
4. Unpinned Pi/addon/Node versions prevent whole-stack reproducibility; `--no-packages` is not respected by doctor; rollback does not cover the full install transaction.

The fresh-HOME bootstrap installed its private Node, Pi and model server. The artificial model verifies transport only, never quality. This was not a clean macOS install, another Mac, a login-service qualification, or a reboot. Temporary installed test runtimes were stopped and removed.

For the requested Apple Silicon scope, the installer should own a versioned engine and a curated tested profile (weights, template, reasoning, sampling and context), select by validated RAM budget, verify a real answer/tool round trip/restart, and roll back on failure. “Best” should mean a versioned tested recommendation, not merely the highest catalog rank that fits. The current live Saluki and Qwen setup depends on Pippa's binary/helpers and is not yet standalone.

The intended entry point is `git clone …`, then `./install.sh --yes`, then `pi`; cloning alone does not execute setup. Official [oMLX installation documentation](https://github.com/jundot/omlx#install) describes the macOS application with bundled native kernels. A managed runtime should avoid assuming a preinstalled Pippa, Homebrew or full Xcode. See [review evidence and proposed installer contract](repo-review.json).

## Evidence and limits

The adjacent JSON files preserve all scored answers from the terminal checks and controlled ablation, manual review notes, lifecycle results and configuration checks. Raw RPC events, captured request payloads, scripts, fresh-HOME install logs and the HTML report remain locally under `<repo>/.build/saluki-validation/`. No credentials are archived. Personal path prefixes are replaced in this directory.

Cache reuse and desktop background load affect timing. Two ablation tasks and one terminal pass are diagnostic samples. Quality grades are assistant-reviewed, not independently blinded. No model is demonstrated to be globally best for 24 GiB, and no universal Pippa-versus-Pi quality conclusion follows from this sample.
