# Internal Sub-Agent Policy (canonical)

internal_subagent_backend=opencode
internal_subagent_transport=native_watcher_mcp
internal_subagent_policy=writer_only

This file is the canonical source for ownership, OpenCode routing, the native
watcher bridge, mandatory sidecar fan-out, nested delegation, repair, and
long-job progress. Other workflow files summarize it; they must not redefine it.

## Ownership

- The GPT orchestrator plans, reads, diagnoses, validates, inspects diffs, and
  decides acceptance. It never authors a code patch or uses a native
  `scout`, `researcher`, `reviewer`, or `worker` as a substitute for OpenCode.
- The OpenCode `worker` is the only implementation role. It receives a fresh
  claim-map, an isolated clean worktree, `WRITER_WORKTREE=<cwd>`, and
  `WRITER_BASELINE=<full-commit>`. It may edit only the allowed files.
- The native `watcher` is a coordination exception, not an implementation or
  analytical role. It may hold one `opencode_worker` MCP call open and return
  its result; it must not inspect, review, edit, or delegate.
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

- Normal text sidecars use the explicit native watcher bridge:
  `GPT parent -> native watcher (agent_type=watcher) -> opencode_worker MCP ->
  exact OpenCode role`. The parent spawns the native watcher for every normal
  reader, reviewer and worker handoff and never calls `opencode_worker`
  `run_agent`/`start_agent` directly for normal work. The parent's own MCP
  exposure is status-only (`get_agent_status`, `get_agent_result`,
  `cancel_agent`) for declared recovery.
- The watcher is transport-only: it makes one blocking `run_agent` call for the
  normal handoff so the parent chat stays free; the parent never polls that
  call. Detached work and recovery via `start_agent` are an explicit exception
  used only after the route is declared and evidence requires it; keep the
  opaque `job_id` and never treat `accepted` as a result.
- The full MCP handoff config (`run_agent`/`start_agent`) is carried by the
  installed native watcher profile, rendered from portable placeholders at
  install time; the parent configuration exposes status/result/cancel only.
- Reader and reviewer roles are read-only (`edit: deny`, `bash: deny`). The
  writer is edit-only (`edit: allow`, `bash: deny`, `task: deny`,
  `external_directory: deny`). Permissions are role definitions, not an OS
  sandbox; do not pass secrets.
- If images are attached, a native relay may perform only visual preflight and
  return a text-only `[VISUAL_PACKET v1]`. The parent then sends that text to
  OpenCode; it never sends image paths, bytes, base64, or data URLs, and never
  asks the OpenCode (DeepSeek) model to read image data directly. The relay
  must not analyze the repository or edit files.

## Mandatory sidecar trigger

`SIDECAR=REQUIRED` (sidecar/quality-first fan-out) applies to:

- any non-trivial task (multi-file, shared/core, unclear ownership, high blast);
- any task with two or more independent fronts;
- an explicit user request for sub-agents;
- shared/core or contract risk;
- an explicit review or test obligation.

Fan-out is mandatory even without a wall-clock gain. Spawn one or more
read-only readers (one per independent front, each through its own watcher
handoff) and do not absorb required fronts locally. Only strictly simple,
serial, one-surface tasks stay local. `sidecar-gate` in the dictionary is the
compact reference for this trigger.

## Mandatory nested delegation

When a reader task contains two or more independent, uncovered fronts, the
parent marks `NESTED_REQUIRED=<front-a,front-b,...>` in the prompt. The OpenCode
reader must launch one read-only nested task per listed front, wait for every
result, integrate them, and return `NESTED_DELEGATION=used`. If the `task` tool
is unavailable, it returns `NESTED_DELEGATION=blocked`; it must not silently do
all fronts itself. Simple or serial tasks stay local. Nested delegation is one
level deep and never re-delegates the assigned parent front. Writers never
delegate. Nested task agent types are explicitly selected per front and
limited to `explore` or `general`; `watcher`, `reader`, and front-label-derived
values are forbidden.

## Progress checkpoints

The orchestrator does not wait blindly:

- Normal route: the parent spawns the native watcher (`agent_type=watcher`);
  the watcher holds the single blocking `run_agent` call for the handoff and
  returns its result to the parent. No MCP `job_id`/status polling is involved;
  the parent continues only useful local non-overlap work while the call is
  open and never queries job status.
