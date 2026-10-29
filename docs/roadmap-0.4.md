# Pippa 0.4: a familiar window, an easier start, finished results

Release plan · 28 October 2026 · **Work on branch `claude/adoring-einstein-4z6whw`; nothing here is released yet**

Pippa keeps her desktop pill as the place to drop things, and gains a conversation window that works like other
assistant apps. Setup asks for one decision instead of several. The README and the website lead with one promise:
"Paperwork on your Mac? Done." The reasons for that wording are in [Positioning](positioning.md).

## On this branch

| Area | What changed | Verified by |
|---|---|---|
| Conversation window | Conversations rail on the left (Today / Yesterday / Previous 7 Days / Older, rename and delete from a "…" menu), the unchanged conversation in the middle, a detail rail on the right with *Files in Use*, *Results* (prepared, found, created or changed files, drafts, charts, and Calendar and Reminders entries) and *Sources*. ⌘N new conversation, ⌃⌘S and ⌥⌘I toggle the rails. Below 632 pt the window is today's plain conversation, so every 400 pt capture is unchanged. | `ConversationRailChecks` in PippaChecks; `scripts/check-conversation-rails.sh` (20 assertions per language) on macOS 15 |
| Setup | One primary action ("Load Pippa's AI · N GB") with "Picked to fit your Mac: chip with memory"; free space checked before the click; download consent kept across restarts and the download resumes asking only for the missing bytes; "Stop Loading"; a ready step that teaches ⌃⌥ Space and offers Open at Login; the local AI is loaded right after setup so the first answer has no cold start; English DMG with an "Applications" link. | 5 new setup checks; existing first-use acceptance |
| README and docs | New README; [What Pippa can do](what-pippa-can-do.md), [Pippa's local AI](models.md), [Privacy and permissions](privacy-and-permissions.md); release-notes intro rule. | relative-link check |
| Website | New hero with the demo above the fold, "Why Pippa?" comparison, honest privacy block, rewritten FAQ and start steps. | `check-site.cjs`, `check-site-launch.cjs`, screenshots at 1280×800 and 390 pt |
| Ideas from Hob | "Save as skill" after explicit approval, refused after web pages, mail or selected text; chart cards whose numbers Pippa computes from the table file, listed under Results and saved or copied as a picture; the PDF form-filling core (blank detection, filling a copy, card) without offering it to the AI yet; on-device dictation in the composer, built but switched off (`dictation.enabled`). | node tests incl. real Pi, PiRPCChecks, PippaChecks (skill, chart, form fill, dictation gate), macOS 15 acceptance |

## Next, in order

1. **Close the launch gates** in [Positioning](positioning.md#launch-gates): a real recording, physical 8/16 GB Macs, the
   English letter test, one English name for the folder action, and the repository description and topics.
2. **Starter AI first.** On 16 GB and larger Macs, download the 2.7 GB tier first, open the conversation, and switch to
   the full AI by itself when its download finishes. This removes the longest wait from the first session.
3. **Ask for permissions when a task needs them**, instead of the "What Pippa may do" page during setup. The chat
   permission repair from 0.3.13 already resumes the task after a grant.
4. **PDF forms, part 2.** Register `fill_pdf` and list blanks in `read_document` only after about five real German forms
   (tax, insurance, residence registration) have been filled correctly on a Mac. Part 1 (blank detection, filling, card,
   checks) is on this branch and reaches no model.
5. **Dictation.** Ship the hidden on-device dictation switch after testing microphone and speech permissions in a
   Developer ID build; later use `SpeechAnalyzer` on macOS 26.
6. **Turn dead-end setup errors into one-click fixes** (`releaseBroken`, `modelsJSONUnreadable`, `checksumMismatch`).
   Only then may copy say "no Terminal".
7. **Faster first download:** parallel range requests and an ETA measured on the person's connection.

## Measure before switching to MLX

Pippa runs llama.cpp with Metal on the GPU. The 23 October comparison ([oMLX versus Pippa's Qwen](measurements/omlx-compare-2026-10-23/README.md))
measured about 21 versus 20 tokens per second, but with different models, so it says nothing about the engines
themselves. Published 2026 results disagree: some report MLX decoding up to twice as fast, others report llama.cpp ahead
on M5 Max. Decide with one controlled comparison:

- **Same model, two engines:** Qwen3.5 9B as the shipped GGUF Q4_K_M under Pippa's llama-server, and as an MLX 4-bit
  conversion under an MLX server, both behind Pi with Pippa's prompts and tools.
- **Where:** a physical 16 GB Mac (the main tier) and one M5-generation Mac.
- **Measure:** time to first token, prompt processing for a 20-page PDF, generation speed, peak memory and swap, and the
  ten `scripts/quality/model-compare` tasks graded as in the oMLX comparison.
- **Switch only if** MLX is at least 30 % faster on time to first token or document reading with no loss in task
  correctness. Even then, keep llama.cpp for GGUF files reused from LM Studio, Ollama and Hugging Face.

Perceived speed has larger levers than the engine today: the median first visible answer took 15.6 s in that
comparison because of thinking, so lighter thinking for simple reading tasks comes before any engine change.

## iPhone

Underdog is building an iPhone app, and people photograph letters with their phones. A full Pippa on iOS is a different
product: no Pi or llama-server, smaller AI, App Store review. The proportionate first step is a **companion**: the
iPhone camera or share sheet sends a photographed letter or receipt to Pippa on the Mac (Continuity Camera already
inserts photos into Mac apps; a share extension or iCloud Drive inbox folder would cover the rest). Decide after the
launch gates, based on what testers actually photograph.
