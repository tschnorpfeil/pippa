# Model comparison K2 Horizon 7B vs. Qwen3.5-9B (harness)

Results and method notes: `docs/measurements/model-compare/README.md`.

| File | What |
|---|---|
| `variants.mjs` | Variants A/B/C, plus S (B's model and sampling on stock Pi: no Pippa prompt, extensions, skills or tool list): server arguments (as `LlamaServer.arguments`), models.json entry (as `PiReasoningStyle.modelFields`), Pi settings (as `PiModelTuning.merge`), ctx 32768 |
| `server.mjs` | One llama-server per block; waits while another llama-server runs or load ≥ 10; RSS/footprint sampling |
| `make-agentic-corpus.swift` | 20 invented PDFs in `dist/model-compare-home` (fake HOME, Spotlight-indexed) |
| `tasks.mjs` | Ten agentic tasks: prompt, mock mail/web data, automatic first-pass rubric |
| `agentic.mjs` | Full Pi dialogues over RPC with Pippa's prompt, tools, skills, assist and MCP extensions; MCP mock; timings |
| `agentic-isolation.ts` | Pi extension: tools only inside the fake HOME and the bundled skills |
| `run-all.mjs` | Rounds × variants interleaved; per block agentic 10, file search 6, tool choice 25 (`../tool-choice.mjs` with `PIPPA_MC_VARIANT`) |
| `summarize.mjs` | Median/range per variant, decision rule, blind answer sheet |
| `one.mjs` | One variant, chosen tasks (smoke tests) |
| `run-subset.mjs` | Agentic tasks only: chosen variants and task ids, rounds interleaved, waits for a quiet Mac |

```sh
H=$PWD/dist/model-compare-home; mkdir -p $H; HOME=$H CFFIXED_USER_HOME=$H swift scripts/quality/model-compare/make-agentic-corpus.swift
S=$PWD/dist/sf/pippa/dist/tool-search-home; mkdir -p $S; HOME=$S CFFIXED_USER_HOME=$S swift scripts/quality/make-search-corpus.swift
python3 scripts/quality/mcp-schema.py > .build/mcp-tools.json
CFFIXED_USER_HOME=$H PIPPA_MC_SEARCH_HOME=$S PIPPA_MC_LLAMA=<patched llama-server> \
  .build/pi-payload/bin/node scripts/quality/model-compare/run-all.mjs docs/measurements/model-compare/raw 3 ABC
.build/pi-payload/bin/node scripts/quality/model-compare/summarize.mjs docs/measurements/model-compare
```

Models are read from `~/pi-bench-models` (`PIPPA_MC_MODELS`), SHA256 equal to the catalog pins.

## Installed oMLX versus current Pippa

`run-omlx.mjs` runs the same ten tasks against two oMLX effort levels and a local Qwen server. It rotates
`LMQ`, `MQL`, `QLM`, preloads models before timing, and unloads oMLX before starting Qwen. Completed blocks can
be resumed; quarantine infrastructure failures before retrying. It never clears the user's inference cache. Its changing system-message prefix does not prevent reuse of a shared
chat-template/tool prefix; inspect captured usage before interpreting cold-cache performance.

Required environment:

- `PIPPA_MC_VARIANTS_FILE`: JSON with `L`, `M`, `Q` entries in the format recorded in the result metadata.
- `PIPPA_MC_LLAMA`: the pinned llama-server executable.
- `PIPPA_MC_PAYLOAD`: the current pinned Pi payload (with `bin/node` and `release/`).
- `PIPPA_MC_API_KEY_FILE`: existing local oMLX credential file. The proxy reads it in memory; it is not passed to
  the model or written into request captures. The benchmark's llama-server does not inherit `LLAMA_API_KEY`.
- `PIPPA_MC_WEB_SCHEMA`: JSON containing the current `DECLARATIONS` from `runtime/pippa-web/index.ts`.
- Optional `PIPPA_MC_OMLX`: server origin (default `http://127.0.0.1:8012`).
- Optional `PIPPA_MC_TIMEOUT`: per-task limit in milliseconds (default 180000).

Generate the PDF corpus and native tool declarations as above, then run:

```sh
"$PIPPA_MC_PAYLOAD/bin/node" scripts/quality/model-compare/run-omlx.mjs <result-dir>/raw 3
```

The harness now uses the current Pippa extension set and offers deterministic web tools with current names and
declarations when `PIPPA_MC_WEB_SCHEMA` is set. `agentic.mjs` saves first-request payloads, streaming usage and
Pi events alongside each answer. Model-visible requests use a shared 4096-token output budget in the recorded
October 23 comparison. Review every answer and action into `grades.json` before running
`summarize-omlx.py <result-dir>`; automatic keyword grades are insufficient for fabricated facts or false action
claims. The summary requires all 90 runs unless `--partial` is explicitly supplied.

`PIPPA_MC_OMIT_CACHE_TAG=1` is only for a separate prompt-sensitivity check: it omits the cache-busting prefix.
Those runs may reuse existing cached prompts and must not be pooled with the controlled timing matrix.

See `docs/measurements/omlx-compare-2026-10-23/protocol.md` for the exact setup, rubric and limitations.

## Pippa prompt and declaration regression comparison

`PIPPA_MC_TOOL_SCOPE=off` disables the declaration filter and removes its expansion tool for a baseline run.
`PIPPA_MC_PROMPT_BASELINE=1` can strip the two experimental date/source-qualification sentences from the
October 24 candidate. Those sentences were rejected and are absent from the final production prompt. For
current declaration-only comparisons, vary `PIPPA_MC_TOOL_SCOPE` with identical model, effort, fixtures and
output limit.
First-request payloads are saved as soon as they arrive; each request records its tool count. Inspect these
payloads before accepting a run as a test of narrowed declarations: MCP registration order can otherwise
invalidate the intended comparison. Do not combine interrupted or misconfigured attempts with accepted runs.
