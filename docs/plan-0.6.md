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

Current memory result: not measured. Historical probes inform questions to investigate; they are not new test results
or grounds for public performance claims. Release preparation follows [releases/README.md](releases/README.md).
