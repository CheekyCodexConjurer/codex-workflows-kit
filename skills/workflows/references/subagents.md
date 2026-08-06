# Subagents

This file is the short operational companion to the canonical
`backend-policy.md`. It describes when a sidecar is useful and how the parent
joins it; ownership and failure states live in the canonical policy.

## Roles

- `orchestrator`: GPT parent; plans, reads, diagnoses, tests, inspects and
  accepts. It never authors a source patch.
- `reader`: OpenCode `scout`, `researcher` or `reviewer`; read-only evidence.
- `worker`: OpenCode `worker`; the only implementation role, with a claim-map
  and isolated worktree.
- `relay`: native transport-only visual preflight. It is never an analyst,
  reviewer or writer.

Native analytical profiles return `NATIVE_ROUTE_BLOCKED` while the OpenCode
backend is active. The legacy native route is an explicit maintenance mode,
not a silent fallback.

## Dispatch

Use the smallest route that closes the evidence gap. A reader is useful for a
distinct research, test, or review front; do not duplicate a serial task. The
parent owns the critical path and joins required sidecars before making a
decision. A no-edit mode never dispatches a worker.

For two or more independent uncovered reader fronts, the parent puts
`NESTED_REQUIRED=<fronts>` in the brief. The reader must use OpenCode's
read-only `task` tool once per listed front, wait for all nested results and
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

Use the direct `opencode_worker` MCP. `run_agent` is for a bounded smoke;
`start_agent` is for work that may take time. Store its `job_id`.

At a prolonged-wait or decision checkpoint, call `get_agent_status`. A live
heartbeat on a running job permits another wait. A terminal state or
`result_available=true` permits `get_agent_result`. Stale heartbeat, missing
process, MCP error or unknown state requires one diagnostic check and then
repair/replan/block. Never poll continuously, wait forever on stale evidence,
or treat `accepted` as a completed result.

## Review and testing

Reviewers inspect a frozen integrated diff only. Tests and validation remain
parent-owned; a subagent result is evidence, not approval. If a required test
sidecar cannot return, keep the gate blocked and report the exact failure.
