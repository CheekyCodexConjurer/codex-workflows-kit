---
name: workflows
description: Matheus universal workflow router for Codex, Antigravity, and OpenCode using $workflows, with compatibility aliases $codex-workflows, $antigravity-workflows, and $opencode-workflows; compact modes, evidence-first investigation, quality ratchets, sub-agents, phase graphs, claim maps, and strict validation.
---

# Workflows

Use this skill when a prompt invokes `$workflows`, one of the compatibility aliases
`$codex-workflows`, `$antigravity-workflows`, or `$opencode-workflows`, or uses
Matheus compact workflow syntax in Codex, OpenCode, or Google Antigravity.

## Fast path: one-step read-only probe

When a prompt is a one-step smoke test or health check and already supplies
`target_agent`, an absolute `cwd`, and a bounded read-only `task`, treat the
installed route as a cache hit. `target_agent` is the child role (`scout`,
`researcher`, or `reviewer`), not the MCP server name `opencode_worker`:

- Do not read repository files, memory, backend references, or run shell or
  CodeGraph before spawning.
- Spawn exactly one native `relay` with `agent_type=relay` and
  `{target_agent,cwd,task}`.
- Join that same relay; do not create a second relay or perform MCP discovery
  first.
- Only after a spawn or relay failure, inspect the relevant configuration.

This shortcut does not apply to implementation, high-risk, unclear, or
multi-phase work.

Load references by need, except for the fast path above:

- `references/dictionary.md`: for alias expansion on non-fast-path work.
- `references/mode-matrix.md`: to route non-fast-path modes.
- `references/runtime-adapters.md`: before routing tools or sub-agents on
  non-fast-path work;
  select exactly one adapter from the currently exposed host surface.
- `references/backend-policy.md`: for the Codex/Antigravity adapter when a
  sidecar is needed; do not ask the user to provide its routing token.
- `references/quality-ratchet.md`: for every workflow mode; apply the profile assigned by `mode-matrix.md`, including explicit no-scan and no-edit profiles.
- `references/observability.md`: for code-facing planning, investigation, review, or delivery; use its gate to choose no instrumentation, a bounded temporary diagnostic, or a durable event.
- `references/commit.md`: when prompt invokes `COMMIT`.
- `references/research.md`: when prompt invokes `RESEARCH.DEEP` or asks for deep web/GitHub research.
- `references/subagents.md`: when mode is `PLAN.AUTO`, `P.DEEP`, `RESEARCH.DEEP`, `IMPL.AUTO`, `IMPL`, `IMPL.PHASE`, `DELIVER.AUTO`, `REVIEW`, `DEBUG`, or `R.A.F.V`; or when the task mentions subA, worker, parallel, phase graph, claim map, review, audit, or multi-agent work.
- `references/validation.md`: for every workflow mode; each mode owns its validation, evidence, or explicit no-edit gate internally. Also load it when restarting AHK or using CodeGraph.

Operational rules:

- Expand aliases exactly enough to execute; preserve left-to-right order.
- Treat `mode=<MODE>` as the complete default execution contract. Optional trailing user text is task context or an explicit override; launcher aliases are not required.
- Treat `$workflows` as the canonical user-facing prefix. The three legacy
  prefixes are compatibility aliases and must resolve to the same mode matrix,
  quality rules, acceptance gates, and validation contract.
- Select exactly one runtime adapter from `references/runtime-adapters.md`
  before any tool or sub-agent action. The adapter changes only the available
  execution surface, never the workflow contract.
- Read the internal backend policy before routing a non-fast-path sidecar. The
  fast path uses the pinned `internal_subagent_backend=opencode` and
  `internal_subagent_transport=native_relay` contract; only an explicit
  maintenance request changes the backend to `native`.
- Apply the assigned TN quality-ratchet profile; never split for line count alone or broaden structural work beyond its paydown gate.
- Route by mode+risk+blast before work; keep simple tasks simple.
- Apply `proportional-cadence` to every mode: start with the smallest route, expand scope or depth only when existing evidence or material risk reveals uncertainty, or a required gate is still open; parallelize approved independent work only when it saves wall-clock; checkpoint before repeating no-progress work and, when a materially different cheapest action exists, take it once before using the mode's own done, blocked, or replan outcome; scale validation by impact; do not impose fixed timeouts on active subagents.
- Apply `plan-sync` to nontrivial work with two or more phases: initialize the real `update_plan` checklist with the first step `in_progress` and the rest `pending`; before the first command of the next phase and only after proof, mark the current phase `completed`, the next phase `in_progress`, and future phases `pending`; update it before continuing after scope changes; after the last proof, leave every step `completed` and none `in_progress`; never update it after every command, and keep the main agent as its single owner. Skip it for one-step or simple work.
- Read direct evidence first; use CodeGraph only when cg-worthy.
- Main agent owns critical path, contracts, integration, and final quality.
- Subagents are background scouts/reviewers/workers, not timers. Never close an
  active/waiting/required subagent before its reply is integrated. After a final
  reply is integrated, close its completed relay; on a slot-occupied spawn
  failure, use `subA-slot-full` to reclaim only completed/idle integrated
  subagents or wait for an optional one, then retry the same role. If no slot is
  reclaimable, report the explicit capacity block rather than silently skipping
  a required gate.
- Read-only work must use the exact custom role; use `relay` as the native
  transport when the internal OpenCode backend is active. After a transient
  availability error, retry that same role once and never fall back to
  `default`.
- Custom-role spawns must omit `fork_context`, `model`, and `reasoning_effort`; full-history forks inherit the parent and must not be combined with an explicit role.
- Prefer smallest safe change, canonical owner, delete/simplify before abstraction, and no unrelated churn.
- Final response must report concrete files, validation, risks, and remaining work.

## Codex/Antigravity sidecar route

When the selected runtime adapter is Codex or Antigravity, the installed
internal default is `internal_subagent_backend=opencode` with
`internal_subagent_transport=native_relay`. Each sidecar request starts a
fresh native relay with `multi_agent_v1__spawn_agent` and
`agent_type=relay`; it receives `{target_agent,cwd,task}`, calls the
configured `opencode_worker` MCP without a session identifier, and returns
the original response through the native sub-agent conversation. Completed
relays are not reused for later prompts, so each prompt gets an isolated MCP
conversation.
The main chat continues local non-overlap work and joins the relay at the
decision/final gate. After integrating a relay's final response, close that
completed relay to release its host slot; never close an active, waiting, or
required relay before integration. Read-only sidecars and claim-map-scoped
writer sidecars both use the configured OpenCode MCP through the native relay;
the relay remains transport-only, while the parent GPT owns review, tests, and
integration. The native `worker` profile remains only as an explicit
`internal_subagent_backend=native` maintenance override. The user does not
need to add a provider or transport flag.
Custom-role spawn calls still omit `fork_context`, `model`, and
`reasoning_effort`.

If the internal policy is explicitly changed to
`internal_subagent_backend=native`, use the native custom-role profiles for all
sub-agents. If the OpenCode route is unavailable while selected, report the
gate as blocked instead of silently changing provider, model, effort,
permissions, transport, or calling the MCP directly from the main chat.

## OpenCode execution surface

When the selected runtime adapter is OpenCode, use the OpenCode Task surface
and its configured `scout`, `researcher`, `reviewer`, and `worker` role
definitions. Read-only roles remain read-only; writable workers require the
same claim-map, isolated-worktree, no-touch, validation, and merge-gate
contract. Do not expose
the private Codex relay settings as prompt flags, and do not silently switch
to another provider, model, permission, or transport when an OpenCode gate is
unavailable.
