# Pippa's local AI

Pippa has no model picker. She chooses one local AI for your Mac from its memory, tells you the download size and
asks before downloading it. Photo and PDF jobs, Tidy Up and the morning overview work before that download.

This page is for the curious. The [README](../README.md#will-it-run-on-my-mac) has the short version.

## Which Mac gets which AI

| Mac memory | AI | File (quantization) | Download | Context | Thinking |
|---|---|---|---|---|---|
| 8 GB | Qwen3.5 4B | Q4_K_M | 2.74 GB | 16K tokens | Off |
| 16 GB or 18 GB | Qwen3.5 9B | Q4_K_M | 5.68 GB | 16K tokens | Medium |
| 24 GB or more | Qwen3.6 35B-A3B (mixture of experts, about 3B active) | UD-Q3_K_XL | 16.85 GB | 32K tokens | Off |

- **Memory classes.** Pippa rounds your Mac's memory to a class: under 12 GB counts as 8 GB, under 20 GB as 16 GB,
  and everything above that gets the 24 GB row.
- **Where the files come from.** The GGUF files come from Unsloth's repositories on Hugging Face
  (`unsloth/Qwen3.5-4B-GGUF`, `unsloth/Qwen3.5-9B-GGUF`, `unsloth/Qwen3.6-35B-A3B-GGUF`). Each one is pinned to a
  revision, a size and a SHA-256 checksum. Downloads can resume and are verified before use.
- **License.** The Qwen models are licensed under Apache 2.0.
- **How they run.** llama.cpp's `llama-server` runs the AI on your Mac, reachable only from your Mac. It is unloaded
  again when idle.
- **Download sizes** are in decimal gigabytes (2.74 GB = 2,740,937,888 bytes). Leave room for the app and your results.

The source of truth is `ModelSelector.table` in
[`app/Sources/PippaCore/Models.swift`](../app/Sources/PippaCore/Models.swift), with sizes and pins in
[`catalog.json`](../app/Sources/PippaCore/Resources/catalog.json).

## Why these choices

- **8 GB:** the 9B needs about 7 GiB of memory, more than Pippa allows herself on an 8 GB Mac (about 4.8 GiB), so
  these Macs get the 4B.
- **16 GB:** Qwen3.5 9B replaced K2 Horizon 7B after a side-by-side test with Pi: more tasks done, fewer invented facts,
  faster answers and better German ([comparison](measurements/model-compare/README.md), in German).
- **24 GB and more:** since 24 October 2026, Qwen3.6 35B-A3B without thinking. In Pippa's ten-task check it passed
  six tasks, as many as Saluki 27B, the model it was compared with, at about half its median task time (34.5 s
  versus 69.9 s; [GGUF follow-up](measurements/qwen-gguf-validation-2026-10-24/README.md)). Medium thinking passed only three, so it
  is not the default.

These are small test suites, not quality guarantees. Local AI can miss details or get facts wrong; check important
names, amounts and dates against the original. The full reasoning is in
[Settings simplification](settings-simplification.md#the-model-is-fixed-by-hardware).

## The hidden "More thorough" option

Macs with 24 GB or more have a second choice, "Standard" or "More thorough", but Settings doesn't show it yet
(`thoroughTested = false` in `Models.swift`). It stays hidden until it passes Pippa's side-by-side test with Pi.

| Option | File | Download | Context | Thinking |
|---|---|---|---|---|
| More thorough (hidden) | Qwen3.6 35B-A3B, UD-IQ3_S | 13.68 GB | 32K tokens | Medium |

- **Designed for the old default.** The option dates from when the 24 GB default was still the 9B (5.7 GB); since the
  24 GB default became the 35B, it would now be the smaller download.
- **Saved choices.** While the option is hidden, a saved "More thorough" choice counts as "Standard".
- **For developers.** The file stays pinned, so developers can still run it with
  `PIPPA_PI_MODEL=qwen3.6-35b-a3b-iq3`.

## Using a file you already have

Before downloading, Pippa looks for the exact same file in other apps' folders:

| App | Folder |
|---|---|
| LM Studio | `~/.lmstudio/models`, `~/.cache/lm-studio/models` |
| Hugging Face | `~/.cache/huggingface/hub` |
| llama.cpp | `~/Library/Caches/llama.cpp` |
| Ollama | `~/.ollama/models/blobs` |
| Jan | `~/Library/Application Support/Jan` |
| GPT4All | `~/Library/Application Support/nomic.ai/GPT4All` |

Only the identical file counts: same size, and the SHA-256 checksum is checked before use. Pippa clones it (APFS),
hard-links it or, as a last resort, copies it into her model folder. The other app's file is left as it is. Other
models or other quantizations of the same model don't count, so Pippa still downloads hers.

Her model folder is `~/models` if that folder already exists (the shared folder Pi suggests), otherwise
`~/Library/Application Support/Pippa/models`.

## Apple Intelligence

Apple Intelligence is optional. On macOS 26, when it is turned on, Pippa uses Apple's on-device model for a few quick
jobs: suggestions for a document, the first line of a letter, short text selections and sorting unclear files while
tidying. Without it, these jobs fall back to simpler rules or to Pippa's own AI. Pippa never needs it.

## Online AI instead

If you prefer, Pippa can work with an online AI: sign in with your ChatGPT subscription, or add your own OpenAI or
Anthropic key in Settings. While it's on, your conversations and what Pippa reads for them go to that service. See [Privacy and permissions](privacy-and-permissions.md#online-ai-only-if-you-switch-it-on).
