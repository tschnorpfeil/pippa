# K2/oMLX versus Pippa Qwen on this Mac

Measured on 23–24 October 2026: Apple M6, 24 GiB unified memory, macOS 27.0.1. Ten Pippa tasks × three repeats × three configurations = **90 scored attempts**. These are local measurements, not published model benchmarks.

**K2 feels more responsive because visible text arrives earlier. Qwen completed more tasks correctly.** K2-medium improved substantially over low in useful task completion, but took longer than Qwen. Measured generation throughput was close across all three configurations.

## Results

| Metric | K2/oMLX low | K2/oMLX medium | Current Qwen |
|---|---:|---:|---:|
| Median first visible answer text | **3.2 s** | **4.5 s** | 15.6 s |
| Median total task time, including failures | 16.1 s | 48.0 s | 26.3 s |
| Reported generation throughput | 20.9 tokens/s | 20.8 tokens/s | 20.4 tokens/s |
| Fully correct | 3/30 | 7/30 | **14/30** |
| Partially useful | 11/30 | 16/30 | 9/30 |
| Failed | 16/30 | 7/30 | 7/30 |
| Attempts with factual errors | 16/30 | 18/30 | 12/30 |
| Total time across 30 attempts | 14.9 min | 33.0 min | 17.0 min |

First visible text includes progress statements such as “I’ll look at the files.” It is not time to a correct or useful answer. Low's short total time includes seven runs without any tool call, premature finishes, and one 180-second timeout. All 90 scored attempts had successful HTTP transport; none stopped at the output-token limit.

“Fully correct” uses a strict grounded-answer review. Partial answers can be quite useful: for example, a correct calculation with an incorrect service description, a correct summary with an invented cancellation deadline, or a good mail draft saved as a new message instead of a reply. Factual-error counts are not severity-weighted. They include secondary inaccuracies as well as wrong central totals and false completion claims. Every judgment and explanation is available in [grades.json](grades.json).

Generation speed is weighted reported output tokens divided by generation time, from oMLX usage and llama.cpp logs. The engines have different timing definitions and the models have different tokenizers. Unfinished oMLX requests without final usage are excluded from throughput, but included in task time and quality. A roughly 2–3% throughput difference here does not establish an engine advantage.

## What happened on the same tasks

- **Lease comparison:** K2-medium and Qwen were correct in all three repeats. Their median completion times were **67.4 s versus 37.9 s**. K2-low promised an answer without doing the work, timed out, and then produced a correct comparison accompanied by an unrequested failed PDF edit.
- **Create a reminder from a letter:** K2-low succeeded twice in **9.8 s and 16.0 s**, then emitted tool-call JSON as text without creating the reminder. Qwen succeeded three times in **17.8–25.1 s**. K2-medium succeeded twice; once it claimed completion after only reading the document.
- **Invoice total:** K2-medium alone reached the expected **EUR 865.30** twice, both on the English task. One of those answers also mistranslated hallway painting as garden painting, so received partial credit. Most other runs included the annual service-charge statement or missed German-named invoices. The rubric's invoice/statement distinction is fixed but the natural-language request has some ambiguity; this is not a general arithmetic benchmark.
- **Mail replies:** All models had some routing or completion problems. A correct body does not establish that the requested reply draft was saved. The legacy mock overstates thread placement, so review used tool arguments rather than trusting that receipt.
- **Summaries:** Main dates were often correct. Added cancellation dates and stronger-than-source furniture instructions caused many partial grades. The source says furniture need not be dismantled; “need not be moved” was penalized consistently for both models.

K2-low attempted two unrelated file edits. One targeted a path outside the fixture and was blocked; the other targeted the synthetic lease and failed to match its text. **All 20 fixture PDFs remained unchanged.** Native mail/calendar/reminder actions used mocks, so no personal app data was changed.

Even excluding both web tasks, the fully correct / partial / failed counts were **3/9/12 for low, 7/12/5 for medium, and 11/6/7 for Qwen**, each out of 24. Qwen's lead in fully correct outcomes is therefore not solely a web-fixture effect. Medium and Qwen were equally likely to produce at least a partially useful result in the complete set: 23/30 each.

## Exactly what was compared

