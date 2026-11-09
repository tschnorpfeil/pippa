# Local AI on the Mac: research, November 2026

As of 2026-11-09. The question: what is the best way for Pippa to run AI on a Mac, without the internet, for people who
never open a terminal? Today Pippa uses [oMLX](https://github.com/jundot/omlx) with Ornith 1.5 9B ([models.md](models.md),
[omlx-switch.md](omlx-switch.md)).

Two independent research passes (Claude Opus 5.5 and Gemini 4 Argon) covered engines, models, techniques and Apple's
on-device model. Each claim they disagreed on, and every claim this document builds a recommendation on, was checked
again at the source or on a Mac mini (Apple M6, 24 GB, macOS 27.0.1). **Checked** means read at the source or measured.
**Reported** means taken from a vendor card, release notes or a community table without reproducing it.

## Bottom line

1. **Keep oMLX and Ornith 1.5 9B.** No other engine would fix what is slow today. The slow part is reading long tool
   results (prompts up to 23K tokens), and that speed depends on the chip and the model's design, not on the server.
2. **Ship oMLX's native kernels.** Pippa's runtime archive has none of them (checked). oMLX says Qwen 3.5 models, which
   Ornith is built on, need them and otherwise "silently fall back to much slower generic paths". Building them needs
   full Xcode, but only on the machine that builds the runtime (the macOS 26 CI runners have it). The kernels then
   ship compiled inside the runtime download, so nobody using Pippa needs Xcode or the Command Line Tools. The gain
   for Ornith 9B is not measured yet.
