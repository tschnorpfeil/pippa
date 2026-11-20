# Mail triage on Ornith, second pass: thinking off, a 32K window, a higher answer limit

2026-11-20, a follow-up to [pippa-1.0-spike-2026-11-19.md](pippa-1.0-spike-2026-11-19.md) and the measurement behind
[mail-sort.md](../../mail-sort.md). Same harness, same 240 invented mails, same task and prompt, same Mac (M6, 24 GB,
other apps running). One or two runs per setting, so these are observations, not rates. No real mail was touched.

Run again: start Pippa's local server, then
`SPIKE_THINKING=off SPIKE_WINDOW=16384 SPIKE_MAX_TOKENS=4096 SPIKE_TAG=x node scripts/spikes/pippa-1.0/run.mjs <payload> plan`.

## Results

| Variant | Window | Thinking | Answer limit | Moved (of 190) | Wrong | Time | Model turns | Peak prompt | How it ended |
|---|---|---|---|---|---|---|---|---|---|
| `plan` | 16K | medium | 4,096 | 0 | 0 | 784 s | 12 | 13,217 | 2026-11-19: answer limit while re-reading the inbox |
| `plan` | 16K | off | 4,096 | 190 | 0 | 16 s | 3 | 1,884 | Finished |
| `plan` | 16K | off | 4,096 | 190 | 0 | 17 s | 4 | 1,846 | Finished (second run) |
| `plan` | 32K | off | 4,096 | 190 | 0 | 17 s | 3 | 1,924 | Finished |
| `plan` | 32K | medium | 4,096 | 190 | 0 | 74 s | 4 | 3,633 | Finished |
| `plan` | 32K | medium | 8,192 | 0 | 0 | 383 s | 15 | 20,266 | Re-read all 12 pages to check the plan; oMLX memory guard aborted |
| `direct` | 16K | off | 4,096 | 0 | 0 | 214 s | 15 | 12,118 | Read all 12 pages, two compactions, answer limit three times, memory guard aborted |
| `direct` | 32K | medium | 4,096 | 0 | 0 | 142 s | 3 | 2,323 | Memory guard aborted after the first page |
| `both` | 16K | off | 4,096 | 0 | 0 | 125 s | 5 | 3,112 | Three working scripts (23 nested calls), then memory guard aborted |
| `both` | 16K | off | 4,096 | 0 | 0 | 165 s | 14 | 12,471 | Second run: no script, 12 pages read directly, answer limit, a broken tool call |
| `both` | 32K | medium | 4,096 | 0 | 0 | 42 s | 7 | 3,679 | Four working scripts, then memory guard rejected the prompt |
| `both` | 32K | medium | 4,096 | 0 | 0 | 9 s | 2 | 1,456 | Second run: memory guard rejected the second prompt |

In `plan`, `mail_sort` is the dry run: it proposes a folder for every inbox mail from the senders already filed in a
folder, without the model, and `mail_move` applies it by plan id.

## Reading

- **With the dry run made for it, Ornith finishes the task.** Four of six `plan` runs moved all 190 mails, none
  wrongly, and left the 50 others in the inbox. With thinking off it took three calls and 16 to 17 seconds in all
  three runs, at 16K and at 32K.
- **Thinking is what broke `plan` before.** With thinking on, the model decides to check the plan by reading the whole
  inbox, and that reading ends the run (two of three runs). A higher answer limit did not help; it gave the model room
  to read all twelve pages and then ran out of memory.
- **Without the dry run nothing changed.** No `direct` or `both` run made a move, with thinking off or at 32K.
  Thinking off removed the invented cursors (no failed call in any run) but not the problem: twelve pages do not fit.
- **32K is not measured here.** This Mac had about 6 GB for oMLX. Its memory guard ended six runs, two of them below
  4,000 prompt tokens. The 32K rows say nothing about a Mac with free memory.
- **Counts in the answer need the tool's numbers.** One answer added a folder's count wrongly (653 for 530 + 60), and
  the answers differed in what they counted: moved mails or new folder totals. The move itself was right each time.
- **The sort rule was perfect by construction.** In the invented inbox every sender files into one folder, so
  190 of 190 measures that the model drives the tool, not how well sender history sorts real mail.
- **Not measured:** thinking off on Pippa's other tasks, real Mail, more than two runs per setting.
