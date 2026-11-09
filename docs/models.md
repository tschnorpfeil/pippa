# Pippa's local AI

Pippa has no model picker. Her AI on your Mac is one model, **Ornith 1.5 9B** in MLX 4-bit
([`ornith-ai/Ornith-1.5-9B-MLX-4bit`](https://huggingface.co/ornith-ai/Ornith-1.5-9B-MLX-4bit)), served by
[oMLX](https://github.com/jundot/omlx). She tells you the download size and asks before downloading. With an online AI
switched on, she works without that download.

The [README](../README.md#will-it-run-on-my-mac) has the short version.

## Which Macs

| Mac | Local AI | Context | Thinking |
|---|---|---|---|
| Apple silicon, 24 GB or more | Ornith 1.5 9B | 32K tokens | Medium |
| Apple silicon, 16 or 18 GB | Ornith 1.5 9B | 16K tokens | Medium |
| Less than 16 GB | None; use an online AI | | |

The download is about 5.4 GB: the model (5.06 GB) and a Python runtime with oMLX (0.35 GB). Sizes are decimal
gigabytes. While answering, the model needs about 6.5 GB of memory; oMLX unloads it by itself when Pippa has been idle
for a while.

## Why this model and engine

- **One model.** The old table by memory meant three models to tune and test. One model that fits every supported Mac
  is one thing to test and one thing to fix.
- **Ornith 1.5 9B** is built on Qwen 3.5 9B, the model Pippa used before on 16 and 24 GB. In Pi it runs at 25 to
  30 tokens per second on a 24 GB Mac and leaves the Mac usable.
- **oMLX instead of llama.cpp.** MLX is built for Apple silicon; oMLX serves an OpenAI-compatible API, keeps its own
  prompt cache on disk and unloads the model when idle. Pippa no longer builds or bundles an engine of her own.

The decision and what it removed: [Local AI: oMLX and Ornith 1.5 9B](omlx-switch.md). Other engines, models and
speed-ups compared, with a plan by memory size: [research, November 2026](local-ai-research-2026-11.md).

These are small tests, not quality guarantees. Local AI can miss details or get facts wrong; check important names,
amounts and dates against the original.

## Where the files go

Everything lives in `~/Library/Application Support/Pippa`:

| What | Folder |
|---|---|
| Model files (one pinned revision, each file with size and SHA-256) | `omlx/models/ornith-1.5-9b-mlx-4bit/` |
| oMLX settings (loopback only, fixed port, key) and its prompt cache | `omlx/settings.json`, `omlx/cache/` |
| Python runtime with oMLX (pinned archive, SHA-256 checked) | `mlx-runtime/<version>/` |

The model comes from Hugging Face, the runtime from Pippa's GitHub releases. Downloads resume and are verified before
use. If the same model is already on your Mac from oMLX (`~/.omlx/models`), LM Studio (`~/.lmstudio/models`) or the
Hugging Face cache (`~/.cache/huggingface/hub`), Pippa checks each file's SHA-256 and clones it (APFS, no extra space)
instead of downloading it. The other app's files are left as they are.

The server listens only on 127.0.0.1. Pippa starts it when needed; `pi` in the terminal starts the same server through
Pippa's extension when the app is not running.

## Changing the model

For developers:

1. Put the new entry in [`catalog.json`](../app/Sources/PippaCore/Resources/catalog.json) (key, label, repo, context,
   thinking, memory). The key is the folder name and the model id that oMLX serves and Pi asks for.
2. Pin it: `scripts/pin-model.sh <key> <hf-repo>` writes the revision and each file's size and SHA-256.
   `build-app.sh` refuses a model that is not pinned (`scripts/check-default-models.py`).
3. Check the memory floor and context in `ModelSelector` ([`Models.swift`](../app/Sources/PippaCore/Models.swift)) and
   the thinking switch in `PiModelTuning`.
4. A new oMLX version means a new runtime archive with oMLX's native kernels: push to a `ci/mlx-runtime-*` branch (or
   start `.github/workflows/mlx-runtime.yml` by hand), check the run's kernel and minimum-macOS steps, publish the
   artifact as the `mlx-runtime-<version>` pre-release, then copy its manifest to
   [`mlx-runtime.json`](../app/Sources/PippaCore/Resources/mlx-runtime.json). `scripts/build-mlx-runtime.sh` alone
   builds without kernels on a Mac without Xcode, for local checks only, and leaves `mlx-runtime.json` as it is.

## Online AI instead

If you prefer, Pippa can work with an online AI: sign in with your ChatGPT subscription, or add your own OpenAI or
Anthropic key in Settings. While it's on, your conversations and what Pippa reads for them go to that service. See
[Privacy and permissions](privacy-and-permissions.md#online-ai-only-if-you-switch-it-on).