3. **Make tool results smaller.** A 23K-token PDF result costs 100–300 s to read on M1–M4, whatever the engine. Page
   ranges, extracted table rows and totals computed in code shrink it at the source. This is the biggest lever on
   the slow tasks in [omlx-switch.md](omlx-switch.md#acceptance-2026-11-01).
4. **On Macs with 32 GB or more, offer Ornith 1.5 35B-A3B.** It scores clearly higher on agent benchmarks, and because
   only 3B of its weights work per token it reads and writes faster than the 9B. It needs Pippa's own task gate on a
   32 GB Mac first.
5. **Apple's on-device model is a helper, not the agent.** It writes good German titles in under a second, but its
   8,192-token context cannot hold Pippa's tools and documents, and it sometimes refuses harmless questions.

## What Pippa runs today

| Part | State (checked 2026-11-09) |
|---|---|
| Engine | oMLX 0.7.3 in Pippa's runtime archive `mlx-runtime-0.7.3-1` (Python 3.11, `scripts/build-mlx-runtime.sh`) |
| Native kernels | **None.** `native_kernel_status()` reports all four packages missing, for example `No module named 'omlx.custom_kernels.attention._ext'`. The build does a plain `uv pip install` of the source archive; kernels only build with `OMLX_WITH_CUSTOM_KERNEL=1` and Xcode's Metal toolchain |
| Oldest macOS | **26.2.** The MLX binaries in the runtime (`libmlx.dylib`, `core.cpython-311-darwin.so`, `libjaccl.dylib`) need it, although their wheels are tagged `macosx_26_0`; everything else loads from macOS 14. Pippa promised macOS 15 until 2026-11-09, where this runtime cannot load; she now requires 26.2, and `scripts/macho-minos.py` stops a runtime build that needs a newer macOS than `LSMinimumSystemVersion` |
| Model | `ornith-ai/Ornith-1.5-9B-MLX-4bit`, 5.06 GB, uniform 4-bit. Its config names one MTP layer, but none of its 927 tensors are MTP weights, so multi-token prediction cannot run on it |
| Settings Pippa writes | SSD prompt cache 8 GB; idle unload after 600 s; temperature 0.6, top-k 20, top-p 0.95; context 32K (24 GB and up) or 16K (16 GB) |
| oMLX defaults in effect | RAM cache tier 0 (cache lives on the SSD only); memory guard "balanced"; SpecPrefill, DFlash, MTP and KV compression off |
| Answer limit | 4,096 tokens per turn, thinking included (`PiProviderModel.maxTokens`) |

**Measured.** In the 2026-11-01 and 2026-11-02 acceptance runs ([omlx-switch.md](omlx-switch.md#acceptance-2026-11-01)):
generation 12.6–18.4 tokens/s, the ETF task 232–262 s, the mail-totals task out of answer length while adding up in
its head. On the M6 Mac mini the same model generates about 30 tokens/s.

**The prompt cache already works.** The oMLX log on the Mac mini (2026-11-02) has 11 cache restores: 32,129 of 35,998
prompt tokens came from the cache, so each turn only reads what is new. What stays slow is the first read of a large
tool result.

**oMLX refuses to load when memory is short.** The same log has eight refusals on a 24 GB Mac with other apps open:
`507: Model 'ornith-1.5-9b-mlx-4bit' (4.93GB) does not fit under the dynamic memory ceiling (4.69GB). Close other apps
to free RAM`. Pippa has no plain-language handling for this answer yet. It will hit 16 GB Macs more often.

**Nothing for developers on the user's Mac.** The runtime brings its own Python, and serving needs neither Xcode nor
the Command Line Tools. oMLX 0.7.3 calls `/usr/bin/python3` and `git` only in its cluster mode (two Macs), which Pippa
does not use. Checked by reading the code, not yet on a Mac without the Command Line Tools.

## Engines

| Engine | Latest (date) | Verdict for Pippa | Basis |
|---|---|---|---|
| **oMLX** (Apache-2.0) | 0.7.3 (2026-10-31); 0.7.4.dev1 (2026-11-04) | **Keep.** Add the kernels | Checked |
| Ollama (MIT, Go) | MLX is the default on Apple silicon since 0.40.0 (2026-09-25); 0.40.15 (2026-11-03) | Plan B. One binary, bundling allowed. No SSD prompt cache, so long conversations are read again after an unload | Checked |
| llama.cpp (MIT) | v0.9.0 (2026-11-04) | Plan B. Pippa measured Qwen 3.5 9B at 146–167 tokens/s reading on an M3, about the same as MLX there | Checked |
| mlx-lm server (MIT) | 0.32.2 (2026-10-16) | No. oMLX builds on it and adds the SSD cache, tool-call repair and memory guards | Checked |
| vllm-mlx | 0.6.0 (2026-10-20) | No. oMLX began as a fork of it; still Python, pinned to `mlx-lm <0.32` | Checked |
| LM Studio | — | **Cannot be bundled.** Its [app terms](https://lmstudio.ai/app-terms) forbid redistribution. Pippa could only talk to a copy the user installed | Checked |
| Splash | 1.6.0 | Not now. Needs M3 or newer and macOS 26.4+, and serves only large models (27B and up) | Checked |
| mlx-serve (MIT, Zig) | v26.11.2 | Not now. One main maintainer, no SSD cache | Checked |
| MLX Swift | 0.33.0 (2026-10-27) | Not now. Its Metal shaders need Xcode on the build machine, and Pippa would have to rebuild the server, cache and tool-call parsing oMLX already has | Checked |
| Apple Foundation Models | macOS 26+ | Helper only (see below) | Checked on the Mac mini |

**oMLX since 0.7.3.** 0.7.4.dev1 sends parallel tool results to the chat template in call order, so Qwen-based models
no longer pair a result with the wrong call (#5012). That matters for Pippa once it is in a stable release. Its
"agent conversations reuse the prompt cache across tool turns" entry (#5062) is listed under **Cluster** and concerns
two-Mac setups only. 0.7.3 itself ends a `max_tokens` cut inside a tool call with `length` and returns
`incomplete_tool_call` for an unclosed one, both useful for Pippa's error messages.

## Models

Agent scores from the vendor cards (reported, not reproduced). MCP-Atlas, Toolathlon and ClawEval measure tool use over
many steps.

| Model | Size at 4-bit | Agent scores | For Pippa |
|---|---|---|---|
| **Ornith 1.5 9B** (MIT) | 5.06 GB | MCP-Atlas 54.2, Toolathlon 41.2, ClawEval 66.5 (Qwen 3.5 9B: 46.8 / 29.6 / 53.2) | Today's model, 16 GB and up |
| **Ornith 1.5 35B-A3B** (MIT) | 19.51 GB | MCP-Atlas 70.2, Toolathlon 48.7, ClawEval 72.5 (Qwen 3.6 35B-A3B: 62.8 / 41.7 / 68.7) | 32 GB and up |
| Gemma 4 26B-A4B / 31B (Apache-2.0) | 15.34 GB (26B-A4B) | τ²: 68.2 / 76.9 | No German or Pippa evidence; Gemma 4 12B reads at half the 9B's speed or less |
| Qwen 3.8 27B (dense, Apache-2.0) | 16.05 GB | — | Dense 27B reads about 3× slower than the 9B |
| K2 Horizon 7B | — | BFCL v4 67.0 | English only on its card; lost to Qwen on Pippa's own tasks (2026-10-23) |

German quality: no current German leaderboard covers these models. Pippa's own blind rating (Qwen 3.5 9B: 3.83 of 5)
is still the best evidence, and the 35B needs the same rating before it ships.

**Faster builds of the 9B.** `mlx-works/Ornith-1.5-9B-oQ4e-mtp` (5.6 GB) keeps the MTP layer (grafted from Qwen 3.5 9B)
and uses oMLX's mixed-precision oQ format. Its card reports 25.4 → 33.8 tokens/s with oMLX's Lightning MTP, measured
on an M5 MacBook Air with thinking off and a 4-bit KV cache. It is a third-party build with a different chat template
and no license field, so it is a candidate to measure, not a drop-in. Ornith also publishes a DFlash draft model for
the 9B.

**Speed by chip** ([oMLX community benchmarks](https://omlx.ai/benchmarks/performance), user-submitted, 4-bit, 16K
context; reported):

| Model | Chip | Reading (tokens/s) | Writing (tokens/s) |
|---|---|---|---|
| Qwen 3.5 9B | M1 | 75–84 | 8–15 |
| Qwen 3.5 9B | M3 | 92–188 | 7–17 |
| Qwen 3.5 9B | M4 | 197–231 | 16–20 |
| Qwen 3.5 9B | M5 | 384–1,089 | 13–25 |
| Qwen 3.5 9B | M6 | 1,000–1,603 | 26–29 |
| Ornith 1.5 9B | M4 | 177–314 | 18–28 |
| Qwen 3.6 35B-A3B | M4, 32 GB | 182–418 | 18–42 |
| Gemma 4 26B-A4B | M4 | 238–359 | 19–29 |

At 75–230 tokens/s, a 23K-token tool result takes 100–300 s on M1–M4 before the first word of the answer. On M5 and
M6 it takes 15–60 s.

## Techniques

| Technique | What it speeds up | Verdict |
|---|---|---|
| Prompt cache across turns | Every turn after the first | **Already on** and working (see above) |
| Native kernels | Reading and writing for Qwen 3.5 models; prerequisite for ANE prefill | **Do it.** Gain unmeasured; on M5 and newer one kernel is skipped anyway because MLX's own attention is faster there |
| ANE prefill (Neural Engine shares the reading work) | Reading | Later. Experimental, per Mac, needs a tuning run and the native kernels. oMLX measured +22.7 % to +26.3 % on an M3 Ultra (0.6.3 notes) |
| Smaller tool results | Reading | **Do it.** The biggest lever on M1–M4 |
| MTP or DFlash draft | Writing only, about 1.3–1.8× in community rows | Measure. Needs an MTP build or the DFlash draft; reading is unchanged |
| SpecPrefill | Reading | **No.** It drops 50–90 % of prompt tokens, which conflicts with quoting sources |
| KV compression (Affine4/8, TurboQuant) | Memory, not time | Not needed. Ornith has only 8 full-attention layers, so the saving is small |
| Higher answer limit or a thinking budget | Fewer answers cut off | **Do it.** 4,096 tokens including thinking ran out on the mail-totals task. A totals tool helps more than a bigger limit |

## Apple Foundation Models

Probed on the Mac mini with a 20-line Swift program built with the Command Line Tools:

```swift
let model = SystemLanguageModel.default
print(model.availability)                                   // available
print(model.contextSize)                                     // 8192 (macOS 26.4+)
print(model.supportsLocale(Locale(identifier: "de_DE")))     // true
```

| Task | Time | Result |
|---|---|---|
| German conversation titles | 0.22–0.73 s | Good: "Frist für Widerspruch", "Terminänderung Dienstag" |
| Sorting a request into one of a few kinds | 0.18–0.19 s | Correct |
| Same, for a health-insurance question | — | **Refused** as "may contain sensitive content" |
| Deadline from a letter | 0.61 s | Quoted the rule instead of computing the date |

- Builds without Xcode as long as Pippa avoids the `@Generable` macro; dynamic schemas work.
- Apple's larger server model (Private Cloud Compute, 32K context) reports "available" but refuses an app without
  Apple's entitlement. Whether apps outside the App Store can get it is unclear.
- One run per prompt, so a thin sample. Good enough for titles and short sorting jobs on every Mac Pippa supports,
  where Apple Intelligence is on, with the local or online AI as fallback when it refuses.

## Recommendation by memory

| Memory | Recommendation |
|---|---|
| 8 GB | The agent runs on an online AI. Where Apple Intelligence is on, Apple's model can do titles and small jobs offline |
| 16 GB | Ornith 1.5 9B at 16K, with kernels. Handle the 507 refusal in plain language ("close an app and try again") |
| 24 GB | Ornith 1.5 9B at 32K, with kernels. Then measure MTP or DFlash for faster writing. The 35B does not fit beside a working Mac; Pippa recorded swapping with it on 2026-10-31 |
| 32–48 GB | Ornith 1.5 35B-A3B 4-bit, after Pippa's task gate passes on a 32 GB Mac |
| 64 GB and up | Ornith 1.5 35B-A3B 8-bit |

None of these models fix the two known answer errors: a computed deadline date and sums added up in the model's head.
Both need code (a date check and a totals tool), not a different model.

## How to measure

Use a Mac without other model servers running (check `ps aux | grep -E "omlx|llama-server"`), with Safari, Mail and
Pages open as in the release gate. Record chip, `sysctl vm.swapusage` and `memory_pressure`.

1. **Kernels.** Build the runtime twice on the macOS 26 runner, once as today and once with
   `OMLX_WITH_CUSTOM_KERNEL=1`. Check with
   `<runtime>/bin/python3 -I -c "from omlx.custom_kernels import native_kernel_status as s; print(s())"`. Send fixed
   4K, 16K and 23K-token prompts (a real PDF tool result) to `/v1/chat/completions` with `max_tokens: 1` and the header
   `X-oMLX-Cache-Store: off`, five times each. Compare reading speed and time to first token from the
   `Chat completion … prompt:` lines in `server.log`.
2. **Faster writing.** With the server stopped, enable DFlash in `<Support>/omlx/model_settings.json` with Ornith's
   draft model, or switch to an MTP build. Run the ten model-compare tasks with Pippa's sampling. Compare writing speed,
   draft acceptance and whether answers change.
3. **Whole tasks.** The ten model-compare tasks × 3 rounds plus the five acceptance tasks through `Pippa --ask`, graded
   with the existing rubric: pass/partial/fail, median and p90 time, cache hit ratio, answers cut off, incomplete tool
   calls, peak memory and swap growth. Passing means at least 16 yes of 30, swap grows by at most 256 MiB, and the
   median time is no worse than today. Repeat on a 32 GB Mac for the 35B.
4. **Apple's model.** 50 German and 50 English titles and sorting jobs: p50 and p95 time, refusal rate, German quality
   graded 1–5 by hand.

## Corrections from cross-checking

- One pass read oMLX #5062 as the cause of Pippa's slow multi-step tasks. The 0.7.4.dev1 notes list it under
  **Cluster** (two-Mac setups); single-Mac prompt reuse already worked in Pippa's log.
- One pass gave Apple's on-device model a 4,096-token context. On macOS 27 `contextSize` reports 8,192.
- One pass dated Ollama's MLX default to 0.35.0. The 0.40.0 notes (2026-09-25) are where it became the default.
- One pass gave Pippa's idle unload as six hours. Pippa writes 600 s (`PiLocalServer.idleUnloadSeconds`).
- One pass credited oMLX 0.7.2 with +13 % / +57 % ANE prefill on M1–M4. No release note says so; the measured gain in
  the notes is +22.7 % to +26.3 % on an M3 Ultra (0.6.3).
- The oQ4e-mtp speed figures are real but come from an M5 with thinking off; they do not carry over to M1–M4 or to
  Pippa's settings.

## Sources

Read 2026-11-09 unless noted.

- oMLX: [releases](https://github.com/jundot/omlx/releases) (0.6.3, 0.7.1, 0.7.3 of 2026-10-31, 0.7.4.dev1 of
  2026-11-04), [README](https://github.com/jundot/omlx) (native kernels), [community benchmarks](https://omlx.ai/benchmarks/performance)
- Models: [Ornith-1.5-9B-MLX-4bit](https://huggingface.co/ornith-ai/Ornith-1.5-9B-MLX-4bit),
  [Ornith-1.5-35B-A3B](https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B),
  [Ornith-1.5-9B-oQ4e-mtp](https://huggingface.co/mlx-works/Ornith-1.5-9B-oQ4e-mtp)
- Engines: [Ollama releases](https://github.com/ollama/ollama/releases), [llama.cpp releases](https://github.com/ggml-org/llama.cpp/releases),
  [mlx-lm releases](https://github.com/ml-explore/mlx-lm/releases), [vllm-mlx releases](https://github.com/waybarrios/vllm-mlx/releases),
  [LM Studio app terms](https://lmstudio.ai/app-terms), [Splash](https://github.com/incoai/splash),
  [mlx-serve](https://github.com/ddalcu/mlx-serve), [MLX Swift](https://github.com/ml-explore/mlx-swift/releases)
- Apple: [Foundation Models](https://developer.apple.com/documentation/foundationmodels), WWDC26 session
  [241](https://developer.apple.com/videos/play/wwdc2026/241/) (Private Cloud Compute model)
- Pippa: [omlx-switch.md](omlx-switch.md) (acceptance 2026-11-01/02),
  [24gb-tier-9b-2026-10-31.md](archive/measurements/24gb-tier-9b-2026-10-31.md),
  [model-compare](archive/measurements/model-compare/README.md); oMLX `server.log` and `settings.json` on the Mac mini
