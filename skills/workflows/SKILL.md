---
name: workflows
description: Universal workflow router for Codex, Antigravity, and OpenCode using $workflows and compact mode contracts.
---

# Workflows

Use this skill when a prompt invokes `$workflows`, `$codex-workflows`,
`$antigravity-workflows`, `$opencode-workflows`, or compact workflow syntax.

## Contract

- `$workflows mode=<MODE>` is the complete default contract. Expand aliases in
  order and treat trailing text as task context or an explicit override.
- Load only the references required by the mode: `dictionary.md` and
  `mode-matrix.md` for routing; `quality-ratchet.md` and `validation.md` for
  every mode; `research.md` for `RESEARCH.DEEP`; `observability.md` for logs;
  `backend-policy.md` and `subagents.md` when sidecars are involved.
- Select one exposed runtime adapter. It changes invocation, never ownership,
  no-edit, validation, or no-fallback rules.
- Keep simple serial one-surface work local. Sidecar fan-out is mandatory per
  `sidecar-gate` for non-trivial work; do not add instrumentation by default.

## Ownership and writers

The canonical ownership and routing contract is
`references/backend-policy.md`.

- The GPT orchestrator plans, reads, diagnoses, tests, inspects diffs and
  approves. It never authors a code patch.
- Every authorized write uses an OpenCode `worker` through the configured
  `opencode_worker` MCP, in a clean isolated worktree with a claim-map,
  no-touch boundaries and `WRITER_WORKTREE`/`WRITER_BASELINE`.
- The parent spawns the native `watcher` (`agent_type=watcher`) for every
  normal reader, reviewer and worker handoff; the watcher is allowed only as a
  transport bridge: it keeps one MCP job open and returns the result. It never
  analyzes, reviews, edits, or replaces an OpenCode role.
- The loop is `W1 -> verify -> W2 repair -> verify -> read-only diagnosis ->
  W3`. A second failed repair blocks or replans; there is no GPT patch
  fallback, native worker fallback, or direct CLI fallback.
- No-edit modes, including `BUG.INV`, never start writers.

## Nested readers

OpenCode readers are read-only. For two or more independent uncovered fronts,
the parent must include `NESTED_REQUIRED=<fronts>` in the brief. The reader
must launch one read-only nested task per front, wait for all results,
integrate them and return `NESTED_DELEGATION=used`. If `task` is unavailable it
returns `NESTED_DELEGATION=blocked`; it must not silently do all fronts itself.
Simple and serial tasks stay local. Writers never delegate.

## MCP and long jobs

- The default text route is the native watcher bridge:
  `parent -> native watcher (agent_type=watcher) -> opencode_worker MCP ->
  exact OpenCode role`. Every watcher brief must carry the explicit
  `OPEN_CODE_ROLE` token, exactly one of scout, researcher, reviewer, worker;
  the watcher never guesses, and a missing or invalid token blocks before the
  MCP call. The parent never calls `opencode_worker`
  `run_agent`/`start_agent` directly for normal work; its own exposure is
  status/result/cancel for declared recovery. A native `scout`, `researcher`,
  `reviewer`, or `worker` is never an analyst; under the OpenCode backend it
  returns `NATIVE_ROUTE_BLOCKED`. A native relay is permitted only for visual
  preflight and returns text-only `[VISUAL_PACKET v1]` evidence; the parent
  attaches only that sanitized text to the watcher brief and the MCP OpenCode
  role — never image paths, bytes, base64, data URLs, and never direct image
  reading by the OpenCode (DeepSeek) model.
- Before the first live watcher -> MCP handoff after installation, restart,
  or route/model/role change, run a bounded direct OpenCode CLI smoke that
  mirrors the sub-agents-mcp OpenCode invocation: exact role markdown as
  system context, same configured model/variant and cwd, role-appropriate
  no-edit permissions. Require exit success and `CLI_PREFLIGHT=passed`; a
  failure blocks the MCP route. Diagnostic only: never handles user work,
  never replaces watcher -> MCP, never a direct CLI fallback.
- The watcher makes one blocking `run_agent` call for the normal MCP handoff;
  the parent never waits on or polls that call. `start_agent` for detached jobs
  and recovery is an explicit exception used only after the route is declared
  and evidence requires it. Keep the opaque `job_id` when `start_agent` is
  used and never integrate `accepted` as a result.
- At the first prolonged wait or decision checkpoint, call
  `get_agent_status`. `running + freshness=live` is evidence to wait;
  `result_available=true` or a terminal state permits `get_agent_result`.
  Stale heartbeat, missing process, MCP error or unknown state requires one
  diagnostic check and then repair/replan/block. Do not poll continuously or
  wait blindly.
- Child lifecycle is compact and explicit: `MAX_ACTIVE_CHILDREN_PER_CHAT=5`;
  live children are waited on, returned children are captured then closed, and
  only confirmed crashes or terminal children may be closed. Never steer a live
  child to accelerate its MCP call. Required sidecars block if unavailable.

## Validation and plans

- Define the failure signature/check before editing. Start with targeted
  validation, then broaden for shared contracts or higher blast.
- For two or more phases, use `update_plan` at phase boundaries: one phase
  `in_progress`, future phases `pending`, and all `completed` at the end.
- Validate the integrated diff, allowed paths, installed mirrors and the live
  MCP route when the route is part of the claim. A missing required capability
  remains blocked; never silently change provider, model, permissions or
  transport.

## Runtime surfaces

All runtimes hand normal sidecars through the native watcher bridge; the
parent's own `opencode_worker` exposure is status/result/cancel for declared
recovery. OpenCode uses the configured `opencode_worker` MCP and the role
definitions under `agents/opencode`. The native backend is an explicit
maintenance override only.

The canonical user-facing prefix is `$workflows`; legacy prefixes are
compatibility aliases with the same mode matrix and acceptance gates.