- Detached/recovery exception: only a `start_agent` call returns an opaque
  `job_id`, and only then is `get_agent_status(job_id)` used, at the first
  prolonged-wait or decision checkpoint:
  1. `state=running` with a live heartbeat means the worker is still active;
     wait for the result and consult again only at the next meaningful
     checkpoint.
  2. `result_available=true` or a terminal state permits `get_agent_result`.
  3. A stale heartbeat, missing process, MCP error, or unknown state is not
     proof of success. Make one diagnostic status check; then repair/replan or
     block. Never keep waiting indefinitely on stale evidence, poll
     continuously, or relaunch without a changed decision.

`cancel_agent` is used only for an explicit cancellation decision. A status
timeout is uncertainty, not a successful result.

## Child lifecycle and capacity

`MAX_ACTIVE_CHILDREN_PER_CHAT=5` is this workflow's operational cap for native
child threads; it is not a claim about a universal Codex product limit.

- `SPAWN`: create a child only below the cap. Count watchers, readers and other
  native child threads for the same parent chat.
- `RUNNING_LIVE=WAIT`: a live heartbeat means the child is still working or
  waiting on the MCP. Do not send follow-ups, `steer`, `interrupt`, retries or
  other messages to accelerate it; they do not accelerate the MCP handoff.
- `RESULT=CAPTURE_THEN_CLOSE`: when the child returns a result, capture the
  compact envelope and job reference, then close the child immediately. Do not
  close it before the response is captured.
- `CRASH_CONFIRMED=CLOSE_AND_RECOVER`: query status once to distinguish crash
  from a live wait. If the process is absent, the heartbeat is stale or the MCP
  reports an error, close the broken child, preserve `job_id` when available,
  and make one recovery decision; never duplicate blindly.
- `SLOT_FULL=TERMINAL_ONLY_RECLAIM`: close only terminal children whose result
  is already captured. Never close a live, waiting or required child merely to
  free a slot; if none is reclaimable, wait or block.
- `REQUIRED_BLOCK`: a required reader, reviewer or watcher that cannot run
  keeps its gate blocked. Never substitute a native analytical role, absorb
  the required front locally, or declare success on missing capability.

UI inactivity alone is not a crash signal. Status consultation is diagnostic at
meaningful checkpoints, not continuous polling.

## Native-role guard

While `internal_subagent_backend=opencode`, native analytical profiles are
disabled. An accidental native `scout`, `researcher`, `reviewer`, or `worker`
must return `NATIVE_ROUTE_BLOCKED` without inspecting the task. The native
`watcher` is permitted only as a transport-only MCP bridge and must return
`WATCHER_ROUTE_BLOCKED` for analytical or editing requests. The visual relay
remains a separate transport-only exception.

## Exact OpenCode role token

Every watcher handoff brief must carry an explicit `OPEN_CODE_ROLE` token whose
value is exactly one of {scout, researcher, reviewer, worker}. The watcher
passes the brief, token included, to its single `run_agent` call and it
never guesses a role. A runtime failure was observed when the role was guessed
as `watcher` or `reader`: OpenCode has no such roles, so the job either failed
at launch or ran under the wrong default role, producing unusable output. A
missing or invalid token is therefore rejected before the MCP call
(`WATCHER_STATUS=blocked` with `WATCHER_ROLE=missing|invalid`), never repaired
by guessing. `OPEN_CODE_ROLE` is the sole role source for the nested agent
selection: the MCP agent is never derived from `NESTED_REQUIRED` front labels
or other brief text. The brief may carry an optional `OPEN_CODE_MCP_AGENT`
token that, when present, must match `OPEN_CODE_ROLE` exactly
(`WATCHER_MCP_AGENT=mismatch` otherwise). A front named `watcher-contract` was
observed launching agent=watcher; a front label is never an agent hint. When
images are attached, the parent attaches only the sanitized
text-only `[VISUAL_PACKET v1]` to the brief — never image paths, bytes,
base64, or data URLs, and never direct image reading by the OpenCode (DeepSeek)
model.

## OpenCode CLI preflight

