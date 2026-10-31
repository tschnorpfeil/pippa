# Next-level Pippa: plan for the release after 0.3.17

## 1. Verdict

Pippa has a solid deterministic core, and it can already save and restore its model state across unloads. It feels slower than Pi in the terminal for two reasons. First, the single-slot llama-server keeps re-reading prompt text it already processed. Second, the UI redraws itself while the model works. On top of that, RAM is not bounded on the 8 GB tier or for any profile outside the table. The precondition for everything else is one memory guarantee: bounded caches, a check that the Mac has room before a model loads, and a pressure path that unloads the model in every state. Today that path does nothing while the model is loading or when the server was started by terminal Pi. The single biggest speed lever is keeping the prompt cache warm: a fixed tool list per conversation, a stable system prefix, and no cold summary runs. That should come right after the release, once the cache telemetry is in place.

## 2. Next release: 0.3.18 (scope, in order)

Ship it as 0.3.18, not 0.4. The launch gates in `docs/positioning.md` are still open: the scripted demo GIF in the README, and "Organize" vs "Tidy Up" in the English strings. All work goes on one local integration branch cut from `origin/main` (ec2cb0c). Nothing is pushed.

| # | Item | Branch | Effort | Risk | Verification |
|---|---|---|---|---|---|
| 1 | **BLOCKER: Sparkle key.** `origin/main` Info.plist has `iapp2ewn…`, but v0.3.17-784 shipped `BM/Djr…`. `scripts/release.sh:35-36` aborts on a mismatch. Bring in b029bb4 (it is included in air-resource-budget). Add a check to `scripts/tests/test_release.py`: `SUPublicEDKey` must equal the key in the newest `v*` tag unless a key-rotation marker file exists. | `codex/air-resource-budget` (exists locally and on origin) | S | Low | The new test fails on a deliberately changed key. `generate_keys -p` matches the plist. |
| 2 | **RAM bound (c3eb31d) and workspace (d9f6d92).** `ModelSelector.choice` defaults to `cache-ram 0`. Today the 8 GB row (`Models.swift:120`) and every `named()` profile at ≥ 20 GB get llama.cpp's default in-RAM prompt cache of up to 8 GiB. It also fixes `PiLocalServer.swift:86`, which clamps to `model.ctx` (the 9B's catalog ctx is 32768) instead of the profile's ctx. That is why the 9B runs at 32K on 24 GB Macs. | same | S | Medium: follow-up turns may re-read more text | `ps` shows `--cache-ram 0`. `n_ctx_slot=16384` for the 9B in llama-server-pi.log. SetupChecks green. Footprint and swap measured before and after (item 8). |
| 3 | **The pressure path works in every state** (`LlamaServer.swift`). (a) `memoryPressure` returns early while `.starting` (line 520): under critical pressure, abort the start instead. (b) `stop()` only lets go of an adopted server (line 376). Under critical pressure, or at warning with no request in flight, SIGTERM the adopted PID from the lock, then SIGKILL after 2 s. (c) Make `stop()` async instead of the `usleep` loop that blocks the actor (line 382). (d) Log a DiagnosticsLog event for every pressure unload, with its level. | new: `perf/pressure-path` | S–M | Low–medium: a terminal Pi request fails under critical pressure, which is acceptable | `memory_pressure -l critical` with an owned, an adopted and a starting server: the PID is gone and the lock removed within 3 s. Status-line gap during the unload < 250 ms. |
| 4 | **Check memory before loading, and gate preloads.** Add a `MemoryHeadroom` helper (`host_statistics64` free + inactive + purgeable + speculative, plus `kern.memorystatus_vm_pressure_level`). Load requests: refuse only at critical pressure; log the headroom for everything else. Ship it log-only first, thresholds in §3. `preloadIfCold()` (`PiRPCChat+ColdStart.swift:31`, triggered at `AppModel.swift:653`) runs only at normal pressure and above the preload headroom. It skips when `thermalState ≥ .serious`, in Low Power Mode, and for 10 minutes after a pressure unload. Add a new `PippaError.notEnoughMemory` with plain-words copy. | same as #3 | M | Medium: thresholds that are too strict | Synthetic `memory_pressure -S -l critical`: no load starts and the UI stays responsive. Preload/unload counts in DiagnosticsLog. |
| 5 | **expandable-tool-steps, with reasoning updates batched.** Today every thinking token arrives as a `@Published thought` change (`PiRPCChat.swift:489`), and each one runs an O(n) `reasoning.count` (`ThoughtLine.swift:454-455`). Through AppModel's change forwarding (`AppModel.swift:175-212`), each token also triggers a full shell layout (`ShellController.swift:149`). Buffer reasoning the same way `bufferDelta` handles text, flushing every 80–150 ms. Cap by utf8 count. Run `DotPulseView`/`PillAura` at 15 fps instead of 30. | `claude/expandable-tool-steps` + fix commit | M | Low–medium | Changes per second ≤ 12 during reasoning. Pippa CPU during a 60 s thinking answer ≤ 10 % on an Air. 0 main-thread hangs ≥ 250 ms. |
| 6 | **Shell layout only on geometry changes** (optional extra). ShellController subscribes to a `LayoutKey` (mode, rails, size, drops, toast, pill) with `removeDuplicates` instead of `model.objectWillChange`. | new: `perf/layout-key` | S | Medium: hidden dependencies | Signpost count < 1 layout per second while streaming. Snapshot scripts pixel-identical. |
| 7 | **conversation-window-level** (b5c2d36). Check the header at 400 pt and ≥ 632 pt, because d9f6d92 shrinks it from 64 to 56 pt. | `claude/conversation-window-level` | S | Low–medium | `check-conversation-rails.sh` in both languages. `check-strings.py`. Manual checks of the pin and Settings. |
| 8 | **Measure memory on 8 and 16 GB as a release gate.** A 5-turn script with one file read and one search. Record peak llama-server footprint, the `vm.swapusage` delta and the maximum pressure level, with Safari and Mail open. Repeat with `pi` in the terminal on the same server. Record it in `docs/measurements/release-candidate-0.3.18-<date>.md`. | measurement | M | Needs physical Macs | Swap growth ≤ 256 MiB, never critical, time to first token on turn 2 and later regresses ≤ 20 %. |
| 9 | **Version, notes, gates, update probe.** Set 0.3.18 in `PippaCore.swift:5` and write `docs/releases/0.3.18.md` (standard intro, then: lighter on memory, Float on Top, see what Pippa is doing, Stop Answering). Run the niced local gates, then `release.sh`. Run the update probe from a build-784 host (EdDSA) and a build-744 host (Developer ID fallback). | integration | M | Low | `UPDATE INSTALLED` for both hosts. All gates exit 0. |

