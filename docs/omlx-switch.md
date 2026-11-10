# Local AI: oMLX and Ornith 1.5 9B instead of llama.cpp

Decided 2026-11-01. Pippa's AI on this Mac becomes one engine and one model: [oMLX](https://github.com/jundot/omlx)
(MLX, Apple silicon) serving `ornith-ai/Ornith-1.5-9B-MLX-4bit`. llama.cpp, GGUF and the model table by memory size go.
Pi stays the harness; Pippa still only talks to Pi, and Pi talks to the server as provider `pippa-local`.

## Shape

- **Runtime, downloaded at setup** (not in Pippa.app): a relocatable Python 3.11 (python-build-standalone) with oMLX and
  its pinned dependencies, built by `scripts/build-mlx-runtime.sh` into one archive and published as a release asset.
  `app/Sources/PippaCore/Resources/mlx-runtime.json` names its version, URL, size and SHA-256. Setup downloads it with the
  model, checks the hash and unpacks it to `<Support>/mlx-runtime/<version>/`. `PIPPA_MLX_RUNTIME_ARCHIVE` points at a
  local archive for development.
- **Model, downloaded at setup**: the Hugging Face files of one pinned revision, each with size and SHA-256, into
  `<Support>/omlx/models/ornith-1.5-9b-mlx-4bit/`. The folder name is the model id oMLX serves and Pi asks for. A copy
  already in `~/.omlx/models` or the Hugging Face cache is cloned (APFS, no extra space) instead of downloaded.
- **Server**: `<runtime>/bin/python3 -c "from omlx.cli import main; main()" serve --base-path <Support>/omlx --headless`.
  Pippa writes `<Support>/omlx/settings.json` (0600): 127.0.0.1, the stable port, the API key, model idle timeout.
  oMLX unloads the model by itself after the idle timeout, so Pippa no longer stops the process when idle and no longer
  saves prompt slots; oMLX keeps its own prefix cache on disk (`<Support>/omlx/cache`).
- **Prewarm while typing**: editing a nonempty prompt starts the local server if necessary and calls the authenticated
  `POST /v1/models/{model_id}/load` endpoint, which returns after the weights load into RAM. Opening chat alone does
  not preload. Online AI and incomplete setup skip this work. Concurrent edits share one task, with at most one
  attempt per 30 seconds; later edits can reload an idle-unloaded model. The draft is never sent and no answer is
  generated. This hides model loading behind typing; prompt evaluation and generation still happen on Send.
- **One server for the app and the terminal**: the lock file stays. The app starts the server on demand and stops it on
  quit if it started it. Pi in the terminal (extension `runtime/pippa-local-server`) starts it from the launch file
  `<Support>/pippa-local-server.json` when the app does not run.
- **Which Macs**: Apple silicon with 16 GB or more. Context 32K from 24 GB, 16K on 16 GB. Smaller Macs use an online AI.

## Removed

`LlamaServer`, `llama-release.json`, llama-server in the app bundle and its checks, slot save/restore, the model table
by memory size and "Gründlicher", GGUF catalog entries, adopting GGUF files from LM Studio and Ollama, llama-specific
tuning flags.

## Tasks

- [x] Runtime builder script, lock file, local archive; manifest
- [x] PippaCore: catalog with one MLX model; selector reduced to "fits / does not fit"
- [x] PippaCore: runtime download and install next to the model download
- [x] PippaCore: `OMLXServer` replaces `LlamaServer`; launch file v2; models.json provider
- [x] Terminal extension on the launch file v2
- [x] App: PiSession, setup card and settings texts
- [x] Remove llama code, bundle steps, checks, scripts; docs
- [x] Build, verify; setup adopts Ornith from `~/.omlx` by APFS clone; ETF question answered from `ETF-Portfolio.md` (270 s, 13.7 tok/s while a second oMLX held the same model)
- [x] Acceptance runs with Ornith alone in memory (2026-11-01, headless `--ask`, see below): 2 of 5 pass
- [x] Date warning: Ornith computes a date from "four weeks after receipt" (three runs, 13, 17 and 19 November).
  `DateEvidence` added a warning below the answer for dates absent from the sources. Rerun: one answer without a
  date, one with 19 November, which the note named. This did not fix the deadline answer. The rule written in
  `persona.md` was not loaded by the running system prompt; see the correction below.
- [ ] Mail totals: finds both mails (plural retry) and reads both PDFs, then thinks past the 4,096-token answer limit
  adding up two large tables in its head (650–750 s) instead of using awk. The app now says so instead of ending
  quietly; the task itself stays beyond this model
- [ ] Calendar: `calendar_read` hangs in the headless run of the re-signed build (likely an unanswered permission prompt)
- [x] Fresh setup in an empty home (`PIPPA_PI_HOME`, Developer ID build with Hardened Runtime): Pi installed, runtime
  unpacked and checked, model checked, own server on a new port, first answer 31 s cold. The model download itself
  could not be tried: huggingface.co resets the TLS handshake on this network (2026-11-02)
- [x] Publish the runtime archive as a release asset (`mlx-runtime-0.7.3-1`, 2026-11-02)

## Acceptance, 2026-11-01

Ornith alone in memory, M-series Mac, headless `Pippa --ask`, each run starting the server cold.

| Task | Result | Time |
| --- | --- | --- |
| ETF overview in brain | Pass: `ETF-Portfolio.md`, snapshots named as history | 262 s |
| Letter "Until when…" | Fail: payment date quoted right, but an objection date computed (wrong, three different values); also offered to make the transfer | 55–132 s |
| Five photos → one PDF (model) | Pass: one PDF; the answer names an internal folder ("DurableJobs") | 57 s |
| Mail attachments → totals | Fail: found two of three mails, read both PDFs, no answer within 600 s | >600 s |
| Dentist Tuesday 10:00 | Blocked: `calendar_read` did not return | >600 s |

Generation 12.6–18.4 tok/s; prefill dominates once tool results land (prompt up to 23K tokens).
Fixed on the way: the server log was emptied on every start. Correction, 2026-11-10: the deadline and capability
rules added to `persona.md` were not loaded by `PippaPiLaunch.systemPrompt`. Editing that file did not change the
running prompt. The manually invoked deadline skill has its own rule; ordinary chat does not invoke it automatically.

Comparison on the letter deadline, same build: `mlx-community/Qwen3.5-9B-MLX-4bit` (revision 938d891) on
the same oMLX also computes an objection date in three of three runs (19, 17 and 27 November), at 8.8–13.4 tok/s, and
once failed to open the PDF (249 s). The earlier Qwen pass on llama.cpp was not reproducible. Switching back to Qwen does
not fix it; Ornith stays.

### Second round, 2026-11-02 (sampling 0.6 / top-k 20)

| Task | Result | Time |
| --- | --- | --- |
| Letter, two runs | Payment date right; objection date computed (20 and 17 November) and named by the date note both times; no stray words | 54 s, 157 s |
| ETF overview | Pass, clean German | 232 s |
| Mail totals | Fail: out of answer length while adding up in its head | 647–754 s |
