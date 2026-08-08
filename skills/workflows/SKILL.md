---
name: workflows
description: Canonical `$workflows` router for backend-aware sub-agents (default backend, native opt-in).
---

# Workflows

Use this skill when a prompt invokes `$workflows` with `mode=<MODE>`.

## Contract

- `$workflows mode=<MODE>` is the complete default contract: the mode defines
  change authorization, required evidence, validation, and the done gate.
  Expand the mode, then treat trailing text as task context or an explicit
  override.
- Trailing explicit override: `subagents=mcp|native`. The default local
  backend is `subagents=mcp`; `native` is explicit opt-in.
- Read `codex/AGENTS.md` first. It owns the compact mode library and the
  global routing rules.
- `backend-policy.md` is the single detailed canonical policy for
  orchestration and delegation: lifecycle, tool semantics, pending
  obligation, delegation audit, and review-after-writer. Other references
  point to it; do not duplicate the lifecycle.
- Open detailed references only when required by the selected mode or an open
  gate: `research.md` for `RESEARCH.DEEP`, `observability.md` for logs,
  `subagents.md` for native profiles, `validation.md` for delivery gates, and
  `mode-matrix.md` or `dictionary.md` for an ambiguous mode.
- Preserve existing work. Define the failure signature and validation before
  editing. Do not add instrumentation unless `obs-gate` produces an explicit
  contract.

## Delegation

- Parent GPT is the decomposer, router, maestro, synthesizer, integrator, and
  final validator. The default backend is the primary provider for
  substantial bounded delegated reading, investigation, research,
  reproduction, testing, implementation, and review when the mode permits it.
  Keep trivial serial work local.
- Readers run `analyze`/`test`; writers run `edit` only when the mode
  authorizes change. No-edit modes stay no-edit.
- Native `scout`, `researcher`, and `reviewer` profiles exist only under
  `subagents=native` (see `subagents.md`): each is pinned to `gpt-5.6-luna`
  with `high` reasoning and a `read-only` sandbox, and none writes.
- Apply `sidecar-gate` to non-trivial, multi-front, core/contract, or
  explicitly reviewed work. Keep truly simple serial work local.

## Completion gate

- Mandatory delegated work obeys the canonical completion contract and
  pending-obligation gate in `backend-policy.md`: do not synthesize or
  finalize before the delegation audit passes, and never treat an accepted
  spawn as a result.

## Delivery

- No-edit modes stay no-edit.
- In implementation modes, the mode authorizes change: an edit-capable
  writer on the resolved backend implements the authorized, claim-mapped
  change after preflight evidence; the parent owns integration, validation,
  and final approval. Concrete defects from the independent review return to
  the same writer via `deepseek_continue`.
- `DELIVER.AUTO` ends at the reviewed integrated diff and never commits.
- For two or more phases, keep one plan item in progress and update it at
  phase boundaries.
