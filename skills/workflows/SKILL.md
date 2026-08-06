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
- Keep simple work local. Keep non-trivial work proportional to risk and
  blast. Do not add instrumentation by default.

## Ownership and writers

The canonical ownership and routing contract is
`references/backend-policy.md`.

- The GPT orchestrator plans, reads, diagnoses, tests, inspects diffs and
  approves. It never authors a code patch.
- Every authorized write uses an OpenCode `worker` through the configured
  `opencode_worker` MCP, in a clean isolated worktree with a claim-map,
  no-touch boundaries and `WRITER_WORKTREE`/`WRITER_BASELINE`.
- The loop is `W1 -> verify -> W2 repair -> verify -> read-only diagnosis ->
  W3`. A second failed repair blocks or replans; there is no GPT patch
  fallback, native worker fallback, or direct CLI fallback.
- No-edit modes, including `BUG.INV`, never start writers.

## Nested readers

OpenCode readers are read-only. For two or more independent uncovered fronts,
the parent must include `NESTED_REQUIRED=<fronts>` in the brief. The reader
must launch one read-only nested task per front, wait for all results and
integrate them. If `task` is unavailable it returns
`NESTED_DELEGATION=blocked`; it must not silently do all fronts itself.
Simple and serial tasks stay local. Writers never delegate.

## MCP and long jobs

- The default text route is the exposed `opencode_worker` MCP directly. A
  native `scout`, `researcher`, `reviewer`, or `worker` is never an analyst;
  under the OpenCode backend it returns `NATIVE_ROUTE_BLOCKED`. A native relay
  is permitted only for visual preflight and returns text-only
  `[VISUAL_PACKET v1]` evidence.
- Use `run_agent` only for a bounded smoke test. Use `start_agent` for a
  potentially long reader, reviewer, researcher or writer; retain its opaque
  `job_id` and never integrate `accepted` as a result.
- At the first prolonged wait or decision checkpoint, call
  `get_agent_status`. `running + freshness=live` is evidence to wait;
  `result_available=true` or a terminal state permits `get_agent_result`.
  Stale heartbeat, missing process, MCP error or unknown state requires one
  diagnostic check and then repair/replan/block. Do not poll continuously or
  wait blindly.

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

Codex and Antigravity use the directly exposed MCP tools. OpenCode uses the
same configured `opencode_worker` MCP and the role definitions under
`agents/opencode`. The native backend is an explicit maintenance override only.

The canonical user-facing prefix is `$workflows`; legacy prefixes are
compatibility aliases with the same mode matrix and acceptance gates.
