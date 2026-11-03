# Roadmap

The one plan for Pippa. The design is [Pippa next](pippa-next-architecture.md); the step-by-step list is
[pippa-next-tasks.md](pippa-next-tasks.md). Older plans and measurements are in [archive/](archive/).

## Where Pippa stands

Pippa 0.4.1 has shipped. The current checkout makes her a regular native Mac app for Pi: a Dock icon, app menus, a menu bar shortcut, an optional
pill at the edge of the screen and one chat window with a conversation sidebar, a first-run card, and settings for the AI (on this Mac, ChatGPT, or an
own online AI), the shortcut, login item, permissions and updates. Dropped photos and PDFs become one PDF with a button,
without the model.

The chat window is unified: conversations in the sidebar show their topic and the start of the answer and can be pinned
and renamed; while Pippa works, one line says what she is doing; a side panel shows what she read (which pages), what she
changed on your Mac, which dates she checked against the source, and how full the conversation is. Dates she worked out
herself are marked. Files she read appear under the answer.

The AI on your Mac is one model, Ornith 1.5 9B (MLX, 4-bit), served by oMLX; the Python runtime with oMLX is downloaded
at setup. llama.cpp, GGUF and the model table by memory are gone.

Pi does the work through a fixed list of tools: Pi's `read`, `bash` and `write`; the web; Pippa's file tools
(`search_files`, `list_folder`, `move_files`, `remember`); and the app's MCP server for Calendar, Reminders, Mail,
Photos, the app in front, documents and PDF building. Keyword routers, the letter and Excel lines, the tidy preview, the
deadlines view, the morning overview, charts, PDF form filling, saved skills, AppleScript, dictation and the second model
engine are gone.

## Next

1. **Acceptance.** The five tasks in the plan, on a 16 GB Mac with Ornith 1.5 9B on oMLX: find a file in iCloud, evaluate
   mail attachments, add a calendar entry, answer a letter's deadline with the quoted sentence, and photos to one PDF
   without the model. Mail attachments and the calendar entry still need a signed build (or the person's clicks); the
   letter deadline still needs work (Ornith computes an objection date in some runs).
2. **Undo** for calendar entries and reminders in the receipt row (the old app had it).
3. **Mail and Calendar acceptance** needs a signed build or the person's clicks: a re-signed development copy asks macOS
   again.
4. **Local AI on oMLX.** Acceptance runs with Ornith and publishing the runtime archive are still open; see
   [omlx-switch.md](omlx-switch.md).
5. **UI polish.** Settings layout, card views, onboarding text (first pass done).
6. **Release.** The website (`site/`), release notes and entitlements keep pace with the app for each release.

No new tool or card until the acceptance tasks pass.