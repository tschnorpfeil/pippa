# Pippa 1.0 spike: mail triage on Ornith at 16K, direct tools against codemode

2026-11-19, for [pippa-1.0.md](../../pippa-1.0.md). One run per variant, so these are observations, not rates.

## Setup

- Mac with an M6 and 24 GB; other apps held memory, so oMLX throttled prefill and once aborted a request.
- Ornith 1.5 9B (MLX 4-bit) on oMLX 0.7.3-2, started from Pippa's launch file. Window forced to 16,384 tokens, answer
  limit 4,096, thinking medium, compaction as `PiModelTuning` sets it (reserve 4,096, keep 6,144).
- Pi 1.5.2 from `scripts/bundle-pi-payload.sh`, `--mode json`, a fake home under `.build/`, Pippa's English system
  prompt read from `PippaPiLaunch.swift`.
- A synthetic Mail server over MCP (`scripts/spikes/pippa-1.0/mail-server.mjs`): 240 invented mails in the inbox, seven
  folders, 190 mails that belong in a folder and 50 that stay (44 personal, 6 traps whose subject contains a folder
  word). Tools: `mail_folders`, `mail_search` (pages of 20, cursor), `mail_move` (refs, target, `dry_run`, verified
  count). No real mail and no real account was touched.
- Task: "Tidy my inbox: move the mails into my existing folders where they clearly belong. Personal and unclear mails
  stay in the inbox. Do a dry run first, check it, then move. Tell me the count per folder at the end."

Run again: start Pippa's local server, then
`node scripts/spikes/pippa-1.0/run.mjs <payload> direct|only|both|plan`.

## Results

| Variant | What the model sees | Mails moved (of 190) | Wrong moves | Time | Model turns | Peak prompt | Compactions | How it ended |
|---|---|---|---|---|---|---|---|---|
| `direct` | Three tools, pages of 20 | 0 | 0 | 429 s | 12 | 13,178 | 1 | Answer limit reached while thinking, after 6 of 12 pages |
| `only` | `codemode` only (`codemode.mode: "only"`) | 0 | 0 | 635 s | 19 | 12,285 | 2 | Answer limit reached; 3 of 10 scripts failed |
| `both` | Three tools and `codemode` | 0 | 0 | 280 s | 5 | 12,478 | 1 | oMLX memory guard aborted the request after a compaction |
| `plan` | Three tools and `mail_sort`, a dry run without the model that `mail_move` applies by plan id | 0 | 0 | 784 s | 12 | 13,217 | 5 | Answer limit reached while re-reading the inbox to check the plan |

No variant made a dry run or a move.

## What happened

**`direct`.** The model read the folders and two pages, then asked for seven pages at once with cursors it invented
(`c3` to `c9`); that answer hit the 4,096-token limit and Pi refused the calls. It retried the invented cursors five
times, started over, and reached page 6 before one more answer ran into the limit with nothing said. Twelve of twenty
calls failed. Reading 240 mails in pages of 20 does not fit: the prompt reached 13,178 tokens after six pages.

**`only`.** The model first called the hidden tools directly with a wrong argument shape (five validation errors).
Then it wrote working scripts. One script fetched all 240 mails in 0.1 seconds and returned 100 characters to the
model ("TOTAL_FETCHED 240"): the whole inbox for about 25 tokens of context. It then failed to carry the list to the
next script: it tried `require` and `fs`, then read with `store("key")` instead of `load("key")`, and spent its
remaining turns testing `store`. It called a tool named `courcemode` once. It never reached sorting.

**`both`.** After two direct pages the model chose `codemode` without being told ("fetch the rest of the inbox
efficiently using a loop"), and the script worked at the first try. But the script printed all 240 rows (15,102
characters) into the answer, which forced a compaction, and the next request was aborted by oMLX's memory guard.
This says the model picks scripts unprompted; it does not say whether it would have finished.

**`plan`.** The second call returned the finished dry run: counts per folder, examples and a plan id, in 1,041
characters. Applying it needed one more call. The model instead paged through the whole inbox to check the plan
("Do a dry run first, check it"), went through five compactions and ended on the answer limit while looking for
mails for an empty folder. It never applied the plan.

## Reading

- **Ornith did not finish this task in any shape,** not even with the dry run handed to it. Nothing was moved, so
  nothing was moved wrongly.
- **The window is not the only limit.** Codemode removes the reading problem (240 mails for 25 tokens). The model
  then fails at the next step, a plan that spans several calls.
- **The answer limit ends runs.** Three runs ended on `stopReason: "length"` in the middle of thinking, and the
  fourth hit it just before the memory abort, the same way the Mail totals task fails in [omlx-switch.md](../../omlx-switch.md).
- **Nested calls are visible.** Pi reported every tool call a script made as `tool_execution_start` with
  `parentToolCallId` (54 in `only`, 12 in `both`), and the scripts received `structuredContent`.
- **Not measured:** an online model on the same harness, a 32K window, more than one run per variant, a gate
  question in the middle of a script, and real Mail.
