# Pippa 0.6: foundation and a memory experiment

Status: implementation started, 2026-11-10. [ROADMAP.md](ROADMAP.md) remains the active roadmap.
The earlier visual exploration is a concept, not a release specification. Tiny apps are out of 0.6.

## Direction

Simplify existing flows and make their failures reproducible. Test whether local photos and calendar can support
useful recall before adding a persistent index, a new tool or a new card. Reuse existing integrations and checks.
A small script-generation probe does not establish that local models are fundamentally incapable; the reason to
defer tiny apps is their implementation and maintenance cost before demand has been demonstrated.

## Work

| Package | Result | Evidence required |
|---|---|---|
| Foundation | Correct existing Mail, Calendar and document behavior where a failure can be reproduced | Focused before/after reproduction plus the relevant repository checks |
| Acceptance | A repeatable run of the five existing tasks, with elapsed times and explicit unresolved outcomes | Timeout, missing permission, missing fixtures and unreviewed answers cannot count as passes |
| Memory experiment | A bounded, read-only local diagnostic using Photos and Calendar; no model or persistent index | Access status, sampled counts, truncation and timings; fixture checks for unavailable and partial data |
| Conditional memory feature | The smallest useful recall flow, only after foundation acceptance and evidence of utility | Correct openable sources for actual questions; observed benefit over existing Photos/Calendar lookup |

The owner delegated test-case selection. Start with clearly labeled technical fixtures and aggregate diagnostics;
do not block that work on a personal questionnaire. Synthetic cases prove behavior, not user preference or product
utility. Real questions and a baseline comparison remain necessary before claiming the memory feature is useful.

## Constraints

- Keep all five [existing acceptance tasks](pippa-next-architecture.md#acceptance). A warning beside an invented
  deadline does not make the deadline task pass.
- No tiny-app runtime, catalog, model allowlist, additional background service or speculative product surface.
- The memory diagnostic must state its date window and limits. Missing or denied access is not an empty library;
  limited Photos access and truncated reads must remain visible. Do not claim whole-library coverage from a sample.
- Read only metadata needed for the experiment. Do not download originals, upload private data or write an index.
  Public reports contain aggregate results, not titles, coordinates, source identifiers or personal questions.
- Use existing access grants without prompting from a headless diagnostic. An unsigned or differently identified
  executable cannot be assumed to have the signed app's grants. Record unavailable access honestly.
- A local calendar entry is a plan, not proof of attendance. A photo's date and coordinates do not establish who
  was there or what happened. Missing metadata stays unknown.
- Any later persistent memory needs explicit opt-in, deletion/revocation behavior and disclosure before recall
  results reach an online model. These are not implemented by the diagnostic.

## Verification and delivery

Use the commands in [development.md](development.md) and fresh evidence for each changed behavior. Keep mocked,
fixture and live acceptance results separate. The signed app's real permissions and source opening need live proof.
No new production tool or card ships before the existing acceptance tasks pass.

Current memory result: the bounded diagnostic and fixture checks are implemented. A direct development-binary run
reported `notDetermined` for both sources without prompting. The signed app launched through LaunchServices used
existing grants successfully: a seven-day sample contained 0 visible Photos assets and 11 Calendar events, in 182 ms.
This proves the granted read path, not whole-library coverage or recall usefulness. Terminal and app launches can
have different macOS permission attribution.

Release verification on 2026-11-10 uses a Mac with **24 GiB**, not the 16 GB acceptance target. The signed baseline
is 0.5.0 build 980. Keep its evidence separate from checks of the release commit:

| Task | Observed baseline | Remaining evidence |
|---|---|---|
| File lookup | Current run failed in 54 s: changed paths caused tool errors, then the answer chose an older snapshot while the expected current file was present | Correct selection and source use; historical passes do not establish current reliability |
| Mail attachments and totals | Historical failure; selection and attachment fixes in progress | Live newest-message selection, distinct message reads and independently checked totals |
| Calendar creation and Undo | One labeled fixture created with a receipt and Undo; Open Calendar opened Calendar; Undo reported removal | First attempt showed a setup error; retry completed in 78 s. A fresh cold start answered normally; the original cause is unresolved |
| Letter deadline | Synthetic letter failed answer-quality review in 97 s; an isolated no-thinking comparison also failed | Correct source quotation and no invented receipt-based deadline; warnings do not count as a pass |
| Five images into one PDF | Five-page PDF in 5.29 s; all pages rendered in order; input hashes unchanged. The window showed its card and opened Finder | Files entered through Open With, not a physical drag; repeat on the release build |

The Mail candidate was also tested through its signed app and the real Pi runtime with a local scripted responder,
without a model. An inbox with five matches returned consistent selections at limits four and three; three selected
message identities read back exactly. Ten attachments (2,683,020 bytes) were saved, with none reported missing,
in 18 s. This proves native selection/read interoperability and attachment availability. The newest-first algorithm
is covered by shuffled synthetic fixtures; the live comparison is not an independent ordering oracle. The original
payment-topic query had no current matches, so payment totals and model behavior remain unverified.

The model setting stays unchanged. There is no production recall feature, persistent index or new card in this
release. The five live acceptance tasks and performance on a 16 GB Mac are not claimed as passed. Reports and raw
transcripts stay local; public evidence contains aggregate results only.