| Component | K2 arms | Qwen arm |
|---|---|---|
| Model | Installed `SirSahOl/K2-Horizon-7B-chat-mlx-4bit` | `Qwen3.5-9B-Q4_K_M.gguf` |
| Weights | Affine 4-bit, group 64; 5.06 GB safetensors | 5.68 GB GGUF; catalog hash verified |
| Runtime | oMLX 0.7.0 | Pippa's pinned llama.cpp b11503 |
| Reasoning | Explicit low → low; medium → medium | Saved Pippa medium setting; thinking enabled |
| Sampling | Existing temperature 0.6, top-p 0.95 | Temperature 0.6, top-p 0.95, top-k 20, min-p 0 |
| Context / output cap | 32K / 4,096 per request | 32K / 4,096 per request |

Every arm used **Pi 1.4.0**, the current Pippa prompts, skills and extension set, and the same 23 tool declarations. The model-specific effort controls and output caps were checked in every captured request. The installed K2 conversion is revision `6661f8230d99bf73fa1613bce2ed95895a0fe315`; these results should not be transferred to another K2 quantization.

The tasks were eight German prompts and two English prompts over the same German synthetic corpus: file search, comparison, summarization, insurance overview, web lookup, policy plus web lookup, mail reply and reminder creation. File search used real Spotlight. Document/native-app/web results were deterministic fixtures. Models were loaded before timing and inference was sequential. Block order was low/medium/Qwen, medium/Qwen/low, then Qwen/low/medium. The normal K2 loaded state was restored afterward.

## Limits and checks

- This tests the **complete configured stacks with Pippa's prompt and tools**, not a minimal terminal Pi session or general model intelligence. Three repeats of ten tasks are a small, correlated sample. Review was performed by the same assistant, not an independent blinded human judge.
- The output cap was equalized to Pippa's 4,096 tokens; the user's separate K2 terminal configuration allows 8,192. There were no output-limit stops in the scored runs.
- A model-visible `[Benchmark UUID-arm-round]` line limited reuse of earlier task context. It did not eliminate K2's earlier tool-template prefix: oMLX reported **1,536 cached tokens on each block's first request**, versus zero for the fresh Qwen server. Later tasks could reuse cache. This is not an equal cold-cache comparison. See the separate unmodified-prompt check in the local diagnostic archive; its six runs are not pooled into the table.
- The Mac remained a working desktop, with about 5–6 GiB of swap in use. A thermal spot check reported no recorded warning, which does not prove absence of throttling. Background load and cache state limit precision.
- Web fixtures use `.example` domains. One K2-medium run recognized and rejected them before providing unsupported claims from memory. Those tests measure fixture grounding and tool behavior, not current real-world web accuracy. The fixture fees are not public-service guidance.
- An initial Qwen attempt returned HTTP 401 because an inherited `LLAMA_API_KEY` enabled authentication. Those ten failed requests and the interrupted following block are quarantined under the local `diagnostics/invalid-auth/` archive, excluded from all reported measurements. The isolated server launcher was fixed, and valid completed blocks were retained.

On this evidence, **Qwen remains the stronger Pippa baseline for correctness**. K2-low's responsiveness is real and can be valuable for simpler interactions, but it often fails to finish actions. Medium reduces those failures and sometimes solves tasks Qwen misses, at a substantial time cost. Further prompt/tool-format tuning is a separate experiment; these results do not establish K2's best achievable performance.

## Evidence and reproduction

- [Per-task medians and round grades](summary.md), [all 90 rows](runs.csv), [machine-readable summary](summary.json).
- [Review notes](grades.json), [protocol and rubric](protocol.md), [validation](validation.json).
- [Model details and hashes](model-details.json), [run metadata](metadata.json), [source hashes](source-hashes.json).
- The local `raw/` archive contains initial request payloads, Pi events, final answers, usage and Qwen timing logs. User-specific home/repository paths are replaced by `<home>` / `<repo>` in saved evidence; credentials are not retained.
- Reproduction instructions: [model-comparison harness](../../../scripts/quality/model-compare/README.md). Only benchmark tooling and measurement artifacts were changed; no production model selection or saved tuning was changed.

Raw response streams and diagnostic attempts are retained locally in the validation archive and are not part of this release source. Published summaries and grades describe the measured outcomes.
