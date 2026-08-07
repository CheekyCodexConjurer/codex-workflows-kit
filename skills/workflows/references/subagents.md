# Subagents

This file is the short operational companion to the canonical
`backend-policy.md`. It describes when a sidecar is mandatory and how the
parent joins it; ownership and failure states live in the canonical policy.

## Roles

- `orchestrator`: GPT parent; plans, reads, diagnoses, tests, inspects and
  accepts. It never authors a source patch.
- `reader`: OpenCode `scout`, `researcher` or `reviewer`; read-only evidence.
- `worker`: OpenCode `worker`; the only implementation role, with a claim-map
  and isolated worktree.
- `watcher`: native `gpt-5.6-luna` at `high`; transport-only bridge that the
  parent spawns with `agent_type=watcher` for every normal reader, reviewer or
  worker handoff. It keeps one OpenCode MCP call open and returns its result.
  The brief must carry the explicit `OPEN_CODE_ROLE` token, one of {scout,
  researcher, reviewer, worker}; a missing or invalid token blocks before the
  MCP call, and the watcher never guesses a role. `OPEN_CODE_ROLE` is the
  sole role source: the MCP agent is never inferred from `NESTED_REQUIRED`
  front labels, and an optional `OPEN_CODE_MCP_AGENT` token, when present,
  must match it exactly.
- `relay`: native transport-only visual preflight. It is never an analyst,
  reviewer or writer. The parent attaches only the sanitized text-only
  `[VISUAL_PACKET v1]` to the watcher/MCP brief; image paths, bytes, base64,
  data URLs, and direct OpenCode/DeepSeek image reading never cross the
  bridge.

Native analytical profiles return `NATIVE_ROUTE_BLOCKED` while the OpenCode
backend is active. The watcher is the only native text exception and returns
`WATCHER_ROUTE_BLOCKED` when asked to analyze or edit. The legacy native route
is an explicit maintenance mode, not a silent fallback.

## Dispatch

Fan-out is mandatory per `sidecar-gate`: any non-trivial task, any task with
two or more independent fronts, an explicit user request for sub-agents,
shared/core or contract risk, or an explicit review/test obligation requires
one or more read-only readers, even without a wall-clock gain; required fronts
are never absorbed locally. Only strictly simple, serial, one-surface tasks
stay local. Each reader handoff goes through its own watcher; the parent owns
the critical path and joins required sidecars before making a decision. A
no-edit mode never dispatches a worker.

For two or more independent uncovered reader fronts, the parent puts
`NESTED_REQUIRED=<fronts>` in the brief. The reader must use OpenCode's
read-only `task` tool once per listed front, selecting the nested agent type
explicitly — `explore` or `general` only, never `watcher`, `reader`, or a
front-label-derived value — wait for all nested results and
return `NESTED_DELEGATION=used` with the evidence. If the tool is unavailable,
return `NESTED_DELEGATION=blocked`; do not handle the fronts silently. One
nested level is allowed. Simple or serial tasks do not require delegation.

## Writer lifecycle

Every authorized write follows the same loop:

```text
PREFLIGHT -> W1 -> VERIFY
VERIFY pass -> ACCEPT/MERGE
VERIFY fail -> W2 repair -> VERIFY
W2 fail -> GPT read-only DIAGNOSE -> W3 fresh writer -> VERIFY
W3 fail or no new hypothesis -> BLOCKED/REPLAN
```

The repair brief contains the exact failure, previous diff and changed
hypothesis. Transport retries do not count as content failures. The GPT
diagnosis produces evidence and a new brief, never a patch. The parent may
mechanically merge an accepted diff after checking baseline and allowed paths.

Writer preflight requires an absolute worktree distinct from the main checkout,
`git rev-parse HEAD` as `WRITER_BASELINE`, an empty status, and matching
`WRITER_WORKTREE`/`WRITER_BASELINE` tokens. Any failure blocks or replans.

## Long jobs

Normal handoffs always go through the native watcher bridge
(`agent_type=watcher` -> one blocking `run_agent` call) and return its compact
result; it does not poll. The parent never calls `run_agent`/`start_agent`
directly for normal work; its `opencode_worker` exposure is
`get_agent_status`/`get_agent_result`/`cancel_agent` for declared recovery.
`start_agent` for detached work and recovery is an explicit exception used only
after the route is declared and evidence requires it; retain its opaque
`job_id`.

At a prolonged-wait or decision checkpoint, call `get_agent_status`. A live
heartbeat on a running job permits another wait. A terminal state or
`result_available=true` permits `get_agent_result`. Stale heartbeat, missing
process, MCP error or unknown state requires one diagnostic check and then
repair/replan/block. Never poll continuously, wait forever on stale evidence,
or treat `accepted` as a completed result.

### Child lifecycle

`MAX_ACTIVE_CHILDREN_PER_CHAT=5` is the workflow cap. `RUNNING_LIVE=WAIT`:
never message or steer a child to accelerate the MCP. On a result, capture the
envelope and close the child immediately (`RESULT=CAPTURE_THEN_CLOSE`). Close a
child early only after one status check confirms crash/stale/missing process;
preserve `job_id` and recover once or block. When slots are full, reclaim only
terminal children whose results are captured; never close live, waiting or
required children. A required sidecar that cannot run keeps its gate blocked.

## Review and testing

Reviewers inspect a frozen integrated diff only. Tests and validation remain
parent-owned; a subagent result is evidence, not approval. If a required test
sidecar cannot return, keep the gate blocked and report the exact failure.
