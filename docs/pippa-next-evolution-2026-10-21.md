# Pippa's next evolution

Decision memo and execution plan · 21 October 2026 · Horizon: 21 April 2027

**Product direction: Pippa turns the thing in front of you into finished work on your Mac.**

This plan starts with a premortem, then makes explicit product bets, implementation priorities and release gates. It assumes one or two core builders, with recruited testers and occasional specialist help. Dates are planning windows; evidence controls expansion. Targets below are proposed decision thresholds, not measured performance or industry benchmarks.

The code assessment uses local commit `2e67358`, based on remote main `601583b`. The reliability changes on this branch have not been established as released behavior. The [engineering assessment](measurements/agent-readiness-2026-10-21.md) records what was changed and tested. This memo adds a strategy; it does not implement or release its proposed features.

## 1. Premortem: it is 21 April 2027 and Pippa failed

People liked the demonstration. They downloaded Pippa, waited through setup, gave her a real task and discovered that they still had to supervise the work. Some received a convincing answer without the expected result. Others could not tell whether trying again would create a duplicate. They returned to familiar apps. We kept shipping capabilities, while useful repeat usage stayed low.

| Failure mechanism | Evidence or exposure today | Early warning | Prevention and decision |
|---|---|---|---|
| The promise exceeded the experience | The README leads with asking anything; capability availability varies by model, permission and execution path | Broad requests fail in the first session; users describe Pippa as a chatbot | Lead with three complete, demonstrable jobs. Expand the advertised scope only after it passes outcome tests |
| Setup consumed the first impression | Model downloads are multi-GB; the permissions page can appear even when the download is deferred | People leave before producing a useful result | Make a native file task usable immediately. Request access when the chosen task needs it |
| One false completion destroyed trust | Receipt handling improved, but uncertain native writes lack durable cross-turn reconciliation; system-prompt wording still equates failure with no effect | “It said done,” duplicate entries, fear of retrying | Persist execution state, verify actual outcomes, preserve uncertainty and resume unfinished steps |
| The Mac still felt inaccessible | Pi can start without native tools when their endpoint cannot be prepared; permission repair does not preserve a resumable operation | Generic “can't do that” replies; retyping after visiting Settings | Check actual capability readiness and provide a task-specific repair that resumes safely |
| Simple work was too slow | A full model is unnecessary for many file operations; Apple-model acceleration is not available on every supported Mac | A user completes the task manually while Pippa is thinking | Route exact work through code; benchmark total task time, cold starts and memory pressure |
| Convenience never became a habit | Many existing utilities solve occasional tasks; chat history does not itself preserve unfinished work | Downloads rise, weekly completed jobs do not | Keep user-selected tasks and offer a short, user-invoked paperwork review |
| Privacy and action promises conflicted with behavior | Blanket approval, Undo and draft-only claims span tools with different enforcement; a broad shell app grant can reach additional app actions | Users discover access or effects they did not expect | One enforced action contract across native tools, Pi, shell and optional online routes |
| Competitors made the headline ordinary | Apple, Raycast, Alter and Dia already cover automation, context and writing assistance | People ask why they need another AI window | Compete on finishing specific work with less setup, fewer decisions and reliable recovery |
| Scope exhausted the team | Every new integration adds permissions, OS compatibility, recovery and support work | More features, slower fixes, inconsistent behavior | Limit work in progress; fund maintenance; require evidence before another integration |
| We measured the wrong success | Automated checks and model scores do not establish that a person received a usable result | Green checks coexist with unresolved user complaints | Observe real tasks; measure accepted outcomes and repeat usage; interview people who leave |

The most dangerous chain is **overpromise → difficult first session → uncertain completion → no return visit**. A larger model only addresses part of this chain.

### What the current evidence actually establishes

