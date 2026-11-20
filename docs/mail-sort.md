# Sorting a large inbox without asking the model to plan

A plan, written on 2026-11-20. Nothing here is built. It follows [pippa-1.0.md](pippa-1.0.md), which shipped
`mail_folders` and `mail_move` and recorded that the AI on this Mac sorts no large inbox.

## Why

Ornith 1.5 9B reads mail well enough and cannot hold a sorting plan across many calls. Over 240 invented mails it
moved none of 190 with tools, with scripts or with both, at 16K, with thinking on or off
([first spike](archive/measurements/pippa-1.0-spike-2026-11-19.md),
[second pass](archive/measurements/mail-sort-ornith-2026-11-20.md)). When the app made the plan and the model only
had to apply it, Ornith moved all 190, none wrongly, in 16 seconds and three calls. That held in three of three runs
with thinking off. With thinking on it held in one of three: the model wants to check the plan, reads the whole inbox
and runs out of room.

So the app makes the plan, the person sees it, and one button applies it. The model's part shrinks to one call.

## What gets built

**One tool, `mail_sort`.** The person asks in the chat or on Pippa Island ("tidy my inbox"). The model calls
`mail_sort` once. The tool, in the app and without the model:

1. reads which senders are already filed where (below),
2. proposes a folder for each inbox mail whose sender is filed in exactly one folder,
3. shows a card: the count per folder with two examples each, how many mails stay, and the buttons
   **Move 190 mails** and **Don't move**,
4. after **Move**, moves them through the `MailMover` that `mail_move` uses: batches of ten, each read back by
   Message-ID, every mail journaled, one receipt and one Undo for the whole answer,
5. returns the verified counts per folder to the model, which reports them.

The card is a preview, not a gate: moving mail stays class `undoable`. It is there because a rule proposes the moves,
not the person and not a model that read the mails, and because it removes the step Ornith fails at. The card uses
the surface `ask` and the Send card already have, in the chat and on Pippa Island.

`mail_move` stays as it is. An online AI with Mac access can still sort by reading, which it does well (190 of 190
on GLM 5.3), and can call `mail_sort` too.

**The rule.** Decided here, to be checked against real mail before anything moves (step 1 below):

- Sender history: for each folder `mail_move` may target, the sender addresses of its newest 200 mails, headers only.
- A sender belongs to a folder when at least two of those mails are from that exact address and no other folder has
  one. No matching by domain: one mail provider's domain would file everybody.
- From the inbox, the newest 500 mails are looked at. A mail is proposed when its sender belongs to a folder.
- Unread and flagged mails stay in the inbox, whatever the sender. Filing must not hide new mail.
- One account per call. Mails never cross accounts, and never go into or below Trash, Junk, Sent, Drafts or Outbox,
  as in `mail_move`.
- The result to the model fits in about 1,200 bytes: counts, two examples per folder, the number staying.

**Not built:** new folders, rules by subject or content, sorting other mailboxes than the inbox, a schedule, a
permanent button outside the conversation. A keyword router that guesses "tidy" before the model sees the message
stays out ([pippa-next-architecture.md](pippa-next-architecture.md)).

## Build order

1. **Read-only probe on real Mail** (`--mail-sort-probe`, built only with `PIPPA_PROBES=1`). It reads sender history
   and the inbox headers and prints numbers only: seconds, folders read, folders that timed out, inbox mails with a
   proposal, and a leave-one-out score over the mails already filed (for each filed mail, would the rule built from
   the others name its folder, name a wrong one, or name none). It prints no sender, subject or folder name and
   moves nothing. Needs the owner's OK, because it reads real mail headers on this Mac.
   **Go on only if** the leave-one-out score has no more than 1 wrong folder in 100 filed mails and the whole read
   takes under 60 seconds. If wrong folders are above that, raise "at least two" to three and measure again. If the
   read is too slow, lower 200 and 500.
2. **`mail_sort` in the app's MCP server:** sender reader with the per-mailbox timeouts `mail_folders` has, the rule
   as a pure function with checks on invented mail, the plan held per answer like `mail_move`'s plans.
3. **The card** in the chat and on Pippa Island, with German strings, and the move through `MailMover` with the
   journal and Undo. Stop during the move behaves as in `mail_move`.
4. **Spike variant `card`** in `scripts/spikes/pippa-1.0/`: `mail_sort` applies after a simulated press. Ornith at
   16K with thinking medium, as shipped, three runs.
5. **Real run** in the folders "Pippa Test A" and "Pippa Test B" on copies, as for `mail_move`, after the owner's OK.

## Acceptance

- Spike `card`, Ornith at 16K, thinking medium: three of three runs move all 190, none wrongly, under two minutes,
  and the answer's counts are the tool's counts.
- A folder that times out is left out of the history and named in the result; nothing is proposed into it.
- Undo after the answer puts every moved mail back in the inbox, checked by Message-ID.
- With no proposal at all, the tool says so and shows no card.

## Step 1, first run (2026-11-20)

`--mail-sort-probe` is built and ran read-only on this Mac's two accounts. It works: 2.4 seconds for an iCloud
account (8 mailboxes listed, 3 read, 4 refused as Trash, Junk, Sent and Drafts), no timeout, nothing changed. It
measures nothing about the rule: the account has 8 inbox mails and 12 filed mails, most of them the copies in the
test folders "Pippa Test A" and "Pippa Test B", and the second account's inbox is empty. Leave-one-out there: 9 right,
0 wrong, 3 without a rule (at least two mails), 6 right, 0 wrong, 6 without (at least three).

The go-on condition is therefore open. It needs one run on a Mac whose Mail holds a real, sorted mailbox:

    PIPPA_PROBES=1 PIPPA_SIGN_IDENTITY='…' scripts/build-app.sh
    open -n -W --stdout sort.json dist/Pippa.app --args --mail-sort-probe --account "<name>"

The report holds numbers only. Still to add before that run: leave the two test folders out of the history.

## Open

1. **Thinking for Ornith: stays medium.** Measured on five everyday tasks
   ([thinking-off-ornith-2026-11-20.md](archive/measurements/thinking-off-ornith-2026-11-20.md)): off is about 2.5
   times faster, not more often right (9 against 10 of 15), and it wrote one event on the wrong day and invented
   details twice, where medium wrote nothing wrong. `mail_sort` is designed to work with thinking on.
2. **How well sender history sorts real mail** is still unknown (see above). In the invented inbox it was perfect by
   construction.
3. **Gmail:** "All Mail" is a folder `mail_move` may target, and every filed mail is in it too, so almost every sender
   would count as filed in two folders. `mail_sort` has to leave it out of the history; how Mail names it is unchecked.
4. **32K** could not be measured on this Mac for lack of free memory.
