# Pippa vision: the calm, private personal AI agent on Mac

Status: direction, 2026-11-23. It sets the north star for the plans in [ROADMAP.md](ROADMAP.md). Where things stand today
is in the roadmap; how Pippa works is in [Pippa next](pippa-next-architecture.md) and [Pippa 1.0](pippa-1.0.md).
Measurements for the local AI are in [local-ai-research-2026-11.md](local-ai-research-2026-11.md).

## 1. North star

Pippa is a private chief of staff that lives on one Mac. She works inside the person's own Mail, Calendar, Reminders,
Notes, Contacts, Safari, Photos and Files, with the AI on this Mac by default.

Cloud-VM agents run in someone else's browser and someone else's account. Pippa runs where the mail, the files and the
sign-ins already are, so nothing has to be uploaded, shared or re-authorised for her to be useful. The cost is that she
is limited to what one Mac and its apps can do. We accept that.

What this means in practice:

- **Private by default.** Nothing leaves the Mac unless the person turns an online AI on, and then per source.
- **Calm.** She answers when asked, shows progress, and does not interrupt. Proactive help is opt-in (section 5).
- **Acts, and can be taken back.** What can be undone runs at once and is journaled. What cannot be undone or leaves the
  Mac waits for a button. The gate is an action class checked in code, not a judgement by the model
  ([pippa-1.0.md](pippa-1.0.md)). The RunJournal undoes a whole run with one button.
- **No model picker.** Pippa chooses the model for this Mac. The person is never asked to pick a quantisation.
- **For non-developers.** No terminal, no developer tools, no approval storms.

## 2. Build for 2027 local models

Today's 9B model on a 16 GB Mac is the floor, not the target. Local models improve every quarter, so Pippa is built for
the models of 2027 and does not carry workarounds that only a 9B model needs.

- **No throwaway 9B workarounds.** A prompt rule for one observed failure, a router that guesses intent, or a patch on the
  model's answer is rejected ([pippa-next-architecture.md](pippa-next-architecture.md#rules)). If the model cannot do a
  task, the fix is a better model, a better tool, or the online AI.
- **Models are data.** The model list is `catalog.json`, swappable via a catalog entry without changing the app's code. The runtime is oMLX. A new
  model enters only after an automated gate (the acceptance tasks and the prompt-budget check) passes on it.
- **Code does what code does better.** Arithmetic, dates, totals and sorting belong to helpers (`compute`, document
  tools), not to the model. This is tool quality: tools return facts, the model decides what to do with them.
- **Smaller tool results.** The prompt budget is the scarce resource on 16 GB, so tools return less and more precise text.
- **Optional online escalation.** When a task needs more than the local model can do, Pippa can offer the online AI the
  person has set up, with the per-source sharing review. It is never the default and never silent.

## 3. Apple Foundation Models as the Tier-0 reflex

Apple's on-device model costs no extra memory and answers in about half a second, but its context is 8K tokens and it
sometimes refuses ([local-ai-research-2026-11.md](local-ai-research-2026-11.md#apple-foundation-models)).

- **Used for:** conversation titles in 1.1; later, triage of state differences for the watchers in section 5 (did anything
  change that is worth a look).
- **Never the main agent.** Short context, no tool loop, refusals on harmless health questions. It does not answer the
  person's question.
- **Fallback is mandatory.** Where Apple Intelligence is off, the language is unsupported or the model refuses, Pippa uses
  the local or online AI, or a plain first-line title. No feature depends on it being there.
- **Only a reflex.** Nothing it produces is shown as a finding without the main AI or a person behind it.

## 4. Deep Apple integrations, without Full Disk Access

Pippa never asks for Full Disk Access. One broad permission that reads everything is the opposite of a calm, private
assistant, and a non-developer cannot judge it. The order of means:

1. **Native frameworks first.** EventKit (Calendar, Reminders), Contacts, PhotoKit, security-scoped file access. They
   have per-app permissions macOS shows by name.
2. **Bounded in-process Apple Events second.** Mail, Notes and Safari have no framework for what Pippa needs. She
   sends a fixed set of Apple Events from the app process, so macOS asks for "Pippa". Scripts are fixed in the app. The
   model never writes AppleScript, and the person's Automation list stays short and readable.
3. **Read-only Accessibility third.** For what is only on screen (the app in front, a Safari tab without a scripting
   path). It reads, never clicks or types, and the shell does not inherit it.

**Boundary.** Pippa does not read `chat.db` (Messages), Mail's or Notes' databases, or any app's files on disk. A feature
that would need Full Disk Access is not built; it is listed as "not possible" until Apple offers an API. Messages stays
out for this reason.

| App | Through | In 1.1 |
|---|---|---|
| Mail | Apple Events | existing tools; `mail_sort` after the real-mail probe |
| Calendar | EventKit | `calendar_update` with Undo |
| Reminders | EventKit | `reminder_update` with Undo |
| Notes | Apple Events | read-only `notes_read` |
| Contacts | Contacts framework | `contacts_search` |
| Safari | Apple Events, Accessibility | multi-tab `front_read` |
| Photos | PhotoKit | existing tools |
| Files | search, security-scoped access | compact document reading |

## 5. Calm proactivity (1.2)

Pippa may speak first only under a contract the person can read and switch off. It is opt-in, off until chosen.

- **Zero-token watchers.** Plain Swift code watches for changes (new mail from a person on a list, a calendar entry
  moved, a folder that received a file). Watching costs no model tokens. The model runs only when something changed.
- **Morning Brief.** One short overview a day, built as a durable job (`DurableJobKind.morningBriefing`), on Pippa Island,
  at a time the person sets.
- **Strict cap.** At most one or two nudges a day in total, Brief included. When the cap is spent, the rest wait.
- **Focus-aware.** No nudge while a Focus is on. It waits for the Focus to end.
- **Human-closed tasks.** Pippa opens a task ("reply to the landlord") and only the person closes it. She does not
  decide that a thing is done.
- **One-click mute.** Every nudge carries a mute for its kind, and one switch turns all of them off.
- **Idle dreaming is 2.0.** Using idle time to organise notes and prepare drafts needs more memory and trust than 1.2
  has earned. It is not part of 1.2.

## 6. Phases

| Phase | What lands | Gate |
|---|---|---|
| **1.1** | Prompt-budget gate, compact document reading, `compute`, `calendar_update` and `reminder_update` with Undo, `notes_read`, Safari multi-tab, `contacts_search`, Apple FM conversation titles, zero-friction first run, `mail_sort` after the real-mail probe | The five acceptance tasks and the prompt-budget gate pass |
| **1.2** | Calm Morning Brief, human-closed tasks, voice brain dump, watched folder, shootout of local models for Macs with 32 GB or more | The contract in section 5 holds on a week of real use |
| **2.0** | Idle dreaming, life memory if the usefulness experiment supports it, models of 2027 as the default | Decided when 1.2 has shipped |

The dates are not promised. The order is.

## What this is not

- Not a developer tool, not a coding agent, not a chat client for many providers.
- Not a hosted service. There is no Pippa account and no Pippa server that sees the person's data.
- Not a replacement for the person's judgement. She prepares, acts where it can be undone, and asks where it cannot.
