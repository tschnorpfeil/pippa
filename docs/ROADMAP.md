# Roadmap

The one plan for Pippa. Where she is going: [Vision](VISION.md). The design is [Pippa next](pippa-next-architecture.md); the step-by-step list is
[pippa-next-tasks.md](pippa-next-tasks.md). The plan for 1.0 (Pippa acts by default, with gates only for what
cannot be undone or leaves the Mac, and a journal with undo for whole runs) is [pippa-1.0.md](pippa-1.0.md),
decided on 2026-11-19 and shipped in 1.0.0. Older plans and measurements are in [archive/](archive/).

## Where Pippa stands

The last release is 1.2.0. Pippa is a plain native chat front end for Pi: Pippa Island and one chat window with a
conversation sidebar, a first-run card offering local or online AI, optional calm notices (Morning Brief and one
watched folder, off by default), and settings for the AI (on this Mac, or an online
AI with per-source sharing review and optional Mac access), optional abilities, the shortcut, login item, permissions
and updates. Dropped photos and PDFs become one PDF with a button, without the model.

Pi does the work through a fixed list of tools: Pi's `read`, `bash` and `write`; the web; Pippa's file tools
(`search_files`, `list_folder`, `move_files`, `remember`, `ask`); and the app's MCP server for Calendar, Reminders, Mail,
Photos, the app in front, documents and PDF building. An online AI with Mac access also gets Pi's `codemode`. Every tool
has an action class: what can be undone runs at once and is journaled with Undo for the whole answer, and what cannot
be undone or leaves the Mac runs only after the person presses the button on a card. Keyword routers, the letter and Excel lines, the tidy preview, the
deadlines view, the morning overview, charts, PDF form filling, saved skills, AppleScript, dictation and the second model
engine are gone.

## Next

