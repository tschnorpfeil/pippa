# Roadmap

The one plan for Pippa. The design is [Pippa next](pippa-next-architecture.md); the step-by-step list is
[pippa-next-tasks.md](pippa-next-tasks.md). Older plans and measurements are in [archive/](archive/).

## Where Pippa stands

The last release is 0.4.5. Pippa is a plain native chat front end for Pi: menu bar, pill and one chat window with a
conversation sidebar, a first-run card, and settings for the AI (on this Mac, ChatGPT, or an own online AI), the
shortcut, login item, permissions and updates. Dropped photos and PDFs become one PDF with a button, without the model.

Pi does the work through a fixed list of tools: Pi's `read`, `bash` and `write`; the web; Pippa's file tools
(`search_files`, `list_folder`, `move_files`, `remember`); and the app's MCP server for Calendar, Reminders, Mail,
Photos, the app in front, documents and PDF building. Keyword routers, the letter and Excel lines, the tidy preview, the
deadlines view, the morning overview, charts, PDF form filling, saved skills, AppleScript, dictation and the second model
engine are gone.

## Next

1. **Acceptance.** The five tasks in the plan, on a 16 GB Mac with Ornith 1.5 9B on oMLX: find a file in iCloud, evaluate mail
   attachments, add a calendar entry, answer a letter's deadline with the quoted sentence, and photos to one PDF
   without the model. ETF and photos pass; the letter deadline regresses against Qwen (Ornith computes an objection
   date), Mail totals run past the answer limit. Details in [omlx-switch.md](omlx-switch.md).
2. **Mail and Calendar acceptance** needs a signed build or the person's clicks: a re-signed development copy asks
   macOS again.
3. **UI polish, second pass:** card views, onboarding text.
4. **Liquid Glass on a real screen.** Snapshots draw without system glass (`cacheDisplay`); the chat, Pippa Island and
   Settings need one look on macOS 26 or later, and Pippa Island one on a MacBook with a notch.

Done since 0.4.5, not released yet: macOS 26.2 or later is required (the oMLX runtime's MLX binaries need it); Pippa
Island at the notch or under the menu bar symbol replaces the pill; a calmer chat window that streams answers without
reparsing them and asks Pi's questions in the conversation; Settings with toolbar pages (General, AI, Permissions,
Updates) and a permission overview that never prompts; no developer-tool install dialog from Pippa's shell on Macs
without Apple's developer tools, plain sentences when the local AI is short on memory or the disk is short on space;
setup, download, MCP and integration code split into smaller files with one hashing helper. Research for the local AI:
[local-ai-research-2026-11.md](local-ai-research-2026-11.md).

Done since 0.3.20: Undo for calendar entries and reminders in the receipt row; the oMLX runtime archive is published
as a release asset.

No new tool or card until the acceptance tasks pass.
