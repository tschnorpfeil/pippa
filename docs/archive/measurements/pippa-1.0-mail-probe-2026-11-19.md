# Pippa 1.0: mail moves on a real account

2026-11-19, for [pippa-1.0.md](../../pippa-1.0.md). `Pippa --mail-move-probe` on one iCloud account (IMAP) in a
Developer ID build, so the app's own Mail permission applied. It touched only two folders made for it, "Pippa Test A"
and "Pippa Test B", and copies of six old inbox mails. The inbox and every other folder stayed as they were. The
report holds counts and times only. The probe exists only in debug builds and builds made with `PIPPA_PROBES=1`.

## What the runs showed

| Run | Build | Move A to B | Read-back | Undo | Final state |
|---|---|---|---|---|---|
| 1 | first version | Mail said "moved" 6 times | 5 of 6 at once | 4 undone, 1 failed, 1 unclear, 34.5 s | 5 in A, 1 in B |
| 2 | waits for Mail to settle | 6 moved, 2.3 s | 6 of 6 | reported 6 failed after a 30 s lookup timeout | all 6 back in A |
| 3 | timeouts are "not known yet" | 6 moved, 2.7 s | 6 of 6 | 6 undone, 3.3 s | as intended |
| 4 | after the review fixes | 6 moved, 3.3 s | 6 of 6 | 6 undone, 3.5 s | as intended |
| 5 | after the second review round | 6 moved, 3.8 s | 6 of 6 | 6 undone, 3.9 s | as intended |
| 6 | after the third review round | Mail did not answer during the move (82.9 s) | 1 of 6, 5 unclear | 1 undone | as intended: the 5 unclear mails had not moved |
| 7 | Undo needs an established identity | 6 moved, 4.2 s | 6 of 6 | 6 undone, 4.3 s | as intended |

Runs 3, 4, 5 and 7 ended with six live mails in A, none live in B, no mail in both folders, and the same picture 45
seconds later.

## What Mail does

- **Mail's own ids change on a move,** also on iCloud, not only on Exchange. The Message-ID is the only identity
  that holds.
- **A moved mail leaves a leftover behind.** The source folder keeps an entry with `deleted status` until Mail
  expunges it. Counting it as a mail made run 1 see doubles. Only live messages count now.
- **A moved mail shows up in the target a moment later.** One immediate lookup is too early (run 1). The read-back
  now looks again every second, for 20 seconds per batch.
- **Mail sometimes does not answer for a folder that just changed.** Lookups on the test folders timed out after 5
  to 30 seconds in about half of the probe starts made within a few minutes of an earlier run, and in none after a
  five-minute pause. A lookup that times out is "not known yet": the wait goes on for up to 60 seconds, then the row
  is unclear and is read once more at the end of the answer and at Undo. In run 2 the Undo had worked while the
  report said failed; that is fixed. A stall can also hit the move event itself (run 6); the rows then stay unclear
  until the later read.
- **The first question after starting the app sometimes times out** (5 of 14 starts). The probe asks once more; the
  cause is unknown.

## Not checked

- Gmail and Exchange accounts.
- More than one batch (the test had six mails).
- A whole triage on real mail through the model.
- `mail_folders` on an account with many or very large folders: the listing of 8 folders took 2 seconds.