Direction: [Vision](VISION.md). The [0.6 scope](plan-0.6.md) shipped the foundation and reliability work first, kept
tiny apps out, and left life memory conditional on a bounded usefulness experiment. Since 1.0 the five acceptance tasks
gate each release, not the start of new work ([pippa-1.0.md](pippa-1.0.md#tools-in-10)). Document selection, Mail
payment totals and receipt-based deadlines remain open model-quality limits ([plan-0.6.md](plan-0.6.md),
[omlx-switch.md](omlx-switch.md)).

### Pippa 1.1: less to carry, more apps

Gate: the five acceptance tasks on a 16 GB Mac with Ornith 1.5 9B on oMLX (find a file in iCloud, evaluate mail
attachments, add a calendar entry, answer a letter's deadline with the quoted sentence, photos to one PDF without the
model) plus the prompt-budget gate.

1. **Prompt-budget gate:** an automated check that the fixed prompt and tool list stay inside the token budget.
2. **Compact document reading and deterministic `compute`** for sums, dates and deadlines instead of model arithmetic.
3. **`calendar_update` and `reminder_update`** with journaled Undo.
4. **Read-only `notes_read`.**
5. **Safari multi-tab** in `front_read`.
6. **`contacts_search`.**
7. **Apple Foundation Models Tier-0:** conversation titles, with a plain fallback where Apple Intelligence is off.
8. **Zero-friction first run:** fewer steps and less text before the first answer.
9. **`mail_sort`** after the real-mail probe passes ([mail-sort.md](mail-sort.md): Ornith moved none of 190 mails by
   reading pages, and all 190 in 16 seconds once the app made the plan).

No Full Disk Access in any of these.

### Pippa 1.2: calm proactivity

Contract: [Vision, section 5](VISION.md#5-calm-proactivity-12). Opt-in, one or two nudges a day, Focus-aware, one-click mute.

1. **Calm Morning Brief** on Pippa Island as a durable job.
2. **Human-closed tasks:** Pippa opens, the person closes.
3. **Voice brain dump** into notes and reminders.
4. **Watched folder** with zero-token Swift watchers.
5. **32+ GB local model shootout** for Macs that can run a larger model.

### Still open

- **Pippa Island on a MacBook with a notch.** Checked on a MacBook Air with a notch for 0.6.6 (window lifecycle check,
  real menu bar); motion and drag and drop at the real notch still need a look.
- **Real-portal browser sign-in matrix.** Multi-tab local browsing and OAuth child popups are implemented; manual
  AutoFill/Passkey testing across 5 real portals on macOS 26.2 remains open.

Released in 1.2.0: For You desk with scheduled routines, natural-language routine creation, starter packs, reactive watchers and isolated read-only checks; multi-tab local browser per conversation with LRU memory eviction, real child-window OAuth sign-in popups, compact action observations, single-card form confirmations, query-free same-host links, long-page reading and an "Open in Pippa’s Browser" bridge; expandable unsent Mail draft preview cards (without a direct Send button); one-card question selection with persistent answered-question history; decoupled concurrent One PDF, per-conversation send queue with settings/sharing re-check, burst-coalesced steering and steering-aware approval cancellation; bounded `structuredContent` on MCP readers for codemode; online onboarding data-flow summary, Recommended default model badge, default `medium` effort and fixed online failure classes with privacy-safe diagnostics; local model compaction deadlock rescue for Pi 1.6.0.

Released in 1.1.0: opt-in calm notices (Settings › General › Calm notices, off by default) backed by a SQLite matter store (`proactivity.sqlite`) with human-closed task permanence, a strict daily cap of at most 2 nudges/day, quiet hours + screen-lock + optional Focus status awareness, 1-click mute per kind, a 0-token Morning Brief (`DurableJobKind.morningBriefing`) from already-authorized Calendar and Reminders with a Settings preview, a single-level watched folder scanner with content-hash deduplication and Tier-0 Apple Foundation Models triage (strictly read-only, never waking oMLX in the background), and a quiet Pippa Island nudge card with menu bar fallback; reliable "Check for Updates…" and direct "Install and Restart" when a background Sparkle update waits for quit; redesigned heypippa.app website (German and English) and updated OG preview cards.

Released in 1.0.5: native Inkling 2 Mini (`inkling-2-mini-oQ3e`, 32K context, native vision, oMLX 0.8.3 with native kernels and aggressive memory guard) on Macs with 32 GB of memory or more while 16–24 GB Macs keep Ornith 1.5 9B and upgraded Macs move old bundled model weights to Trash; mid-turn follow-up messages while Pippa works; live step status line, Stop progress ring, and compact source links; Apple Notes read, Contacts search, Safari multi-tab read, Calendar and Reminders updates with Undo, deterministic `compute`, and automatic conversation titles via Apple Foundation Models with fallback.

Released in 1.0.1: a tool name the model mistypes with a prefix it saw elsewhere (`web_fetch_content`, `mcp__pippa__ask`) is renamed to the one active tool it means before Pi runs it; the first web search of a conversation asks, later ones in that conversation run; failed Pi tool calls appear in `pippa.log` (`pi-werkzeug`); unknown tools show "Using a tool" instead of their raw name; `read_document` points a web address to `fetch_content`; bundled Pi 1.6.0.

Released in 1.0.0: Pippa acts by default on what she can undo (events, reminders, unsent drafts, file moves, mail moves) for the AI on this Mac and an online AI with Mac access; action classes (`read`, `undoable`, `irreversible`, `external`) with a card-and-button gate checked in code; `mail_folders` and `mail_move` (inbox into one existing folder per call, dry run, batches verified by Message-ID, never Trash, Junk, Sent or Drafts); `mail_send` for one draft saved in the conversation, after a card; a run journal in `journal.sqlite` with one receipt and one Undo per answer, "unclear, please check" after an interruption, kept 30 days; rate limits waited out (15, 30, 60, 60 seconds) with a countdown and Continue, quota told apart; going online from the shell asked per command; `codemode` for an online AI with Mac access. Not in 1.0: deleting for good, payments, a channel bot, creating mail folders.

Released in 0.8.2: updated bundled Pi release from 1.5.0 to 1.5.2 (latest provider catalog, Anthropic OAuth / OpenRouter / OpenCode / MCP tool-schema and stdio fixes).

Released in 0.8.1: explicit **Allow Mac access** grant for one verified online AI (scoped to provider, model and account, off by default), account-aware paged Mail triage across unread/read/Sent/Drafts with reply-state detection and threaded drafts, richer Calendar details and multi-day/named-calendar events, direct browser URL bar when empty, quieter collapsed Sharing settings when online AI is off, cleaner online setup copy, modularized Swift core/app/view files, and main-thread/runtime performance and reliability fixes.

Released in 0.8.0: choosing local or online AI directly in first-run setup, per-source reviewed sharing with online AI (Mail, Documents, Calendar, Reminders, Photos) with editable excerpts and single-question handoff (**Ask [provider]…**), separate Web search and Personal notes switches for local and online AI, and keeping Island conversations and drafts when opening the full window.

Released in 0.7.0: Pippa's browser (a `WKWebView` panel in the chat window and the `browse` tool; she asks before each new site and each click, typed text or choice, and hands sign-ins to the person), a read-only Accessibility fallback for `front_read`, a tighter shell sandbox (Mach service lookups limited to an allowlist, no inherited Accessibility trust), and continuing an earlier conversation from Pippa Island with a fixed follow-up rule (`Island.followUp`).

Released in 0.6.8: Pippa asks when she can't tell what you mean (the `ask` tool: a question with choices on the existing card, in the chat and on Pippa Island; the system prompt's ask test), and an empty file search asks the model to try one other word, then stop (the 9B model does not always stop yet).

Released in 0.6.7: a question on Pippa Island follows up the conversation of the last ten minutes ("Follow up…", a
pencil for a new one); the island's step chain keeps its height, shows no thinking text and streams the answer's last
three lines without reflowing; a laptop or cloud beside the island's field names the AI and opens Settings; room between the chat's last line and the composer.

Released in 0.6.6: long PDF and Word texts read to the end as notes on all of them, saved and reused while the file is
unchanged; Pippa Island shows one live mark at a time (beside the notch the island, under the menu bar symbol the
symbol), each status once, an answer only until it was seen, and stays on screen when the chat is hidden with ⌘H.

Released in 0.6.5: one look for the chat window, Pippa Island and Settings. The island in SF Pro Rounded on one grid,
an approval question directly on the black with one filled "Allow", the field and "Open Pippa" in one row, a solid drop
tray, and a panel height that follows its own spring; the chat with clearer headings, capsule buttons, neutral card
symbols, the AI named once in the composer by its display name, and Pippa's mark in the empty sidebar; Settings on the
chat's almost black background with one type scale and display names for models.

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
