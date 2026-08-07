---
name: workflows
description: Canonical `$workflows` router for native read-only sub-agents.
---

# Workflows

Use this skill when a prompt invokes `$workflows` with `mode=<MODE>`.

## Contract

- `$workflows mode=<MODE>` is the complete default contract. Expand the mode,
  then treat trailing text as task context or an explicit override.
- Read `codex/AGENTS.md` first. It owns the compact mode library and the
  global routing rules.
- Open detailed references only when required by the selected mode or an open
  gate: `research.md` for `RESEARCH.DEEP`, `observability.md` for logs,
  `backend-policy.md` and `subagents.md` for delegation,
  `validation.md` for delivery gates, and `mode-matrix.md` or `dictionary.md`
  for an ambiguous mode.
- Preserve existing work. Define the failure signature and validation before
  editing. Do not add instrumentation unless `obs-gate` produces an explicit
  contract.

## Native sub-agents

- Native `scout`, `researcher`, and `reviewer` are the only workflow
  sub-agents. Each is pinned to `gpt-5.6-luna` with `high` reasoning and a
  `read-only` sandbox.
- Use them for independent evidence, research, and review fronts. Give each
  one bounded ownership and join the results before making a decision.
- They never edit, stage, commit, create patches, or launch another agent.
  The parent owns synthesis, changes, validation, and integration.
- Apply `sidecar-gate` to non-trivial, multi-front, core/contract, or
  explicitly reviewed work. Keep truly simple serial work local.

## Sidecar completion

- Completion contract: for every required sidecar, the parent must wait for a
  `final response` before `synthesis or advancement`. While a sidecar is
  `running`, do not send an `interruptive follow-up` or `replace` it.
- `interrupted`, `errored`, `timed out`, or `missing final response` means
  unavailable: keep `sidecar-gate` `open/BLOCKED`; do not use a `silent
  fallback`.
- This parent-side policy cannot prevent an explicit user or host cancellation
  outside this repository.
- Normative contract: `completion_policy = { required = "final_response", running = "no_interrupt_or_replace", missing = "gate_open_blocked", fallback = "forbidden" }`

## Delivery

- No-edit modes stay no-edit.
- In implementation modes, the parent applies only an authorized,
  claim-mapped change after preflight evidence. Validate the affected behavior,
  inspect the integrated diff, then request a read-only review when the mode
  requires it.
- `DELIVER.AUTO` ends at the reviewed integrated diff and never commits.
- For two or more phases, keep one plan item in progress and update it at
  phase boundaries.
