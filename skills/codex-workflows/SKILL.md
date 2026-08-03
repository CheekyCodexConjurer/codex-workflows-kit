---
name: codex-workflows
description: Matheus compact Codex and Antigravity workflow router for AHK shortcuts and prompts using $codex-workflows or $antigravity-workflows, compact aliases, PLAN.AUTO, PLAN, P.DEEP, RESEARCH.DEEP, earned-rework, passive TN quality ratchet, IMPL.AUTO, IMPL, IMPL.PHASE, DELIVER.AUTO implementation-wave and review-after-freeze, REVIEW, COMMIT intelligent commit series/push, BUG.INV, BUG.FIX, DEBUG feature bug loop, REWORK, R.A.F.V, TN.SKILL, size-scan, refactor-sizing-plan, CodeGraph, subagents, phase graphs, claim maps, and strict code-quality workflows.
---

# Codex & Antigravity Workflows

Use this skill when a prompt invokes `$codex-workflows`, `$antigravity-workflows`, `$opencode-workflows`, or uses Matheus compact workflow syntax in Codex, OpenCode, or Google Antigravity environments.

Load references by need:

- `references/dictionary.md`: always for alias expansion.
- `references/mode-matrix.md`: always to route the requested mode.
- `references/backend-policy.md`: always for the internal sub-agent backend
  selection; do not ask the user to provide its routing token.
- `references/quality-ratchet.md`: for every workflow mode; apply the profile assigned by `mode-matrix.md`, including explicit no-scan and no-edit profiles.
- `references/observability.md`: for code-facing planning, investigation, review, or delivery; use its gate to choose no instrumentation, a bounded temporary diagnostic, or a durable event.
- `references/commit.md`: when prompt invokes `COMMIT`.
- `references/research.md`: when prompt invokes `RESEARCH.DEEP` or asks for deep web/GitHub research.
- `references/subagents.md`: when mode is `PLAN.AUTO`, `P.DEEP`, `RESEARCH.DEEP`, `IMPL.AUTO`, `IMPL`, `IMPL.PHASE`, `DELIVER.AUTO`, `REVIEW`, `DEBUG`, or `R.A.F.V`; or when the task mentions subA, worker, parallel, phase graph, claim map, review, audit, or multi-agent work.
- `references/validation.md`: for every workflow mode; each mode owns its validation, evidence, or explicit no-edit gate internally. Also load it when restarting AHK or using CodeGraph.

Operational rules:

- Expand aliases exactly enough to execute; preserve left-to-right order.
- Treat `mode=<MODE>` as the complete default execution contract. Optional trailing user text is task context or an explicit override; launcher aliases are not required.
- Read the internal backend policy before routing any sidecar. Its installed
  default is `internal_subagent_backend=opencode`; only an explicit maintenance
  request changes it to `native`.
- Apply the assigned TN quality-ratchet profile; never split for line count alone or broaden structural work beyond its paydown gate.
- Route by mode+risk+blast before work; keep simple tasks simple.
- Apply `proportional-cadence` to every mode: start with the smallest route, expand scope or depth only when existing evidence or material risk reveals uncertainty, or a required gate is still open; parallelize approved independent work only when it saves wall-clock; checkpoint before repeating no-progress work and, when a materially different cheapest action exists, take it once before using the mode's own done, blocked, or replan outcome; scale validation by impact; do not impose fixed timeouts on active subagents.
- Apply `plan-sync` to nontrivial work with two or more phases: initialize the real `update_plan` checklist with the first step `in_progress` and the rest `pending`; before the first command of the next phase and only after proof, mark the current phase `completed`, the next phase `in_progress`, and future phases `pending`; update it before continuing after scope changes; after the last proof, leave every step `completed` and none `in_progress`; never update it after every command, and keep the main agent as its single owner. Skip it for one-step or simple work.
- Read direct evidence first; use CodeGraph only when cg-worthy.
- Main agent owns critical path, contracts, integration, and final quality.
- Subagents are background scouts/reviewers/workers, not timers. Never close an active required subagent before its reply is integrated.
- Read-only work must use the exact custom role; use `relay` as the native
  transport when the internal OpenCode backend is active. After a transient
  availability error, retry that same role once and never fall back to
  `default`.
- Custom-role spawns must omit `fork_context`, `model`, and `reasoning_effort`; full-history forks inherit the parent and must not be combined with an explicit role.
- Prefer smallest safe change, canonical owner, delete/simplify before abstraction, and no unrelated churn.
- Final response must report concrete files, validation, risks, and remaining work.

## Internal sub-agent backend route

The installed internal default is `internal_subagent_backend=opencode` with
`internal_subagent_transport=native_relay`. When a mode chooses to use a
read-only sidecar, spawn the native `relay` profile in the background. Give it
`{target_agent,cwd,task}`; it calls the configured `opencode_worker` MCP and
returns the original response through the native sub-agent conversation. The
main chat continues local non-overlap work and joins the relay at the
decision/final gate. Implementation workers remain native and claim-map
scoped. The user does not need to add a provider or transport flag. The spawn
operation is `multi_agent_v1__spawn_agent` with `agent_type=relay`; omit
`fork_context`, `model`, and `reasoning_effort`, and place only
`{target_agent,cwd,task}` in the relay message.

If the internal policy is explicitly changed to
`internal_subagent_backend=native`, use the native custom-role profiles for all
sub-agents. If the OpenCode route is unavailable while selected, report the
gate as blocked instead of silently changing provider, model, effort,
permissions, transport, or calling the MCP directly from the main chat.
