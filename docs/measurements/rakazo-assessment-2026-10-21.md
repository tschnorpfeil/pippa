# Rakazo: useful patterns for Pippa

Research date: 21 October 2026. Reviewed Rakazo commit: [`4dd95da0adc7c16f848b8ff6c865af78e3b21bd5`](https://github.com/elie222/rakazo/commit/4dd95da0adc7c16f848b8ff6c865af78e3b21bd5).

**Decision: study and adapt its memory, reusable-procedure and evaluation patterns while retaining Pippa's native Mac architecture and Pi core.** This is a read-only source assessment. No Rakazo code was installed, executed or copied into Pippa, and its reported live evaluation results were not reproduced.

## What Rakazo actually provides

Rakazo is a beta platform for persistent agents built around Pi, with React/Electron/Expo clients, a TypeScript API and worker, PostgreSQL/Prisma persistence, Graphile Worker jobs, and selectable model/computer providers. The local desktop setup starts a Docker Compose backend. Its root license is Apache-2.0. These are meaningful architectural differences from Pippa's native Mac application; adopting the entire platform would add substantial infrastructure. [README](https://github.com/elie222/rakazo/blob/4dd95da0adc7c16f848b8ff6c865af78e3b21bd5/README.md), [computer runtime](https://github.com/elie222/rakazo/blob/4dd95da0adc7c16f848b8ff6c865af78e3b21bd5/docs/computer-runtime.md), [license](https://github.com/elie222/rakazo/blob/4dd95da0adc7c16f848b8ff6c865af78e3b21bd5/LICENSE).

| Area | Verified implementation | Pippa implication |
|---|---|---|
| Memory | Scoped Markdown documents, revisions, transactional writes, conflict checks and source run/thread identities; optional semantic providers | Add origin, scope and correction history to personal preferences; retrieve only relevant records |
| Skills | Agent tools create, read, update and delete user skills; built-in/plugin skills remain read-only | Let a successful procedure become a proposed reusable routine with a visible version and rollback |
| Teaching | Recorded actions become editable playbooks with steps, checks, outputs and approval/failure boundaries; APIs support drafts and test runs | Begin with Pippa's verified native-action history; demonstration-based GUI routines can follow later |
| Delegation | Separate subagent context, bounded concurrency, no further nesting, cancellation propagation and labeled results | Evaluate selective decomposition or independent checking for complex work; measure cost on a single local-model slot |
| Execution recovery | The executor records effects and rejects uncertain duplicate execution pending verification | Preserve effect uncertainty rather than treating an error as proof that nothing happened |
| Evaluation | Protocol tests and real-model quality checks are separate; graders inspect artifacts, service records and persisted effects | Measure useful outcomes independently of the assistant's final answer |

Implementation sources: [memory store](https://github.com/elie222/rakazo/blob/4dd95da0adc7c16f848b8ff6c865af78e3b21bd5/packages/memory/src/index.ts), [memory context](https://github.com/elie222/rakazo/blob/4dd95da0adc7c16f848b8ff6c865af78e3b21bd5/packages/adapters/src/memory-context.ts), [skill tools](https://github.com/elie222/rakazo/blob/4dd95da0adc7c16f848b8ff6c865af78e3b21bd5/packages/adapters/src/skill-tools.ts), [skill catalog](https://github.com/elie222/rakazo/blob/4dd95da0adc7c16f848b8ff6c865af78e3b21bd5/packages/core/src/agent-skill.ts), [playbook builder](https://github.com/elie222/rakazo/blob/4dd95da0adc7c16f848b8ff6c865af78e3b21bd5/packages/core/src/teach-playbook.ts), [Pi runtime](https://github.com/elie222/rakazo/blob/4dd95da0adc7c16f848b8ff6c865af78e3b21bd5/packages/adapters/src/pi-runtime.ts), [executor](https://github.com/elie222/rakazo/blob/4dd95da0adc7c16f848b8ff6c865af78e3b21bd5/packages/adapters/src/executor.ts), [evaluation method](https://github.com/elie222/rakazo/blob/4dd95da0adc7c16f848b8ff6c865af78e3b21bd5/docs/agent-verification.md).

## Important limits

**Native Mac access:** the host desktop provider declares `graphical: false` and `takeover: false`; its observation method uses a placeholder. It supports trusted host shell/file access. The teaching API rejects `computer.kind === "desktop"` and requires a graphical sandbox. Therefore this adapter is not a ready macOS Accessibility or graphical computer-use layer for Pippa. [Desktop provider](https://github.com/elie222/rakazo/blob/4dd95da0adc7c16f848b8ff6c865af78e3b21bd5/packages/adapters/src/desktop-sandbox.ts), [teaching API](https://github.com/elie222/rakazo/blob/4dd95da0adc7c16f848b8ff6c865af78e3b21bd5/apps/api/src/taught-skills.ts).

**Learning:** the reviewed implementation persists information and creates or revises instructions. Those mechanisms do not establish model-weight learning or a continuously improving task-success rate. The playbook builder primarily turns recorded events, including coordinates, into instructions; that alone does not demonstrate generalization to changed interfaces. Its principal quality evaluation does not establish visual-teaching quality. [Playbook builder](https://github.com/elie222/rakazo/blob/4dd95da0adc7c16f848b8ff6c865af78e3b21bd5/packages/core/src/teach-playbook.ts), [evaluation scope](https://github.com/elie222/rakazo/blob/4dd95da0adc7c16f848b8ff6c865af78e3b21bd5/docs/agent-verification.md).

**Capability truth:** the reviewed HEAD fixes repeated attempts to call `forget_memory` by exposing it only when the selected provider supports forgetting. This closely matches Pippa's need to distinguish configured tools from tools that can actually run. [Capability fix](https://github.com/elie222/rakazo/commit/4dd95da0adc7c16f848b8ff6c865af78e3b21bd5).

## Ordered adaptation plan

1. **Establish trustworthy outcome records.** Pippa's current habit ranking is evidence of what people choose, not verified task success: `Habits.weight` can positively weight an action without a known outcome. Join learning signals to authoritative task/native results and explicit acceptance. Failed, cancelled and uncertain work must not become successful examples.
2. **Make preferences explicit and editable.** Extend the current bounded fact memory with origin, intended scope, timestamps, replacement and deletion semantics. The existing Settings view/forget control is a foundation; ensure removal invalidates already-loaded context. Document content and model guesses must not silently become personal preferences.
3. **Propose reusable routines.** After repeated verified and accepted results, offer a procedure with inputs, expected outputs, checks and required access. Preview and test it on fresh synthetic input before activation. Store revisions and support rollback. A stored routine grants no new permissions.
4. **Improve problem-solving with controlled comparisons.** Test better skill retrieval, tool selection, adaptive reasoning and selective delegation on held-out task variations. Require improved completion or reduced intervention while preserving correctness, latency and effect safety. Do not enable subagents for routine local tasks merely because the capability exists.
5. **Promote improvements through reviewed releases.** Convert consented, minimized failure evidence into synthetic regressions. Compare candidate skills, prompts, routes and models against a pinned baseline. Do not make autonomous application rewriting or permission expansion part of the learning contract.

Pippa's existing task history, Undo signals, native receipts, bundled skills and evaluation harness make these incremental improvements feasible. They do not yet constitute a measured self-improving system. The next milestone is an observable reduction in repeated failures and user effort, with the same authority and predictable recovery.

See [Pippa's evolution plan](../pippa-next-evolution-2026-10-21.md) for sequencing and release gates.
