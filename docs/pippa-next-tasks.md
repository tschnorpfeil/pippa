# Pippa next: task list

Branch `claude/pippa-next`, plan in [pippa-next-architecture.md](pippa-next-architecture.md). Local commits only; push
and PR only on explicit request.

## Tool surface (target)

Pi's own: `read` (documents return text in the same call), `bash`, `write`; web: `web_search`, `fetch_content`.

Pippa's runtime tools (pippa-tools.ts): `search_files`, `list_folder`, `move_files` (destination `trash` moves to the
Trash), `remember`.

Pippa's MCP tools (in the app process): `calendar_read`, `reminders_read`, `mail_search`, `mail_read`, `photos_search`,
`front_read`, `read_document`, `calendar_add`, `reminder_add`, `mail_draft`, `prepare_files`.

Dropped: `applescript`, `pippa_more_tools` and tool-scope, `save_skill`, `make_chart`, `fill_pdf`, `move_to_trash`
(merged), pippa-context (handover and quiet summaries; Pi compacts), the draft-only lane.

## Steps

- [x] Audit and plan
- [x] Runtime tools: fact-shaped results (sorted, full timestamps, at most 20, newest marked), `read` returns document
      text, drop the tools above, tests updated
- [x] MCP: chart and form fill dropped, tool list trimmed (cards come from the in-process server's read and write notes,
      so no `structuredContent` is needed)
- [x] PiRPC: action policy removed; native readiness checks the trimmed list
- [x] Launch: short system prompt (under 300 tokens), fixed tool list, no keyword routing
- [x] New app target: menu bar, hotkey, pill, chat window with sidebar (Pi sessions), composer with file drop and
      front-app chip, cards, stop, permissions on demand
- [x] First run: one card (download for this Mac, or online AI); settings: AI, permissions, updates
- [x] Delete old UI, routers, LocalEngine, SourceFidelity sentence removal, snapshot harness, old checks
- [ ] Checks: behavior only
- [x] CI split: fast PR gate (`ci.yml`); real Pi, web access, macOS 15 and the app build by hand and on release tags
      (`heavy.yml`)
- [x] Docs: development.md, README; one [ROADMAP](ROADMAP.md); old plans and measurements in [archive/](archive/)
- [ ] Acceptance: the five tasks in the plan (Qwen 3.5 9B on this Mac, `Pippa --ask` / `--make-pdf`, 2026-11-01)
  - [x] ETF overview in iCloud `brain`: names `ETF-Portfolio.md` (updated 2026-11-01) as current, 293 s cold
  - [ ] Payment receipts from Mail attachments: needs Mail permission for a signed build
  - [ ] Calendar entry: needs Calendar permission for a signed build (`calendar_read` waited on the macOS prompt)
  - [x] Letter deadline: pay by 15 Nov 2026; objection "four weeks after receipt" without a computed date, 54 s
  - [x] Photos to one PDF: with the model 82 s, with the One PDF button and no model under 10 s
- [ ] Acceptance again with Ornith 1.5 9B on oMLX (2026-11-01, results in docs/omlx-switch.md): ETF 262 s and photos
  57 s pass; the letter deadline regresses against Qwen (Ornith computes an objection date in three of three runs);
  Mail totals not done within 600 s; Calendar still waits on the permission

## Open

- UI polish, first pass done (867173e): Markdown blocks, folded steps, live thinking, date-grouped sidebar with
  search, new composer and empty state. `Pippa --snapshot <folder>` renders sample states. Next: settings layout,
  card views, onboarding text.

- [x] Undo for calendar entries and reminders in the receipt row: removes only what is unchanged since Pippa added
  it, and tells Pi with the next question.
- Mail and Calendar acceptance needs a signed build or the person's clicks: a re-signed dev copy asks macOS again.
- Local AI switched to oMLX with Ornith 1.5 9B (MLX, 4-bit); llama.cpp, GGUF and the model table are gone. Tasks in
  [omlx-switch.md](omlx-switch.md).
