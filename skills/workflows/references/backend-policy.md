# Internal Sub-Agent Policy (canonical)

internal_subagent_backend=opencode
internal_subagent_transport=direct_mcp
internal_subagent_policy=writer_only

This file is the canonical source for ownership, OpenCode routing, nested
delegation, repair, and long-job progress. Other workflow files summarize it;
they must not redefine it.

## Ownership

- The GPT orchestrator plans, reads, diagnoses, validates, inspects diffs, and
  decides acceptance. It never authors a code patch or uses a native
  `scout`, `researcher`, `reviewer`, or `worker` as a substitute for OpenCode.
- The OpenCode `worker` is the only implementation role. It receives a fresh
  claim-map, an isolated clean worktree, `WRITER_WORKTREE=<cwd>`, and
  `WRITER_BASELINE=<full-commit>`. It may edit only the allowed files.
- The orchestrator may mechanically apply an accepted writer diff at the merge
  gate; it must not compose, repair, or improvise source changes itself.
- A no-edit mode never starts a writer. A missing MCP, invalid worktree, dirty
  writer checkout, missing baseline, or route mismatch blocks/replans.

## Writer loop

Use this state machine for every authorized write unit:

```text
PREFLIGHT -> W1 -> VERIFY
VERIFY pass -> ACCEPT/MERGE
VERIFY fail -> W2 repair (error + prior diff + changed hypothesis)
W2 fail -> ORCHESTRATOR DIAGNOSE (read-only) -> W3 fresh writer
W3 fail or no new hypothesis -> BLOCKED/REPLAN
```

Transport failures may receive one same-route retry and do not count as a
content failure. A writer quality/bug failure does count. The orchestrator's
diagnosis produces evidence and a new writer brief, never a patch. Never
silently fall back to a native worker, direct CLI, or GPT-authored edit.

## OpenCode route

- Use the exposed `opencode_worker` MCP directly for text sidecars. The native
  relay is not the normal analyst or writer route.
- `run_agent` is only for a bounded one-step smoke. Use `start_agent` for a
  reader, reviewer, researcher, or writer that may take time; keep its opaque
  `job_id` and do not treat `accepted` as a result.
- Reader and reviewer roles are read-only (`edit: deny`, `bash: deny`). The
  writer is edit-only (`edit: allow`, `bash: deny`, `task: deny`,
  `external_directory: deny`). Permissions are role definitions, not an OS
  sandbox; do not pass secrets.
- If images are attached, a native relay may perform only visual preflight and
  return a text-only `[VISUAL_PACKET v1]`. The parent then sends that text to
  OpenCode. The relay must not analyze the repository or edit files.

## Mandatory nested delegation

When a reader task contains two or more independent, uncovered fronts, the
parent marks `NESTED_REQUIRED=<front-a,front-b,...>` in the prompt. The OpenCode
reader must launch one read-only nested task per listed front, wait for every
result, and integrate them. If the `task` tool is unavailable, it returns
`NESTED_DELEGATION=blocked`; it must not silently do all fronts itself. Simple
or serial tasks stay local. Nested delegation is one level deep and never
re-delegates the assigned parent front. Writers never delegate.

## Progress checkpoints

The orchestrator does not wait blindly:

1. Start the job and record `job_id`.
2. Continue only useful local non-overlap work while it runs.
3. At the first prolonged-wait or decision checkpoint, call
   `get_agent_status(job_id)`.
4. `state=running` with a live heartbeat means the worker is still active;
   wait for the result and consult again only at the next meaningful
   checkpoint.
5. `result_available=true` or a terminal state permits `get_agent_result`.
6. A stale heartbeat, missing process, MCP error, or unknown state is not proof
   of success. Make one diagnostic status check; then repair/replan or block.
   Never keep waiting indefinitely on stale evidence, poll continuously, or
   relaunch without a changed decision.

`cancel_agent` is used only for an explicit cancellation decision. A status
timeout is uncertainty, not a successful result.

## Native-role guard

While `internal_subagent_backend=opencode`, native analytical profiles are
disabled. An accidental native `scout`, `researcher`, `reviewer`, or `worker`
must return `NATIVE_ROUTE_BLOCKED` without inspecting the task. The only
permitted native exception is the transport-only visual relay. Returning to
native analysis requires an explicit maintenance change to this policy.

## Configuration

The installer mirrors `agents/opencode/*.md` to `%CODEX_HOME%\opencode-agents`
and configures the pinned `opencode_worker` MCP:

```toml
[mcp_servers.opencode_worker]
args = ["-y", "github:CheekyCodexConjurer/sub-agents-mcp#v0.13.1"]
enabled_tools = ["run_agent", "start_agent", "get_agent_status", "get_agent_result", "cancel_agent"]
```

The configured model is `opencode-go/deepseek-v4-flash` with
`AGENT_EFFORT=max`; `JOB_DIR` and heartbeat settings remain durable. If the
selected MCP, model, credentials, or variant is unavailable, preserve the
gate as blocked. Never switch provider, permissions, transport, or model
silently.
