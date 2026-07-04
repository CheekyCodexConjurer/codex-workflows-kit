---
name: codex-workflows
description: Matheus compact Codex workflow router for AHK shortcuts and prompts using $codex-workflows, compact aliases, PLAN, P.DEEP, IMPL, IMPL.PHASE, REVIEW, COMMIT, BUG.INV, BUG.FIX, DEBUG, REWORK, R.A.F.V, TN.SKILL, CodeGraph, subagents, phase graphs, claim maps, and strict code-quality workflows.
---

# Codex Workflows

Use this skill when a prompt invokes `$codex-workflows` or uses Matheus compact workflow syntax.

Load references by need:

- `references/dictionary.md`: always for alias expansion.
- `references/mode-matrix.md`: always to route the requested mode.
- `references/subagents.md`: when prompt mentions subA, worker, parallel, phase graph, claim map, review, audit, or multi-agent work.
- `references/validation.md`: when planning validation, running checks, restarting AHK, using CodeGraph, or reporting final evidence.

Operational rules:

- Expand aliases exactly enough to execute; preserve left-to-right order.
- Route by mode+risk+blast before work; keep simple tasks simple.
- Read direct evidence first; use CodeGraph only when cg-worthy.
- Main agent owns critical path, contracts, integration, and final quality.
- Subagents are background scouts/reviewers/workers, not timers. Never close an active required subagent before its reply is integrated.
- Prefer smallest safe change, canonical owner, delete/simplify before abstraction, and no unrelated churn.
- Final response must report concrete files, validation, risks, and remaining work.