Not in this release: changes to the 24 GB tier, a thinking-level change, the tool-scope freeze (see §5, #1). They need measurements first, and §4 and §5 hold them.

## 3. Memory and "never freeze the Mac"

**Can Pippa cap RAM? Yes, but only as a budget Pippa imposes on itself.** macOS gives no usable hard cap:
- there are no cgroups;
- `RLIMIT_AS`/`RSS` are not enforced in a useful way and do not count Metal or mmap'd memory;
- per-process jetsam limits are private API;
- `iogpu.wired_limit_mb` is a system setting and must not be touched.

The budget is built from:
- a bounded configuration: tier table, fixed ctx, `cache-ram 0` unless a measurement pays for more, q8_0 KV, `--parallel 1`;
- keep mmap; never `--mlock` or `--no-mmap`. Mmap'd GGUF pages are file-backed and the kernel can drop them without writing swap;
- a memory check before every load (#4) and pressure unloads in every state (#3);
- hysteresis, so preloading does not thrash.

Numbers per tier. `budgetGiB` is the existing formula at `Models.swift:172`; today only PippaChecks call it, and it becomes a hard check in `choose()`/`named()`:

| Tier | Model (memGiB) | ctx | cache-ram | Budget (budgetGiB) | Refuse load | Preload only if | Release gate |
|---|---|---|---|---|---|---|---|
| 8 GB | Qwen3.5 4B Q4 (4.2) | 16K | 0 | 4.8 GiB | critical pressure (enforced); headroom < 5.2 GiB logged only | normal pressure, headroom ≥ 6 GiB | footprint ≤ 4.8 GiB, swap +≤ 256 MiB |
| 16 GB | Qwen3.5 9B Q4 (7.0) | 16K | 0 | 10 GiB | critical; headroom < 8 GiB logged | normal, ≥ 10 GiB | footprint ≤ 9 GiB, swap +≤ 256 MiB |
| 24 GB | Qwen3.6 35B-A3B Q3 (17.5) | 32K today → candidate 16K | 1024 today → candidate 0 | 18 GiB (0.5 GiB of room before KV) | critical; headroom < 18.5 GiB logged | normal, ≥ 20 GiB (in practice: no preloading with apps open) | measured 30K request: 163.8 s with 8.2 GiB swap, so this tier fails the gate today |
| 32 GB+ | 35B-A3B Q3 | 32K | ≤ 1024 | 24 GiB | critical | normal, ≥ 22 GiB | swap +≤ 256 MiB |

The refusal thresholds stay log-only for 0.3.18. Tighten them in 0.3.19 using the logged headroom data, so Pippa never refuses loads that would have worked on a busy 8 GB Air. For 24 GB, measure the same Q3 at 16K with `cache-ram 0` against IQ3 (14.5 GiB) at 16K with thinking off. Use the ten-task rule plus zero swap growth with Safari, Mail and Pages open.

## 4. Thinking level

- **8 GB (4B): stay off.** It is already off.
- **24 GB (35B-A3B): stay off.** It was measured at 6/10 off vs 3/10 medium.
- **16 GB (9B): currently `medium`. Measure off vs medium before changing anything.** `low` does not exist for Qwen: `PiModelTuning.swift:40` maps it to `NSNull()`, and `enable_thinking` is only on or off. The roadmap blames thinking for the 15.6 s median first visible answer.

What to measure first:
1. The ten model-compare tasks on a physical 16 GB Mac, with production sampling. Decide the rule beforehand: switch to off if passes ≥ medium's and the median time to first visible text drops.
2. Run `cache-report` (§5, #1) next to it. With thinking on, Qwen's template drops earlier `<think>` blocks. Each new question then re-reads the whole last turn (cacheRead 3522 against a previous prompt of 4188 tokens). So "off" also wins time on the cached path.
3. Optional third arm, only if the pinned llama.cpp supports a per-request reasoning budget: medium with a 512-token cap.

Also record thermalState (it must not reach `.serious`) and the powermetrics average on an Air. Changing the level is a one-line catalog revert.

## 5. Later (ranked backlog)

1. **Cache telemetry and a stock-Pi arm** (S). Add `scripts/quality/cache-report.mjs`: uncached vs cached tokens, prefill seconds and cache divergences per request, from Pi session JSONL and llama-server-pi.log, numbers only. Add one DiagnosticsLog event per answer. Add variant "S" to model-compare. This turns "slower than terminal Pi" into a measurement. Do it first after the release.
2. **Freeze the tool list per conversation** (S). `tool-scope.mjs:103` adds to the list across turns and changes it in the middle of an answer. Qwen renders tools before all messages, so each change re-reads the whole conversation. It also classifies the composed message including shown-file text. Classify only the person's own words, decide the list on the first request, and only ever widen it once to the full list. Check with `tool-choice.mjs`.
3. **Byte-stable system prefix plus a saved prefix slot for new conversations** (L). Move `<earlier>` (`pippa-context.ts:157`) and `<memory>` into the first user message. Prefill system and tools once, save the slot as `prefix-<hash>.bin`, and restore it when a new conversation starts. Each new conversation currently costs about 3.5k cold tokens, measured at 50–74 s on this Mac.
4. **A save slot per conversation** (M). Key the slot file by Pi session id, save and restore on conversation switch, cap the folder at about 1–2 GB with LRU eviction. Uses disk instead of RAM.
5. **Idle compaction that reuses the live prefix** (M). Today `ctx.compact` sends a cold summarizer prompt over 10–20k tokens and evicts the warm slot. Stopgap: compact only at 75 % full, on AC power and not thermally throttled.
6. **Batch tool-step events at the source and remove AppModel's change forwarding** (M), then migrate to `@Observable` (L).
7. **Letter facts in `read_document`, plus a code-only router for deadlines and invoices** (M + M). Small models get past/open deadlines and sums wrong. A router that answers without the model saves whole inference runs on Airs.
8. **`invoice_table` as a tool Pi can call** (M), and code-checked sums in SourceFidelity (S).
9. **Delete the release-dead model path in LocalEngine** (M). One readiness source, and the second-llama-server path can no longer exist. Add one gate for Apple's on-device model that knows the llama-server and thermal state (S).
10. **Measure `--threads` and flash attention** (S). The arguments built at `LlamaServer.swift:164-180` pass no `--threads` and no flash-attention flag. The 9B prefills at only 50–70 tok/s, which is suspiciously slow.
11. Stop the shell tool from naming python when it is not installed (S). Stop re-injecting shown file text that is still in context (S). Make German deadline rules consistent (M). fill_pdf part 2 (M). Remove the "thorough" profile (S). English deadline patterns (M). Split AppModel (M).

## 6. Decisions you need to make

1. **Call it 0.3.18 or 0.4?** Recommended: 0.3.18. The 0.4 launch gates are still open.
2. **Should the memory check refuse loads already in 0.3.18?** Recommended: refuse only under critical pressure, log headroom otherwise, and set thresholds in 0.3.19 from the data.
3. **Keep `cache-ram 1024` on 24 GB+?** Recommended: keep it in 0.3.18 and measure it together with the 24 GB re-sizing.
4. **24 GB: 16K context or IQ3?** Recommended: do not change it for 0.3.18. Measure both against today's setting, and ship the winner in 0.3.19.
5. **Turn thinking off on 16 GB?** Recommended: only if the pre-registered ten-task rule passes, and not without the measurement.
6. **Do you have access to physical 8 and 16 GB Macs for item 8?** If not, run memory-limited runs on the 24 GB Mac and label them as such in the measurement record.
7. **Ship the reasoning display now or later?** Recommended: now, but only with item 5's batching.
8. **Can the release kill an adopted server (one terminal Pi started) under memory pressure?** Recommended: yes. The terminal extension restarts it on the next request.

## 7. Implementation workflow (parallel agents, no file overlap, no push)

| Agent | Base | Files it touches (exclusively) | Local gates |
|---|---|---|---|
| **A: integration** (runs first, then last) | `origin/main` → merge `codex/air-resource-budget`, then `claude/conversation-window-level` | `scripts/tests/test_release.py`, merge resolutions in `ConversationWindow.swift`/`AppModel.swift`; at the end `PippaCore.swift:5`, `docs/releases/0.3.18.md` | full gate list below |
| **B: pressure and memory check** | A's integration commit | `PippaCore/LlamaServer.swift`, new `PippaCore/MemoryHeadroom.swift`, new `PippaCore/HostConditions.swift` (thermal state and Low Power Mode), `PippaCore` error type, Core `.strings` (de/en) for the new error, `Pippa/App/PiRPCChat+ColdStart.swift`, new `PippaChecks/PressureChecks.swift` | `swift build`, `PippaChecks`, `PiRPCChecks`, `check-strings.py`, `runtime/pippa-local-server` node tests, the synthetic `memory_pressure` run |
| **C: reasoning batching** | `claude/expandable-tool-steps` | `PippaCore/ThoughtLine.swift`, `Pippa/App/ConversationController.swift`, `Pippa/Views/DotPulseView.swift`, `Pippa/Shell/PillAura.swift`, `PippaChecks` ThoughtLine/WorkShape checks | `swift build`, `PippaChecks`, `PiRPCChecks`, snapshot scripts for chat/states |
| **D: layout key** (optional extra) | A's commit | `Pippa/Shell/ShellController.swift` only | `swift build`, snapshot scripts (pill, states, workspace, chat), `check-conversation-rails.sh` |
| **E: measurement scripts** (no app code) | A's commit | new `scripts/quality/cache-report.mjs`, new `scripts/quality/memory-gate.*`, `scripts/quality/model-compare/variants.mjs` (stock arm) | `node --test` for the new scripts. The model runs themselves start only when you start them. |

Order: A builds the base. B, C, D and E run in parallel. A then merges C (after its fix), B, D and E into the integration branch, runs the gates once on the integrated commit, bumps the version, writes the notes, and reports "ready to push, one command is enough".

Full gate list, run one after another, each prefixed with `taskpolicy -b` or `nice -n 10`:
1. `python3 scripts/check-strings.py`
2. `python3 -m unittest discover -s scripts/tests -p 'test_*.py'`
3. `python3 scripts/check-default-models.py`
4. `swift build --package-path app`
5. `swift run --package-path app PippaChecks`
6. `swift run --package-path app PiRPCChecks`
7. `runtime/pippa-web` `npm ci --ignore-scripts && npm test`
8. pippa-tools and tool-scope node tests, as in ci.yml
9. the `pippa-auth` test
10. the `pippa-local-server` autostart and real-pi tests
11. `scripts/check-conversation-rails.sh`
12. `check-site.cjs` and `check-site-launch.cjs`

For `build-app.sh`, also add a `PIPPA_BUILD_JOBS` override (default ncpu−2), so the llama.cpp build does not take every core. No `git push`, `gh pr` or CI runs without your explicit command.

**Where the reports were wrong:**
- `--threads` is not set anywhere. The `n_threads=4` one report attributed to `LlamaServer.swift:173` is llama.cpp's own default, not Pippa's.
- `codex/air-resource-budget` also exists as a local branch, checked out in another worktree, not only on origin.
- The IQ3 model's catalog `memGiB` is 14.5. One report gave 13.7 GB, which is the file size.

Everything else I checked by reading the files held up: `Models.swift` table, `choice`, `named` and `budgetGiB`; `LlamaServer.swift:165/376/382/520`; the Info.plist keys on `origin/main` and the tag; `PiModelTuning.swift:40`; the forwarding sinks in `AppModel.swift`; `ShellController.swift:149`; `PiRPCChat.swift:489`; `ThoughtLine.swift:454`; the 30 fps animations; `PiLocalServer.swift:86`; `tool-scope.mjs:103`; and `release.sh:34-36`.