# Pippa next: a native Mac front end for Pi

Pippa 1.0 changed rules 3, 4 and 7 below: a token budget for the fixed prompt instead of a tool count, scripts may
read more than 20 entries, and the five tasks gate the release instead of new work. See
[pippa-1.0.md](pippa-1.0.md#tools-in-10).

Status: proposal, 2026-11-01. Replaces the plans in [archive/](archive/) (`next-level-plan-2026-10-30.md`,
`pippa-next-evolution-2026-10-21.md`, `roadmap-0.4.md`) if accepted. Where things stand: [ROADMAP.md](ROADMAP.md).

## Why

The audit of 2026-11-01 found the same pattern everywhere: Pippa decides things around the model instead of letting
the agent work. Six keyword routers guess intent before Pi sees a message, about 22 prompt rules and regexes patch
single observed failures, and `SourceFidelity` deletes sentences from finished answers. The UI has 14 shell modes,
three bespoke "line" surfaces and about 13 card types. Each layer was reasonable on its own; together they are 77k
lines of Swift that contradict each other (deadlines from the letter date in `Deadlines.swift`, forbidden by the
`fristen-erkennen` skill).

## The idea

Pi is the harness. Pippa is the window and the hands.

| Part | Owner |
|---|---|
| Reasoning, tool choice, sessions, compaction, skills, memory | Pi, unchanged, over RPC |
| Chat window, menu-bar pill, hotkey, file drop, cards | Pippa app |
| Mail, Calendar, Reminders, Photos, documents, PDF building, file search and moves | One MCP server inside the app process |
| Model and runtime download, the oMLX server, whether this Mac can run the model | Pippa app |

The MCP server stays inside the app so macOS asks for "Pippa" when a tool first touches Mail or Calendar, and the
permission belongs to the app. The same server can be offered to Pi in the terminal, so the tools outlive the app if
the app is ever dropped.

## Rules

1. No code decides what the user means before Pi does, and no code rewrites Pi's answer afterwards.
2. No prompt rule for a single observed failure. If the model can't do a task, the fix is a better model or the
   online AI, not a patch. The system prompt stays under 300 tokens.
3. At most about 12 tools, one purpose each, one way per job. Nothing that Pi already does (read, bash, skills,
   sessions) is rebuilt.
4. Tools return facts, not raw data: results sorted, with full timestamps, at most 20 entries, the newest marked,
   documents read to text. This is tool quality, not routing.
5. Jobs without AI (photos to one PDF, smaller PDF, tidy with undo) are tools too. The app can call them from a
   button without the model.
6. Checks test behavior. No assertions on prompt wording or on source text.
7. One plan file. No new tool or card until the five acceptance tasks below pass.

## Cards

Pi's RPC stream reports every tool run as `tool_execution_start` and `tool_execution_end`, with the tool name,
arguments and result. Extension tools return a structured `details` object, and Pi carries an MCP tool's
`structuredContent` through to its result (`agent-session.js`). The app builds a card from the tool name plus that
structured result: a mail draft with "Open in Mail", a reminder with "Undo", a PDF with "Show in Finder". Six card
kinds are enough: files, list items (mail, events, reminders, photos), draft, chart, sources, receipt with undo.
Not yet tested end to end: whether `structuredContent` arrives in the RPC event unchanged. Because the server runs in
the app process, the app can fall back to the result it produced itself.

## UI

- A small pill with a state dot (ready, working, needs you), and one normal, resizable chat window with a
  conversation sidebar.
- Dropped files and the front app become chips in the composer. Native jobs appear as suggestion chips.
- Permissions are asked when a tool first needs them, with one shared explanation. Settings has the repair list.
- First run is one card: load the AI (size for this Mac) or use an online AI. Native jobs work during the download.
- Menu bar: Ask Pippa, Recent Conversations, Settings, Quit.

## What carries over

`PiRPC`, model download and local server start (`PiSetup`; since 2026-11-01 `OMLXServer`, see
[omlx-switch.md](omlx-switch.md)), the native readers and writers in
`PippaMCP*` and `runtime/pippa-tools` (trimmed to the tool list), and the deterministic parts of PippaCore:
`GermanText`, `Naming`, `MailFiling`, `PreSort`, `CalendarRange`, `FolderLookup`, PDF building and Undo.

Not carried over: shell modes, line surfaces, the keyword routers, `pippa_more_tools`, `SourceFidelity`'s sentence
removal, `LocalEngine`, the second local server supervisor, the snapshot harness in the product target, and the
wave-named source-grep checks. Target size: 6,000 to 8,000 lines of Swift.

## Acceptance

The new app replaces the old one when these pass on a 16 GB Mac with Pippa's local model (Ornith 1.5 9B on oMLX since
2026-11-01):

1. "Find my ETF portfolio overview in my iCloud folder brain": names `ETF-Portfolio.md` as the current file.
2. "Evaluate the attachments of the last three mails about Zahlungseingänge": reads the PDFs and gives the totals.
3. "Put a dentist appointment on Tuesday at 10": a calendar card with Undo.
4. A letter PDF dropped in, "Until when do I have to answer?": the deadline with the quoted sentence, no date
   computed from the letter date.
5. Five photos dropped in, "one PDF": a PDF card, without the model.

If they don't pass, the tools go to Pi in the terminal as a package and the app is retired.

## Order

1. Tool server: the trimmed tool list with fact-shaped results, tested with Pi in the terminal first.
2. Cards: an RPC spike that shows a mail draft card from a real `tool_execution_end`.
3. Chat window and pill on top of `PiRPC`.
4. First run and model setup carried over.
5. Acceptance tasks, then the decision.
