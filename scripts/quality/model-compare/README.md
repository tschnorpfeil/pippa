# Model comparison K2 Horizon 7B vs. Qwen3.5-9B (harness)

Results and method notes: `docs/rebuild/measurements/model-compare/README.md`.

| File | What |
|---|---|
| `variants.mjs` | Variants A/B/C: server arguments (as `LlamaServer.arguments`), models.json entry (as `PiReasoningStyle.modelFields`), Pi settings (as `PiModelTuning.merge`), ctx 32768 |
| `server.mjs` | One llama-server per block; waits while another llama-server runs or load ≥ 10; RSS/footprint sampling |
| `make-agentic-corpus.swift` | 20 invented PDFs in `dist/model-compare-home` (fake HOME, Spotlight-indexed) |
| `tasks.mjs` | Ten agentic tasks: prompt, mock mail/web data, automatic first-pass rubric |
| `agentic.mjs` | Full Pi dialogues over RPC with Pippa's prompt, tools, skills, guard, MCP extension; MCP mock; timings |
| `agentic-isolation.ts` | Pi extension: tools only inside the fake HOME and the bundled skills |
| `run-all.mjs` | Rounds × variants interleaved; per block agentic 10, file search 6, tool choice 25 (`../tool-choice.mjs` with `PIPPA_MC_VARIANT`) |
| `r7.sh` | r7 latency (18 answers) per variant on the app's own server path (`PiRPCR2Spike r7 latency`) |
| `summarize.mjs` | Median/range per variant, decision rule, blind answer sheet |
| `one.mjs` | One variant, chosen tasks (smoke tests) |

```sh
H=$PWD/dist/model-compare-home; mkdir -p $H; HOME=$H CFFIXED_USER_HOME=$H swift scripts/quality/model-compare/make-agentic-corpus.swift
S=$PWD/dist/sf/pippa/dist/tool-search-home; mkdir -p $S; HOME=$S CFFIXED_USER_HOME=$S swift scripts/quality/make-search-corpus.swift
python3 scripts/quality/mcp-schema.py > .build/mcp-tools.json
CFFIXED_USER_HOME=$H PIPPA_MC_SEARCH_HOME=$S PIPPA_MC_LLAMA=<patched llama-server> \
  .build/pi-payload/bin/node scripts/quality/model-compare/run-all.mjs docs/rebuild/measurements/model-compare/raw 3 ABC
swift scripts/quality/make-ctxsug-corpus.swift .build/quality/ctxsug-corpus   # r7 cases
PIPPA_MC_LLAMA=<patched llama-server> scripts/quality/model-compare/r7.sh A docs/rebuild/measurements/model-compare/raw/r7-a.log
.build/pi-payload/bin/node scripts/quality/model-compare/summarize.mjs docs/rebuild/measurements/model-compare
```

Models are read from `~/pi-bench-models` (`PIPPA_MC_MODELS`), SHA256 equal to the catalog pins.