- The previous implementation passed 743 native checks, 61 runtime tests and 7 RPC checks. That supports the specific fixes described in the engineering assessment. It does not establish signed-app permission reliability, current end-to-end success rates or retention.
- The [9 October model comparison](measurements/model-compare/README.md) reported 17 complete, 12 partial and 1 failed task across 30 runs for thinking-enabled Qwen3.5-9B. It used older code, Pi 1.1, mocked integrations and one 24 GB Mac. Language mismatches contributed to partial grades. This is historical evidence for improving evaluation, not a score for today's build.
- Existing [tester issue #104](https://github.com/tschnorpfeil/pippa/issues/104) supplies a useful recruitment script. Its comments were empty when checked on 21 October. This does not establish whether private feedback or other testing exists. The next step needs observed users, not an assumption that demand has already been proven.

## 2. Choose the first people who should love Pippa

**Initial audience hypothesis:** nontechnical Mac owners who handle documents and correspondence every week and already use Apple Mail, Calendar and Reminders. Recruit German-speaking household organizers and freelancers first, then compare their actual behavior. Keep English supported and test it separately.

This choice follows existing strengths and lowers integration scope. It remains a hypothesis: interviews must establish task frequency, current effort and willingness to use Pippa again. “Everyone with a Mac” is a long-term reach ambition; this cohort determines the next release.

The public promise to test is: **“Less paperwork. More done. Privately, on your Mac.”** Support it with a visible result, accurate hardware requirements, and the current free, MIT, no-account commitment. State clearly when an optional online service would receive content. Local inference does not prevent Mail drafts or Calendar/Reminder entries from syncing through the person's configured accounts; explain that distinction in the relevant integration setup. Do not claim a task stays local when its selected route does not.

The potential durable advantage is accumulated reliability: native adapters, realistic task cases, recoverable execution, useful preferences and a coherent completion experience. Local models and a polished overlay support that advantage; neither establishes it alone.

## 3. Build three complete jobs

| Job | Concrete experience | Existing foundation | Proposed completion work |
|---|---|---|---|
| **Make these files ready to send** | Drop scans, photos or PDFs; choose order and an attachment size goal; receive one correctly named, openable file | PDF/image tools, compression, OCR exports, results and file Undo | A compact preparation flow, page preview, explicit quality tradeoff, verified output size and destination. Report when the size goal cannot be met acceptably |
| **Help me deal with this letter** | See what it asks, the supporting passages, any explicit deadline, and the appropriate next step; create a requested reminder or prepare a reply | Document reading, cited analysis, letter/reply skills, native reminders and drafts | A persistent task connecting source, extracted facts, chosen action and verified result. Missing dates stay missing; relative dates retain their basis |
| **Deal with this scheduling email** | Read the selected message, resolve the proposed time, check availability, create the requested event and prepare an unsent reply | Mail context, Calendar reads/writes and Mail drafts | Stable source identity, validated time zone and duration, conflict handling, linked native results and recovery if only one step finishes |

These are proposed experiences assembled from existing parts, not claims that their entire flow is already implemented. Understanding a letter does not authorize creating reminders; a request to check availability does not authorize accepting an invitation. Carry the actual user intent through each step.

Each job ends with a result the person can inspect: an artifact, a specific calendar entry, a reminder or an unsent draft. A fluent paragraph is insufficient evidence of completion. Preserve partial progress and show the one useful next action.

Minimal persisted task and execution state is a prerequisite for these jobs. The later task library and weekly-review interface build on that state; they do not defer it. Release and learn from file preparation first, then the letter workflow, then scheduling.

### Fast actions that support these jobs

Keep a broad capability catalog internally, but show two or three relevant choices for the current material. Add at most two new utility actions at a time, selected by observed demand within the three jobs.

| Action family | Execution | Status and next increment |
|---|---|---|
| Photos to PDF, merge, convert and compress | Native code | Existing foundations; connect them into the first hero job |
| Export PDF/photo text | Native extraction and OCR | Added on the current branch; retain page/source labels and explicit unreadable-page handling |
| Remove photo location metadata | Native code | Added on the current branch; describe its actual metadata coverage, not general anonymization |
| Extract selected PDF pages; reorder before combining | Native code | Candidate additions; preview exact pages and produce a separate output |
| Find a recent download; reveal the result | Scoped file search and native navigation | Package existing search/navigation capabilities into obvious actions; preserve actual file identity |
| Clean pasted line breaks or spacing | Code for exact transformations | Candidate action on explicitly supplied text; provide a reversible preview |
| Fix spelling, shorten, improve, summarize, make a checklist | Apple Foundation Models when eligible | Five current small-text actions; retain the bounded fast path and honest fallback |
| Extract proposed tasks and dates from selected text | Constrained model output plus code validation | Candidate action: include supporting text, preserve ambiguity and ask only for missing consequential details |
| Produce receipt/invoice tables and totals | Extraction plus deterministic arithmetic | Build on existing document/CSV work after the first three jobs pass; source each critical field and flag missing values |

Apple-model output is not inherently verified. Schema validity does not establish factual accuracy. Code can validate formats and calculations; source evidence and evaluation must establish extraction quality.

## 4. Make the interaction feel natural

The default experience should be **invoke or drop → understand the context → perform the requested work → show the result**.

1. **Start with something useful.** Open to a file drop or selection action, with “Choose a file” and a clearly labeled sample. A real native task works before the model download. A sample demonstrates the product but does not count as personal activation.
2. **Keep context visible and correct.** Show a compact source chip. Capture the originating file, message or app identity; do not silently switch to whatever is frontmost later. Ask for a new selection when the original target is unavailable.
3. **Make the relevant action obvious.** Offer a few contextual actions; retain other supported actions in the menu. Avoid exposing model names, MCP or execution routes in normal work.
4. **Clarify only what changes the result.** Use a sensible reversible default where possible. Ask when the recipient, destination, date, scope or consequence is materially ambiguous. Bundle related missing details rather than asking once per tool.
5. **Request access in context.** Explain why the specific task needs permission, open the appropriate repair, recheck access and target identity, and resume the unfinished step. A general permissions inventory belongs in Settings.
6. **Show real progress.** Distinguish working, waiting for the person, blocked, partially completed and uncertain. Derive progress from actual work events. Stop prevents undispatched work and accurately reports work that already happened.
7. **Finish where the work belongs.** Make files draggable and revealable. Open the exact native result where supported. Offer insertion into the originating app only when the target can be verified; otherwise present an explicit copy action.
8. **Keep corrections cheap.** “Use my work calendar” or “make that shorter” should operate on the retained task and latest result. Do not restart completed steps. Offer Undo only for operations with a supported, verified reversal.

Keyboard navigation, VoiceOver, text scaling, reduced motion, light/dark appearance and English/German fidelity are part of the same release bar. Reuse [issue #106](https://github.com/tschnorpfeil/pippa/issues/106) for observed first-use accessibility testing and [issue #105](https://github.com/tschnorpfeil/pippa/issues/105) for English fixture coverage. Dictation can use the Mac's established input first; a separate conversational voice stack needs evidence of demand.

## 5. Evolve Pi and Mac access around one execution contract

Keep Pi as the general coordinator. Extend Pippa's existing execution infrastructure instead of introducing a second general agent loop.

### A. Tell the truth about actions

Use one result vocabulary from executor to tool response to persisted task to UI: not dispatched, running, confirmed, partial, failed before effect, and uncertain after dispatch. Replace the contradictory failure wording in [PippaPiLaunch.swift](../app/Sources/PiRPC/PippaPiLaunch.swift). An error alone never establishes that no change occurred.

Retain native target IDs and verify postconditions where APIs permit. [PippaMCPWrite.swift](../app/Sources/PippaCore/MCP/PippaMCPWrite.swift) currently drops useful created-item identity from some results. The UI should make the result inspectable, and Pi should receive the same authoritative state.

### B. Persist enough state to recover safely

Reuse [Executor.swift](../app/Sources/PippaCore/Executor.swift), which already has a durable journal, file fingerprints, native external-operation methods and recovery foundations. Record task/step identity, authorized scope, source fingerprint/version, stable destination account/calendar/list identity, intended operation, dispatch state and native result before advancing the task. Permission recovery must detect a changed source or ambiguous destination before resuming. Avoid persisting unnecessary document content.

Distinguish a retry of the same step from an explicitly requested new action. Equal arguments alone do not imply the same intent. Reconcile unfinished writes after process loss or restart before replaying them. If an API cannot uniquely identify the outcome, preserve uncertainty and offer inspection; do not claim universal exactly-once behavior across macOS APIs.

Native readback establishes the state it actually observes. A locally created entry is not proof of completed account synchronization, remote delivery or acceptance by another person.

The existing [NativeReceiptContext](../app/Sources/PippaCore/NativeReceiptContext.swift) helps conversation continuity. Its bounded prompt context is not a durable execution ledger.

### C. Know what can actually run

Add a capability handshake covering loaded tools, schema version, required app availability and actionable permission state. [PippaMCPService.endpoint](../app/Sources/Pippa/App/PippaMCPService.swift) can currently return nil and leave Pi without native tools. A task requiring missing tools needs a precise repair; unaffected native utilities should remain usable.

A shared catalog should declare accepted input, required capabilities, effects, verification and recovery. Use it for suggestions, task admission and selective tool exposure. Preserve the current Pi lifecycle and loop-guard tests. Bound repeated failures, but retain meaningful progress and provide a clear recovery rather than merely terminating the answer.

### D. Solve problems resourcefully

Performance, problem solving and helpfulness are continuous workstreams from the first release. Reliability makes resourceful execution possible; it must not reduce Pippa to a fixed set of buttons.

For an unfamiliar request, Pi should establish the desired outcome and constraints, inspect relevant context and available capabilities, choose an economical approach, execute, verify, and revise the approach when evidence requires it. Keep this working plan internal unless the person needs to choose between consequential alternatives. Reuse intermediate artifacts and verified results instead of repeating completed work.

When a route fails, distinguish a fixable input issue, unavailable capability, missing authorization and uncertain side effect. A useful alternative preserves the requested outcome and existing authority: for example, extracting a scanned page with OCR when native PDF text is absent, or producing an inspectable reply draft when direct insertion is unavailable. A fallback must not silently broaden access, send private content online or substitute a different task. Ask one focused question when a real decision is needed.

Evaluate held-out combinations of supported capabilities, not only rehearsed workflow scripts. Include changed file names and layouts, missing apps, ambiguous dates, multi-step dependencies and a failed first approach. Compare verified completion, unnecessary tool calls, repeated reads, latency and user intervention against the pinned baseline. A clever solution succeeds with less effort and preserved correctness; a longer chain of tools is not evidence of intelligence.

### E. Improve from evidence and experience

Self-improvement has three concrete layers, delivered in order:

1. **During the task:** detect missing evidence, observe tool results, correct the plan and verify the outcome. Bound retries and preserve uncertain writes. Introduce this alongside the first execution fixes and scenario tests.
2. **For this person:** retain explicit corrections and preferences, with their scope, origin and a visible edit/forget control. After repeated verified success, suggest a reusable routine whose inputs, effects and required access are clear. Store it only with the person's agreement. Add this with the task-library phase.
3. **Across releases:** turn consented, minimized failure reports into synthetic regression cases; compare proposed prompt, skill, routing and model improvements on held-out tasks; ship reviewed, versioned changes with rollback. Start this evaluation loop in week one.

Task content and model self-reflection are not trustworthy instructions for future runs. Do not promote an unverified attempt into a skill, treat repeated behavior as standing authorization, change security rules, install tools, rewrite the application or train on personal content autonomously. Learned preferences remain subordinate to the current request and action policy. General model-weight training is a separate research project, not a promised effect of using Pippa.

Acceptance tests must show that a corrected preference is applied only in its intended scope, a forgotten preference stops affecting behavior, adversarial document text cannot become memory, a reusable routine repeats the verified result without additional access, and an updated skill can be rolled back. Measure recurrence of the original failure and held-out task quality, not the amount of stored memory.

### F. Enforce the same boundaries on every route

- Explicit, small, reversible actions should execute without redundant conversational approval.
- Include Pi's built-in `read`, `edit` and `write` paths in scope enforcement. The shell sandbox does not cover every executor. Start with the routes needed by the first workflow and extend policy coverage before advertising broader guarantees.
- Consequential, ambiguous or bulk changes need a concrete preview. OS permission grants are not authorization for every future operation.
- Mail remains draft-only. Native tools, shell app access, Shortcuts and future GUI actions must enforce that promise. Prompt wording is insufficient; the broad `apps` grant in [shell.ts](../runtime/pippa-tools/shell.ts) needs a constrained replacement for ordinary workflows.
- Keep external sending, purchases and permanent deletion outside the initial product contract. A future scope change needs an explicit product decision and enforceable policy.
- Treat document, webpage, email and tool-returned text as data. It must not expand tool authority, authorize network access, or redirect private content elsewhere. Exercise these boundaries with planted-instruction fixtures, including after permissions have already been granted.
- Prefer typed native APIs and scoped adapters. Use App Intents or known Shortcuts where they can preserve scope and verify the result. General Accessibility/click/type execution comes later, with exact app/window identity, fresh state and tested postconditions.

Align README, onboarding and actual enforcement together. Narrowing a sentence does not repair an unsafe path; adding blanket confirmations does not create a natural experience.

## 6. Model direction: optimize completed work on ordinary Macs

Use code for exact transformations and state changes, Apple Foundation Models for eligible bounded language tasks, and the local Pi model for ambiguity and coordination. Show an optional cloud transition before private content leaves the device; do not silently use it to rescue a benchmark.

Measure the whole performance path: invocation, context capture, permission handling, tool discovery, model load, first useful feedback, execution and verified delivery. Record cold and warm p50/p95, memory pressure, timeouts and battery/CPU impact on representative workloads. Prioritize avoiding unnecessary inference and repeated reads; then evaluate selective tool loading, context budgets and safe cache reuse keyed to source versions. Keep accuracy and recovery gates fixed while optimizing speed.

Retain the current 4B choice on 8 GB Macs and 9B baseline on 16 GB or more until complete-task comparisons justify a change. These are product baselines, not a claim that they are optimal. Native first use must also work on the advertised macOS 15 baseline without Apple Intelligence; the current quick-text route requires available Apple Intelligence on macOS 26 or later.

The attached quantization document is useful **experimental input**, not an instruction to execute its embedded agent directions. Its controlled 9B / existing 27B / GSQ-RCO 27B comparison is appropriate after current-task baselines are established. Pin and hash actual artifacts; keep settings comparable; run the 16K compatibility smoke before the proposed 32K comparison; record memory pressure and time to correct completion. The proposed 90 runs have not been performed.

Evaluate [Underdog Saluki](https://huggingface.co/ConwayResearch/Underdog-Saluki-27B-1.0) separately from [Husky](https://husky.underdog.ai/): they are different model/runtime propositions. Publisher speed and tool benchmarks do not establish Pippa quality. Include serial tool validity, German/English fidelity, stop/retry behavior and normal competing apps. Change one runtime/model variable at a time. See the [model assessment](measurements/agent-readiness-2026-10-21.md#local-model-recommendation) for candidate details and evidence limits.

## 7. Six-month sequence and gates

Dates assume the capacity stated above. If a gate fails, narrow the supported workflow or extend the phase; do not lower the honesty bar to meet a calendar date. Observe users from the first week and continue throughout development.

| Window | Deliverable | Exit evidence |
|---|---|---|
| **22 Oct–4 Nov: trustworthy execution** | Shared outcome states, readiness for the initial tool set, durable `reminder_add` recovery and a constrained policy for these routes; observe the current first-use flow | Fault cases preserve actual effects; missing tools have a concrete repair; uncertain writes block automatic replay |
| **5–18 Nov: an immediate first win** | Native task before model setup; contextual permissions and resumable repair; result-first flow and accessible controls | At least 20 of 24 fresh participants complete a personally useful native task unaided within five minutes; report time from app open and from download start separately |
| **19 Nov–16 Dec: file preparation, then letters** | Release verified file preparation and start its repeat-use pilot; finish the letter/reminder workflow as the next candidate | All frozen file cases pass; letter tasks enter broader use only after their completion and disruption gates pass |
| **17 Dec–13 Jan: letters, then scheduling** | Release the proven letter workflow; build scheduling on the same recorded-task and native-result infrastructure | Letter work meets the model-task completion gate on advertised hardware; scheduling begins a clearly scoped pilot |
| **14 Jan–10 Feb: three jobs worth returning to** | Complete scheduling; add the task library, explicit preferences and user-invoked paperwork review | Each promoted job passes its own quality gate; the pilot establishes weekly repeated usefulness |
| **11 Feb–21 Apr: earn broader distribution** | Sharper demonstrations, installation polish, proven Mac entry points, maintenance support experiments; at most one integration justified by demand | Repeat usage survives beyond novelty, support demand is manageable, and every expanded route matches existing permission, outcome and recovery guarantees |

The first two weeks should not attempt universal crash recovery for every conceivable shell effect. Start with `reminder_add`, test the failure boundaries, then extend the pattern. Full permission repair/resume follows in weeks three and four. Ship restricted capability scope when broad guarantees are not yet enforceable. Secure access to the hardware matrix and pilot participants in week one; absent access, record the affected validation as incomplete.

### Ordered implementation backlog

| Order | Owner role | Concrete work and acceptance condition |
|---|---|---|
| 1 | Core | Canonical outcomes and prompt/tool/UI consistency. A dispatched timeout never becomes “nothing happened”; partial work remains visible |
| 2 | Core | Tool readiness handshake. Missing extension/server/app produces a specific repair, and supported local utilities still work |
| 3 | Core | Route `reminder_add` through the existing durable journal and preserve native IDs. Reconcile identifiable outcomes, resume confirmed unfinished work, and block automatic replay when the outcome remains uncertain |
| 4 | Core | Unified action policy, starting with Mail and shell app access. A draft-only workflow cannot gain send authority through another route |
| 5 | Product + core | Retain the blocked task through permission repair; revalidate source and resume only unfinished work, without retyping |
| 6 | Product | Native first-use path and contextual actions; verify on macOS 15 without Apple Intelligence and on newer supported systems |
| 7 | Product + core | File-preparation workflow with order, size, fidelity and destination checks; use it as the first unassisted activation test |
| 8 | Core + evaluation | Letter and scheduling workflows with evidence, native identity and partial completion. Freeze realistic fixtures before tuning |
| 9 | Product + evaluation | Local outcome records, approved diagnostic export and observed pilot. Run from week one alongside the code backlog |
| 10 | Product | Build the task library, explicit preferences and weekly-review interface on the persisted task state required earlier; verify week-four repeat use |

Roles describe responsibility, not additional assumed headcount. With one builder, sequence core mutations and UI work; use parallel reviewers for evaluation and source research. Keep at most one core change and one experience change in active development.

## 8. Measure usefulness and trust

The primary outcome is **verified useful jobs completed per returning person per week**. Report cohort retention and the share completing no jobs alongside it, so a few power users cannot conceal abandonment.

Separate technical completion from usefulness: an existing output file proves an artifact was created, while an explicit acceptance or observed successful use establishes whether it met the person's need. A click, model answer or tool return alone is not a useful job.

| Measure | Proposed decision gate | Measurement discipline |
|---|---|---|
| First useful result | At least 20 of 24 fresh participants succeed unaided within five minutes after first open | Use their own chosen task; count abandonments and setup failures; label sample-only completion separately |
| Normal workflow completion | At least 95% for each model-dependent hero job and advertised hardware tier; all defined deterministic file fixtures pass | Freeze inputs, input limits, rubric and supported scope before tuning; verify contents, destination and actual native state; report EN/DE separately |
| Trust | Zero observed false completion, wrong-target mutations, duplicate retries or unauthorized egress in the release matrix | Any occurrence blocks the affected capability; finite test coverage is not a guarantee of zero future failures |
| Critical facts | No invented critical names, dates or amounts in the release set | Preserve source spans, mark absence/ambiguity, and fail the action safely when necessary |
| Recovery | Every defined disruption has an accurate outcome and a tested recovery path | Cover denied/revoked permission, closed app, malformed input, timeout, Stop, sleep/wake, process loss and restart |
| Responsiveness | Visible acknowledgement within 200 ms in the measured UI path; target a small native task within two seconds | Define file limits and hardware first; measure OCR separately; report model-task cold/warm p50 and p95 before setting credible budgets |
| Repeat usefulness | At least half of week-one activated users complete useful work in week two; at least one-third do so in week four and at least two earlier weeks | Denominator: participants activated in week one. Also report against all 24 enrolled people, including dropouts; replicate in a larger cohort before broad acquisition |
| Maintenance | Support load and regressions fit the available weekly capacity | Track issue severity, time to repair and hours per active cohort; stop adding integrations if critical defects accumulate |

In parallel, compare new problem-solving behavior with the pinned baseline on held-out combinations of supported actions. Require no regression in critical facts, authorization or recovery, and a measurable gain in verified completion or reduced user intervention. Track usefulness through accepted outcomes and observed time/effort saved. Track learning through fewer repeated failures and correct scoped preference reuse; a self-reported confidence increase does not count.

Start with this explicit normal-task matrix: 30 distinct cases per job, comprising 15 German and 15 English cases; run on 8 GB, 16 GB and a higher-memory Mac with ordinary background apps. Run deterministic file cases once per tier (90 runs) and letter/scheduling cases twice per tier (180 runs per job): **450 normal-task runs across the three staged releases**. All file cases must pass; each model-dependent job/tier must reach at least 95% complete runs, with neither language below that threshold. Count incomplete and failed attempts in the denominator. Check language-matched case coverage separately from repeated execution success.

Measure initial run duration before reserving the full hardware time; budget time for fixture inspection, actual native-state verification and repairs as well as inference. Do not tune on the final held-out cases. Report counts and uncertainty; repeated runs of one case are not independent evidence of broad coverage. This is a starting acceptance matrix, not sufficient evidence for every file type, app or arbitrary request.

Keep a separate disruption matrix: correct refusal or preserved uncertainty can pass that matrix while still counting as an unfinished user job. Retain broader existing regression checks and add boundary cases for advertised file limits.

Use synthetic fixtures for automation and dedicated test accounts/calendars for signed-app acceptance. Include the actual macOS permission dialogs and observed Mail/EventKit effects; mocks cannot establish those behaviors.

Preserve the no-telemetry promise for ordinary users. An explicitly enrolled pilot can use local outcome records and a previewable, user-approved export. Avoid raw content by default. Participation and any research contact are opt-in. This plan does not enroll or message anyone.

## 9. Earn demand and sustain the product

**Before broad promotion:** create a 20–30 second demonstration for each proven hero workflow using synthetic material. Show the input, minimal interaction and actual resulting file or native item. State cuts, waiting or setup honestly. Put supported Macs, download size and capability limits beside the download button.

**Find the initial cohort:** recruit through a small number of relevant Mac communities, household-administration groups and freelance networks. Reuse the existing tester script, shorten it around one real job, and observe where people hesitate. Recruitment is proposed work; no posts or messages are authorized by this document alone.

**Test the message:** compare a specific completed-task demonstration with the generic private-AI introduction. Measure installation to accepted first result, then repeat use. Low conversion suggests messaging/setup problems; high activation but low retention suggests the wrong job or insufficient recurring value. Interview dropouts before adding features.

**Build a useful return visit:** offer a ten-minute review of tasks the person deliberately kept. Remember explicit preferences such as reply tone or chosen calendar, with a visible editor and a forget control. Ask about saving a reusable routine after repeated successful use; do not infer authorization for background monitoring or execution.

**Grow through results:** make completed artifacts easy to use and Pippa easy to recommend. Offer an optional shareable synthetic demonstration or app link. Do not read contacts, send invitations, expose private work, or add forced watermarks.

**Fund maintenance without reversing the product promise:** retain the free MIT core, no account and no subscription requirement. Test voluntary one-time support, sponsorship and separately offered setup/help. Record real willingness to contribute and support cost before forecasting a business model. If upkeep exceeds capacity, narrow supported integrations and stabilize releases before expanding acquisition.

## 10. Explicitly defer

For the next 90 days, defer a broad agent marketplace, dozens of integrations, always-on screen/inbox memory, autonomous sending, general computer control and a model picker as the product's centerpiece. Preserve useful existing features, but prioritize new work that completes the three jobs.

A general GUI route becomes justified when repeated high-value tasks cannot be handled through reliable adapters. A new model becomes justified when it improves complete-task quality within memory and latency budgets. A background routine becomes justified when a person repeatedly performs and explicitly delegates it. Expansion follows those observations.

## 11. Current external evidence

Checked 21 October 2026. These are official project/vendor descriptions, not independent proof of reliability, adoption or comparative superiority. Features may depend on OS, language, region or configuration.

| Source | Verified development | Decision for Pippa |
|---|---|---|
| [Raycast AI extensions](https://manual.raycast.com/ai/ai-extensions) and [2.8 release, 16 October](https://www.raycast.com/changelog/macos/2-8) | Native context/tools and action permissions; selective loading of extension tools in the current release | Context capture and native actions are competitive expectations. Reduce unnecessary tool/context overhead |
| [Apple Shortcuts 27, 29 September](https://support.apple.com/en-tm/149045) | Natural-language shortcut creation on Mac, selected-text input, richer onscreen extraction and persistent storage | Generic natural-language automation is a weak standalone proposition; make complete workflows easier to discover and recover |
| [Dia 1.53, 15 October](https://www.diabrowser.com/changelog/mac/1-53-0) | Immediate reading of referenced page context and deliberation matched to task complexity | Avoid unnecessary thinking and context-fetch delay for simple work |
| [Alter documentation](https://docs.alterhq.com/) and [workspaces/actions](https://docs.alterhq.com/getting-started/automate-with-workspaces-and-actions) | QuickHub, app context and reusable workspaces/actions | A convenient overlay is already a category; deliver the result back into the person's work |
| [OpenClaw repository](https://github.com/openclaw/openclaw/blob/main/README.md) | Local state, model choice, tools and extensibility | Ownership alone is not unique; reduce setup and operational responsibility |
| [Pi 1.3.0](https://github.com/earendil-works/pi/releases/tag/v1.3.0) and [RPC contract](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md) | Tool validation and lifecycle details relevant to execution | Keep one pinned core and real protocol regression coverage |
| [Peekaboo automation](https://github.com/openclaw/Peekaboo/blob/main/docs/automation.md) | Explicit treatment of dispatch, partial effects and uncertainty | Reuse these principles before expanding GUI control |
| [MacAgentBench](https://github.com/JetAstra/MacAgentBench) | Outcome-oriented Mac task evaluation | Borrow the evaluation approach; maintain a smaller Pippa-specific suite tied to advertised jobs |
| [Apple Foundation Models utilities](https://github.com/apple/foundation-models-utilities) | Native model utilities for skills/context | Evaluate for bounded fast paths without creating another general loop |
| [Sky](https://sky.app/) | The official site says Sky is joining OpenAI | Do not present it as a verified currently downloadable independent alternative |

The first execution package is outcome alignment, readiness for the initial tools, durable `reminder_add` recovery and a constrained policy for those routes, alongside observed baseline tasks. The following package adds resumable permission repair and a real native result before setup. Broader claims and distribution wait for demonstrated completion and repeat use.