Before the first live watcher -> MCP handoff after installation, restart, or
route/model/role change, run one bounded direct OpenCode CLI smoke that
reproduces the sub-agents-mcp OpenCode invocation: exact role markdown as
system context, same configured model/variant and cwd, role-appropriate
no-edit permissions. Require exit success and the explicit
`CLI_PREFLIGHT=passed` evidence token; a failed smoke blocks the MCP route
until the cause is diagnosed and the smoke passes. This is diagnostic only:
the smoke never handles user work, never replaces the watcher -> MCP
handoff, and is never a direct CLI fallback for normal work.

## Child permission boundary

`bin/opencode-worker.cmd` is the MCP process boundary: it exports a valid
inline OpenCode config in `OPENCODE_CONFIG_CONTENT` before launching npx. That
inherited config is the child OpenCode permission boundary (`*` and `doom_loop`
allow; `question`, `plan_enter`, `plan_exit` deny; `external_directory` scoped
to the trusted installed paths below). The launcher never rewrites
`AGENT_PERMISSION`; sub-agents-mcp owns that child env. sub-agents-mcp v0.13.1
still serializes `AGENT_PERMISSION=yolo` as the JSON scalar `"allow"`, which
OpenCode's schema rejects and which would otherwise trigger unattended
external-directory prompts; the inherited valid config prevents them. The same
inherited config also explicitly allows `doom_loop`, whose OpenCode default is
an interactive ask, so a repeated identical tool call resolves instead of
waiting headless on that prompt.

`external_directory` is not granted globally. The wrapper emits one allow rule
per trusted path, with Windows backslashes escaped for JSON: `%AGENTS_DIR%`
(the installed OpenCode agent directory; sub-agents-mcp sets it for the child,
falling back to `%CODEX_HOME%\opencode-agents` when a custom `CODEX_HOME` is
set, then `%USERPROFILE%\.codex\opencode-agents`) and
`%AGENTS_HOME%\skills\workflows` when a custom `AGENTS_HOME` is set, else
`%USERPROFILE%\.agents\skills\workflows` (the installed workflows skill
mirror). Observed cause of the previous global allow: OpenCode's built-in
`general`/`explore` agents retain `external_directory=* ask`, so nested readers
could not read the trusted installed control files and exited without a result.
A bounded direct OpenCode CLI test demonstrated that the path-scoped
external_directory allows solve that headless nested failure, including a
two-front nested smoke. Static validation (`scripts/validate.ps1`) asserts only
the wrapper contract; it does not prove runtime behavior, so a live CLI/nested
smoke remains the runtime check.

A same-name `bin/opencode.cmd` shim that rewrote the permission scalar was
tried and rejected: Windows `child_process.spawn('opencode')` resolves the
real `opencode.exe` before a same-name `.cmd`, so the shim never intercepted
the child and is not a valid boundary. Do not reintroduce it.

## Configuration

The installer mirrors `agents/opencode/*.md` to `%CODEX_HOME%\opencode-agents`,
renders the native `watcher` profile with the full `opencode_worker` handoff
block from portable placeholders, and configures the parent `opencode_worker`
MCP status-only:

```toml
[mcp_servers.opencode_worker]
args = ["-y", "github:CheekyCodexConjurer/sub-agents-mcp#v0.13.1"]
enabled_tools = ["get_agent_status", "get_agent_result", "cancel_agent"]
```

The full `run_agent`/`start_agent` tool set belongs to the installed watcher
profile only. The kit also configures the Codex agent cap
`[agents] max_concurrent_threads_per_session = 5` unless an existing
`[agents]` section already owns agent settings. The configured model follows
the `CODEX_WORKFLOWS_OPENCODE_PROVIDER` runtime flag: default `go` maps to
`opencode-go/deepseek-v4-flash`, `zen` maps to
`zenmux/deepseek/deepseek-v4-flash`. The flag is validated and never silently
falls back, and it never changes credentials — it selects only the model ID.
It takes effect at runtime in the wrapper (`bin/opencode-worker.cmd`) when set
before the MCP child starts, without a reinstall; the installer renders the
selected model explicitly into the watcher profile and the parent MCP block.
`AGENT_EFFORT=max` and the parent status-only / watcher full-handoff
separation are preserved; `JOB_DIR` and heartbeat settings remain durable. If
the selected MCP, model, credentials, or variant is unavailable, preserve the
gate as blocked. Never switch provider, permissions, transport, or model
silently.
