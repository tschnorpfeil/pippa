# Ornith with thinking off on five everyday tasks

2026-11-20, for the open point "Thinking for Ornith" in [mail-sort.md](../../mail-sort.md). Thinking off made the mail
triage work ([mail-sort-ornith-2026-11-20.md](mail-sort-ornith-2026-11-20.md)); this asks what it does elsewhere.

## Setup

- Pippa 1.0.0 (signed build with probes), `Pippa --ask "…"` with `PIPPA_DEMO=1`: Mail, Calendar and Reminders are the
  app's invented demo data, nothing real is read from them or written to them. File search and the notes file are real.
- Ornith 1.5 9B on oMLX, 32K window (this Mac has 24 GB), M6, other apps running.
- Thinking set through a copy of Pi's settings (`PI_CODING_AGENT_DIR`, `modelThinkingLevels` `medium` or `off`); Pi's
  session files confirm the level and show no thinking blocks in the off runs.
- Three runs per task and level, alternating. Observations, not rates. `--ask` cannot answer a question or drop a
  file, so task 4 names the file's path and task 5 of the acceptance list (photos to one PDF, without the model) is
  replaced by a reminder.

| Task | Counts as right |
|---|---|
| 1 "Find my ETF portfolio overview in my iCloud folder brain" | Names `ETF-Portfolio.md` |
| 2 "Wie viel muss ich für die Nebenkosten nachzahlen und bis wann?" | 312,48 € and 31.10.2026, from the demo mail |
| 3 "Put a dentist appointment on Tuesday at 10" | An event on Tuesday 24 November, 10:00 |
| 4 An invented letter, "Until when do I have to answer?" | Quotes "innerhalb von 14 Tagen nach Zugang", computes no date |
| 5 "Remind me tomorrow at 9 to call the plumber" | A reminder tomorrow 09:00 with that job |

## Results

| Task | Medium: right | Medium: seconds | Off: right | Off: seconds | Off: what went wrong |
|---|---|---|---|---|---|
| 1 File | 3 of 3 | 58, 101, 242 | 2 of 3 | 16, 53, 60 | One run answered after a single search and named no file |
| 2 Mail amount | 2 of 3 | 82, 199, 330 | 1 of 3 | 22, 49, 420 | One asked for a document; one looped on `find` until the 420 s cap |
| 3 Calendar | 2 of 3 | 38, 45, 49 | 2 of 3 | 6, 25, 31 | **One event on the wrong day** (today, a Friday, called Tuesday) |
| 4 Letter | 0 of 3 | 28, 41, 41 | 1 of 3 | 9, 16, 18 | Two computed a date, as all three medium runs did |
| 5 Reminder | 3 of 3 | 9, 17, 18 | 3 of 3 | 5, 12, 13 | Right time each run; one with invented notes, one answer naming a job that was not saved |
| **All** | **10 of 15** | median 45 | **9 of 15** | median 18 | |

The medium misses: task 2 once gave up after file searches; task 3 once asked instead of adding; task 4 computed
"17. November" twice and "17. Dezember" once. The app marked every computed date as not in the sources.

## Reading

- **Thinking off is about 2.5 times faster and no more often right.** Nine against ten of fifteen is no difference at
  three runs per task.
- **Its mistakes are worse.** Medium never wrote anything wrong: its misses were no answer, a question, or a computed
  date the app flags. Off wrote one event on the wrong day and put invented details into a reminder and an answer.
  For an app that acts without asking, that weighs more than the speed.
- **So the level stays medium,** and `mail_sort` must work with thinking on, as planned.
- **Task 4 fails at both levels:** Ornith computes the deadline from the letter's date in five of six runs.
- **Task 2 was asked badly for this purpose:** it does not say "mail", so every run searched files first.
- **Not measured:** the real acceptance tasks 2 and 4 with real mail and a dropped file, a 16 GB Mac, more runs.
