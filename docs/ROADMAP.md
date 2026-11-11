# Roadmap

The one plan for Pippa. The design is [Pippa next](pippa-next-architecture.md); the step-by-step list is
[pippa-next-tasks.md](pippa-next-tasks.md). Older plans and measurements are in [archive/](archive/).

## Where Pippa stands

The last release is 0.6.4. Pippa is a plain native chat front end for Pi: Pippa Island and one chat window with a
conversation sidebar, a first-run card, and settings for the AI (on this Mac, ChatGPT, or an own online AI), the
shortcut, login item, permissions and updates. Dropped photos and PDFs become one PDF with a button, without the model.

Pi does the work through a fixed list of tools: Pi's `read`, `bash` and `write`; the web; Pippa's file tools
(`search_files`, `list_folder`, `move_files`, `remember`); and the app's MCP server for Calendar, Reminders, Mail,
Photos, the app in front, documents and PDF building. Keyword routers, the letter and Excel lines, the tidy preview, the
deadlines view, the morning overview, charts, PDF form filling, saved skills, AppleScript, dictation and the second model
engine are gone.

## Next

The [0.6 scope](plan-0.6.md) shipped the foundation and reliability work first, kept tiny apps out, and left life memory
conditional on a bounded usefulness experiment. The five-task acceptance gate remains in force before any new production
tool or card.

1. **Acceptance.** The five tasks in the plan, on a 16 GB Mac with Ornith 1.5 9B on oMLX: find a file in iCloud, evaluate mail
   attachments, add a calendar entry, answer a letter's deadline with the quoted sentence, and photos to one PDF
   without the model. Document selection, Mail payment totals and receipt-based deadlines remain open model-quality
   limits ([plan-0.6.md](plan-0.6.md), [omlx-switch.md](omlx-switch.md)).
2. **UI polish, second pass:** card views, onboarding text.
3. **Pippa Island on a MacBook with a notch.** The chat and Settings were checked with Liquid Glass drawn by the window
   server (`PIPPA_SNAPSHOT_LIVE=1 Pippa --snapshot`, 2026-11-09, Mac mini without a notch); the island at a real notch
   still needs one look.

Released in 0.6.4: the open Pippa Island is centred on the notch again, and another notch tool right of it
(like tinyStats) stays in front of it instead of moving the island.

Released in 0.6.3: the open Pippa Island keeps left of the notch when another notch tool (like tinyStats) shows right
of it, centred otherwise, with her mark and name in the menu bar row beside the housing; her handwriting (`Scribble`, the pill's old "write" shape) while words come in, on the island and in the
chat; the island's question field keeps the keyboard while she answers; her steps on the open island as a chain that
ends on her thinking or the answer as it is written.

Released in 0.6.2: "Starting my AI…" in the chat window and on Pippa Island while the local AI starts and loads, with
an explanation behind an info button (the weights are now loaded before the question goes out); "Writing…" only while
words come in; files dragged from another app onto the open Pippa Island land there instead of closing it; ⌥ Space as the default shortcut; Pippa Island only left of the notch, with her mark visible
there at rest; a drop tray when files are dragged toward the closed island; the question field focused when the
shortcut opens the island; formatted answers in the island.

Released in 0.6.1: an almost black chat window in Dark Mode to match Pippa Island; large downloads over four
connections with the single connection as fallback; the plain short-on-memory sentence when oMLX's memory guard ends a
request; calmer opening and closing of the steps under an answer; no scroll bar in the conversation; a Copy button that
never wraps.

Released in 0.6.0: serialized Pi setup and first-start installation with automatic repair of incomplete owned runtimes;
newest-first inbox selection before applying the result limit, exact Mail message reads and openable Mail source chips;
preserved inline document attachments and explicit reporting of missing attachment bytes; unsupported-date warnings for
nearby dates too; headless `--ask` exit codes, length-cutoff failure reporting, the acceptance runner, and a bounded
read-only `--memory-probe` diagnostic.

Released in 0.5.0: macOS 26.2 or later is required (the oMLX runtime's MLX binaries need it); Pippa
Island at the notch or under the menu bar symbol replaces the pill; a calmer chat window that streams answers without
reparsing them and asks Pi's questions in the conversation; Settings with toolbar pages (General, AI, Permissions,
Updates) and a permission overview that never prompts; no developer-tool install dialog from Pippa's shell on Macs
without Apple's developer tools, plain sentences when the local AI is short on memory or the disk is short on space;
setup, download, MCP and integration code split into smaller files with one hashing helper; the oMLX runtime 0.7.3-2
with oMLX's native kernels, built in CI and published as a release asset; a SHA-pinned copy of the model in this repository's releases
that the download falls back to. Research for the local AI:
[local-ai-research-2026-11.md](local-ai-research-2026-11.md).

Done since 0.3.20: Undo for calendar entries and reminders in the receipt row; the oMLX runtime archive is published
as a release asset.

No new tool or card until the acceptance tasks pass.
