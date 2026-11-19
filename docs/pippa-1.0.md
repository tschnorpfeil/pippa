# Pippa 1.0: she acts, and you can take it back

Status: decided, 2026-11-19. Builds on [Pippa next](pippa-next-architecture.md); where things stand is in
[ROADMAP.md](ROADMAP.md). Measurements behind the decisions:
[archive/measurements/pippa-1.0-spike-2026-11-19.md](archive/measurements/pippa-1.0-spike-2026-11-19.md).

The owner agreed to all seven points under [Decided by the owner](#decided-by-the-owner) on 2026-11-19.

## The idea

Pi stays the harness, over RPC, as in Pippa next. Three things change:

1. **Pippa acts by default.** What can be taken back runs without a question.
2. **Gates are technical and few.** A question comes only before something that cannot be taken back or that leaves
   this Mac. The gate is decided by a class each tool carries, checked in code. No model judges it.
3. **Every run leaves a record.** Each action is written down before it starts, checked against the real source
   afterwards, and a whole run can be undone.

Not in 1.0: a channel bot, a hosted variant, a permanent-delete tool, payments.

## What the evidence says

| Question | Finding | Source |
|---|---|---|
| Is pi-durable in Pippa's Pi? | No. `metadata.json` lists it as part of the release, but the payload installs only what `pi-coding-agent` depends on: `pi-agent-core`, `pi-ai`, `pi-codemode`, `pi-mcp`, `pi-schema`, `pi-telemetry`, `pi-tui`. The lockfile has no `pi-durable`, and `pi-coding-agent` never imports it. | `app/Packaging/pi-release/package-lock.json`; payload built with `scripts/bundle-pi-payload.sh` |
| How stable is pi-durable? | Its README opens with "Experimental. The API changes without notice between releases." | pi-durable 1.5.0 README, line 3 |
| Does pi-durable manage a small context better? | It has the same compaction knobs Pi already has (`reserveTokens`, `keepRecentTokens`), plus forks, subagents and documents. No history search tool is in the 1.5.0 README. | pi-durable 1.5.0 README |
| Do gates hold inside a codemode script? | Yes. "Every MCP call passes through Pi's tool pipeline. Extension `tool_call` and `tool_result` handlers, including permission gates, therefore apply to MCP tools." Nested calls carry `parentToolCallId`. | Pi 1.5.2 `docs/mcp.md` |
| What can a script reach? | Only the session's tools. "No Node APIs, file system, network, or timers." 256 MB, no default deadline. | Pi 1.5.2 `docs/codemode.md` |
| What does a script get from a Pippa tool? | The whole `CallToolResult` with `structuredContent`. Only the script's output reaches the model. | Pi 1.5.2 `docs/mcp.md`, `docs/codemode.md` |
| Why did the 429 run stop silently? | Pi retries three times after 2, 4 and 8 seconds (`retry.maxRetries` 3, `retry.baseDelayMs` 2000). That is 14 seconds against a one-minute limit. Pi honors `Retry-After` only in provider-level retries, which are off by default. Pippa reads no `auto_retry_start` event. | Pi 1.5.2 `docs/settings.md`, `docs/json.md`; `PiRPCClient.swift` |
| How many tools does the model see today? | 22 with everything on: 3 from Pi, 5 file tools, 2 web tools, 12 MCP tools. Rule 3 says about 12. | `PippaPiLaunch.tools`, `pippa-mcp.ts` |

The spike ran one mail triage (240 invented mails, seven folders, a synthetic Mail server) on Ornith 1.5 9B with a
16K window, one run per variant:

| Variant | Mails moved (of 190) | Wrong moves | Time | How it ended |
|---|---|---|---|---|
| Tools declared, pages of 20 | 0 | 0 | 429 s | Answer limit, after 6 of 12 pages and 12 failed calls |
| Codemode only | 0 | 0 | 635 s | Answer limit; 3 of 10 scripts failed |
| Tools and codemode | 0 | 0 | 280 s | Memory guard; the model chose a script by itself |
| Tools plus a dry run without the model | 0 | 0 | 784 s | Answer limit; had the plan after two calls and never applied it |

- One script read all 240 mails in 0.1 seconds and returned 100 characters. Codemode solves the reading problem.
- Ornith then failed at the next step every time: carrying a plan across several calls.
- Pi reported the calls made inside scripts with `parentToolCallId`, and scripts received `structuredContent`.
- GLM 5.3 on the same harness sorted all 190 mails correctly in every variant; with codemode it needed a third of
  the prompt tokens.
- Not measured: a 32K window, repeated runs, a gate question inside a script, real Mail.

## Action classes

Every tool belongs to exactly one class. The class is a constant next to the tool's definition, in one table in the
app. A tool without a class does not run.

| Class | Meaning | Gate | Journal |
|---|---|---|---|
| `read` | Changes nothing. | None beyond the macOS permission and the online sharing rules. | No |
| `undoable` | Changes something on this Mac that Pippa can put back herself. | None. Runs at once. | Entry before the call, verified after, undo recipe stored |
| `irreversible` | Cannot be put back: deleting for good, emptying the Trash, overwriting without a copy. | A card with the exact objects, every time. | Entry with the person's yes |
| `external` | Leaves this Mac or reaches someone else: sending mail, an invitation, a message, a payment, a form in the browser, a command that goes online, sharing with an online AI. | A card with the recipient and the exact content, every time. | Entry with the person's yes |

How the gate is enforced:

- **In the app's MCP server**, before the tool body runs. For `irreversible` and `external` the server asks the app
  for a confirmation, the app shows the card, and the answer comes from a button. Tool arguments and model text
  cannot supply it. Headless runs (`--ask`) answer no.
- **In Pi**, for the tools that live there (`bash`, `write`, `move_files`, the web tools): the existing `tool_call`
  hook and the shell sandbox. The hook also sees calls from codemode scripts.
- **By absence.** The strongest gate is no tool. 1.0 has no tool that deletes for good and none that pays.
- **MCP annotations follow the class** (`readOnlyHint`, `destructiveHint`, `openWorldHint`), so they cannot drift:
  one check asserts that every listed tool has a class and that its annotations match.
- **A check proves the gate by behavior:** a call to an `external` tool without a pressed button never dispatches,
  direct or from a script.

Where undo cannot be proven, the action is not `undoable`. That is why two existing questions stay:

- A shell command that changes files in the person's folders. Pippa copies only the files the command names, so she
  cannot promise to put everything back.
- A shell command that goes online. Today one yes covers the rest of the answer. In 1.0 it covers one command, like
  every other `external` action, because a later command in the same answer could send what an earlier tool read.

### What "acting by default" loosens

[Privacy and permissions](privacy-and-permissions.md) says: "When you ask for a specific action, she carries it out."
1.0 widens that: Pippa may take undoable steps the request implies without being asked for each one. "Tidy my inbox"
moves mails. "Prepare tomorrow" may add a reminder. The system prompt line "Where a change needs a yes, Pippa asks
the person herself; do not ask first" stays and now covers more. The `ask` tool stays for real choices.

This applies to the AI on this Mac and to an online AI with **Allow Mac access**. An online AI without that grant
keeps today's limits. The gate does not depend on the model, so no model class gets a weaker gate.

**The AI on this Mac.** Acting by default is acceptable with Ornith because the limit on damage is the undo and
the check against the source, not the model. In the spike Ornith moved nothing wrongly; it moved nothing at all.
What 1.0 does not promise is that Ornith finishes large jobs. When a run ends unfinished, Pippa says what was done
and what was not, from the journal, and offers the online AI for that one job (**Ask [provider]…** exists).

## Tools in 1.0

Today, with everything on, the AI on this Mac sees 22 tools. 1.0 changes this:

| Tool | Class | Change | Why |
|---|---|---|---|
| `mail_folders` | `read` | New. The folder tree per account with counts and two sample mails per folder. | Sorting into existing folders is impossible without seeing them. In the terminal session Pi built this view itself with AppleScript. |
| `mail_move` | `undoable` | New. `refs`, `to`, `dry_run`. A dry run returns counts per folder and a `plan` id; applying takes the `plan` id. More than 20 mails need a plan. Moves go in batches, each batch is verified in the target folder by Message-ID, and the run stops at the first mismatch. | There is no way to move mail today. The plan id makes the dry run a fact the tool enforces and saves the model from sending 200 refs twice. |
| `mail_search` | `read` | `limit` up to 100 with header-only rows (ref, sender, subject, date). The existing per-result character cap still applies, so a direct call returns as many rows as fit. | Rule 4 limits what the model reads. A script that filters 240 rows hands the model only its summary. |
| `codemode` | by the tools it calls | Pi's built-in tool, active where the measurement supports it (see below). | Loops, filters and dry runs without the shell and without giving up a gate. |
| `mail_send` | `external` | New, last step, only if the owner agrees. Sends one draft Pippa saved in this conversation, after a card with recipient, subject and text. | The gate has to carry one real external action, or it is untested. |
| All others | as today | Unchanged. `calendar_add`, `reminder_add`, `mail_draft`, `move_files`, `write` are `undoable`; `browse`, `web_search`, `fetch_content` keep their own questions. | |

Deviations from the rules of Pippa next:

- **Rule 3 (about 12 tools).** Today's 22 already exceed it. 1.0 adds three or four. With codemode in `only` mode
  the model sees one tool and a list of declarations inside its description (budget 3,000 estimated tokens,
  `codemode.inlineBudget`). Rule 3 becomes: one purpose per tool, one way per job, and the fixed prompt prefix for
  the AI on this Mac stays under a measured token budget instead of a tool count.
- **Rule 4 (at most 20 entries).** Stays for everything the model reads. A script may read more, because its
  intermediate results never enter the context.
- **Rule 7 (no new tool until the five tasks pass).** Two of five pass on Ornith today. 1.0 keeps the five tasks as
  the release gate but no longer as a gate for starting work, because the new tools are what the sixth task needs.

## Shell and app control

The shell stays, and it stays closed to other apps. The sandbox the system enforces already denies sending Apple
events, starting `osascript`, `open`, `shortcuts` and `automator`, and looking up Mach services outside a short
allowlist (`runtime/pippa-tools/shell.ts`). The word check before a command runs is a courtesy; the sandbox is the
gate.

For 1.0:

- **No Mac app access from the shell.** Changes to Mail, Calendar and Reminders go only through classed MCP tools.
  This closes the way around a gate that an open shell or AppleScript would be.
- **Scripts get no extra reach.** A codemode script can call `bash`, but it gets the same sandboxed tool, and the
  hooks run for nested calls. One check runs `osascript` from a script and expects the refusal.
- **Deleting for good stays impossible** outside the working and temporary folders (`deny file-write-unlink`).
- **Going online is asked per command** (see above).
- **Known rest:** a command the person allowed online can send what it was given. The card says so.

## Journal, verification and undo for whole runs

A run is one answer. The pieces exist and are joined, not rebuilt: `journal.sqlite` (reminders today), the write
scope with its `dispatched` state and operation ids (`PippaMCPWriteScope`), receipts with undo for events and
reminders, and `pippa-change` entries for file changes.

- **One journal.** `journal.sqlite` gets one row per action of every `undoable`, `irreversible` and `external` tool:
  run, order, tool, class, the object's stable identity, where it was before, where it is after, and a state.
- **Written before the call.** States: `planned`, `dispatched`, `done`, `unclear`, `undone`, `undo_failed`. A row is
  `dispatched` on disk before the native call starts. If Pippa or Pi dies, the row stays `dispatched`; the next
  start shows it as "unclear, please check" and never repeats it. That is the guarantee pi-durable gives with
  `interrupted`, placed where the truth is.
- **Checked against the source.** After each action Pippa reads the object back by its stable identity: a mail by
  its Message-ID in the target mailbox (Mail's own id changes on Exchange), an event or reminder by its EventKit
  identifier and fields, a file by path, inode and hash (`DurableFileIdentity`). The tool result reports
  `verified n of m`. The model can only repeat that number.
- **Mismatch stops the run.** A mail that is neither in the inbox nor in the target folder makes the batch
  `unclear`, and no further batch starts. This is the case of the three mails that ended up in the wrong archive.
- **One receipt per run** under the answer: "187 mails moved into 5 folders, 187 checked. Undo".
- **Undo per run** goes backwards through the rows. Each step runs only if the object is unchanged since Pippa
  touched it, as the calendar undo does today. The result is counted: undone, left because changed, failed. The
  model learns of it with the next question, as today.
- **Kept 30 days,** like the backup copies.

Open: how Mail moves behave per account type. The terminal session saw rejected batch moves, partial single moves
and new ids on Exchange. Before `mail_move` is built, a spike on a test mailbox per account type (iCloud, Gmail,
Exchange) measures: move one by one through the app's Apple Events queue, verify by Message-ID, move back. It needs
a test account and the owner's OK, because it moves real mail.

## Rate limits and resuming

- **Wait long enough.** Pippa sets Pi's retry so the waits span a one-minute limit: `retry.baseDelayMs` 15000 and
  `retry.maxRetries` 4 give 15, 30, 60 and 60 seconds (`retry.maxAgentDelayMs` stays 60000).
- **Show it.** `PiRPCClient` reads `auto_retry_start` and `auto_retry_end`. The chat and Pippa Island show "The
  online AI is at its limit. Continuing in 42 s", with Stop (`abort_retry`).
- **Tell rate from quota.** Today both become "limit reached". A rate limit waits and continues. A used-up quota
  says so and offers the AI on this Mac.
- **Resume, don't restart.** If the retries run out, the session is still there. The answer ends with **Continue**,
  which sends one follow-up after at least 60 seconds. The journal tells the model what is already done, and the
  loop brake refuses a repeated change.
- **First step is a check.** A scripted provider (as in `scripts/pi-rpc-smoke.mjs`) answers 429 twice and then 200.
  Whether today's app waits, shows anything and resumes has not been checked.

## Codemode

Decision per model class:

| Model class | Default in 1.0 | Basis |
|---|---|---|
| The AI on this Mac (Ornith 1.5 9B) | `direct`, codemode off | Measured: scripts did not make it finish, 3 of 10 failed, and one script put 15,102 characters into a 16K window. |
| Online AI with Mac access | Tools declared and `codemode` active (`codemode.mode: "on"`). | Measured on GLM 5.3: 190 of 190 mails right in every variant; with codemode a third of the prompt tokens (36,546 against 112,286) and 6 model turns instead of 15, no failed script, and the model chose scripts by itself. |
| Online AI without Mac access | No change: it has no reading tools to script. | |

The five acceptance tasks with `PIPPA_MCP_EXPOSURE` in both settings decide whether this default ships: none may
get worse.

Still to check before codemode ships for any class:

- A gate card in the middle of a script. Scripts have no default deadline, so a wait is not cut off, but it has not
  been tried.
- Receipts and cards for calls made inside a script. The events arrive; the app's card code has not seen them.
- The call budget (`MAX_CALLS` 20, 80 with Mac access) counts nested calls today, because the hook sees them. A
  script that pages through an inbox needs its own bound.
- `discoverNativeTools` in `pippa-mcp.ts` accepts only `direct` and has to learn the second setting.

A finding beyond codemode: a dry run needs no model. The spike's `mail_sort` proposed a folder for each mail from
the senders already filed there, in one call. Ornith did not use it well, but under rule 5 of Pippa next it can be
a button in the app. Whether sender history is good enough on real mail is unmeasured; it is a candidate for after
`mail_move`, not part of 1.0's scope.

## pi-durable

Decision: not in 1.0.

- **It is not there.** Using it means adding a package to the pinned Pi and programming against a second runtime
  (its own harness, conversations and storage) next to the `pi` RPC process Pippa talks to. Sessions, skills,
  compaction and the RPC contract of `pi-coding-agent` do not carry over.
- **It is experimental.** Pippa pins one Pi release and moves to the next through gates. An API that changes without
  notice breaks on every bump.
- **It does not solve the context problem.** Durability and a 16K window are different problems. For the window
  pi-durable offers what Pi already has. And the measurement shows the window is not what stops Ornith: with
  the whole inbox reduced to 25 tokens it still did not finish.
- **The durability Pippa needs is narrower** and has to live in the app anyway: an action that cannot be repeated
  must not be repeated, and its state must be known after a crash. The journal above does that against Mail and
  EventKit. A replayed script does not check whether the mailbox changed in the meantime.

Watch: when `pi-coding-agent` itself builds on pi-durable, it arrives through RPC without work in Pippa. Review at
each Pi bump. Small fix now: `THIRD_PARTY_NOTICES.md` names `pi-durable` and `chord`, which the payload does not
contain.

## Acceptance for 1.0

On a 16 GB Mac with Ornith 1.5 9B at 16K, and with one online AI with Mac access:

1. to 5. The five tasks of [Pippa next](pippa-next-architecture.md#acceptance).
6. **Mail triage.** A test mailbox with at least 200 mails and existing folders. "Tidy my inbox": a dry run with
   counts per folder, then the moves. Pass: every moved mail is found in its target folder by Message-ID, no mail is
   anywhere else, the receipt shows the same numbers, and Undo restores the inbox count.
7. **Gate.** "Send it": a card appears, and nothing is sent without the button, also from a script and in a headless
   run.
8. **Rate limit.** A scripted 429: a visible wait of at least 60 seconds, then the answer finishes.
9. **Crash.** Pi is killed in the middle of task 6: the journal shows what is done and what is unclear, and Continue
   repeats nothing.

Task 6 must pass on the online AI. On Ornith, which moved nothing in the spike, the pass is narrower: no mail ends
in a wrong place, the answer says what was and was not done, and it matches the journal. If the owner wants the full
task 6 on Ornith as a release gate, 1.0 waits for a better local model.

## Order

Each step is one pull request.

1. **Notices.** Correct the Pi package list in `THIRD_PARTY_NOTICES.md`.
2. **Rate limit.** The scripted 429 check, retry settings, retry events as status, Continue.
3. **Action classes.** The class table, the fail-closed check, the confirmation path in the MCP server. Existing
   tools get their class; going online from the shell is asked per command.
4. **Run journal.** All classed actions in `journal.sqlite`, written before the call; the run receipt; Undo for a
   whole run; the unclear state after a crash.
5. **Mail spike** on a test mailbox, then `mail_folders` and `mail_move` with plan, batches, verification and undo.
6. **Codemode** for the model classes named above: readiness accepts it, nested calls show as steps and count
   against a budget, measured on the five tasks and the triage.
7. **Acting by default** in words: the system prompt line, [Privacy and permissions](privacy-and-permissions.md),
   the German site.
8. **`mail_send`** behind the `external` gate, if agreed.
9. **Acceptance** on both model classes, measurements filed, release.

## Decided by the owner

All agreed on 2026-11-19:

1. **Acting by default** changes the sentence in Privacy and permissions quoted above.
2. **Rules 3, 4 and 7** of Pippa next change as described under Tools.
3. **`mail_send`** ends "She never sends your mail": the last step, one draft at a time, behind the card.
4. **Going online from the shell is asked per command** instead of per answer.
5. **Test folders for the Mail spike:** two folders "Pippa Test A" and "Pippa Test B" in one account, with copies of
   up to 20 old mails. Only these copies move. The inbox and existing folders stay untouched.
6. **Paid measurement** of the triage and the five tasks on the online AI (privatemode GLM 5.3), to decide codemode
   there.
7. **Task 6 on Ornith** passes if nothing is misplaced and the answer is honest.
