# Subagents

Principles:

- `orchestrator`: main owns plan, contracts, claim-map, integration, final quality.
- `main-path`: main keeps critical path moving; delegate only sidecar/non-overlap work.
- `subA-speed`: use subA only when expected wall-clock gain/evidence exceeds coordination+merge cost.
- `subA-cost`: optimize wall-clock and evidence, not maximum reasoning.

Lifecycle:

- `subA-fast`: for a one-step read-only smoke or health test with explicit
  `target_agent`, absolute `cwd`, and bounded `task`, skip repository, memory,
  and configuration preflight; `target_agent` is the child role (`scout`,
  `researcher`, or `reviewer`), never the MCP server name `opencode_worker`;
  spawn one native `relay` immediately and join that same relay. Use the full
  lifecycle below for implementation, high-risk, unclear, or multi-phase work.
- `subA-bg`: spawn/message subA, then immediately continue main-path/local non-overlap work.
- `subA-join`: collect/integrate at decision/final/merge-gate or when critical path is blocked.
- `wait-smart`: `subA-bg→main-path until no useful non-overlap work→subA-join`; long waits are correct only at join gate.
- `must-subA`: required before decision/final; not required before independent local work.
- `subA-wait`: wait until replies arrive and integrate; tool timeout is polling noise, wait again unless cancelled.
- `subA-life`: timeout/slow/not-in-time is not failure; never close active/waiting/required subA before final reply is integrated or explicit user cancel.
- `subA-block`: if must-subA cannot return due tool/external failure, leave it open and report blocked; do not pretend gate passed.
- `subA-role-lock`: every read-only spawn explicitly selects `scout`, `reviewer`, `researcher`, or the native transport role `relay`; never use `default` or omit the role for read-only work, because that inherits the parent model/effort.
- `subA-custom-spawn`: custom-role spawns set only the exact `agent_type` plus their task input; omit `fork_context`, `model`, and `reasoning_effort`. Never combine `fork_context=true` with `agent_type`; full-history forks inherit the parent role/model/effort and are a separate operation.
- `subA-retry`: on a transient launch, stream, or account-availability error, continue useful local work and make one fresh retry with the same exact role and the same valid custom-spawn shape; omit `fork_context`, `model`, and `reasoning_effort`, do not retry in a tight loop, and never fall back to `default`.
- `subA-retry-block`: if the same-role retry fails, optional scouting may be skipped with evidence; any required read-only gate remains blocked and must be reported rather than bypassed.
- `subA-isolation`: allocate one native relay and one MCP conversation per sidecar request; do not reuse completed relays or persist continuation state.
- `nested-opencode`: when one or more independent fronts exist, or delegation materially improves evidence or wall-clock time, a configured OpenCode reader may delegate one or more read-only tasks using nested types `explore` or `general`; choose the count by the independent fronts, do not cap it at one, wait for and integrate all results, and keep simple serial work local.

Models:

- `subA-model`: every custom profile uses 5.4 Mini. The custom-role spawn itself still omits `model` and `reasoning_effort`.
- `subA-effort`: analytical unsuffixed roles use the installation default,
  GPT-5.4 Mini with `xhigh`; the native transport `relay` is intentionally
  pinned to `high` so it reliably activates the known deferred MCP function. Use `<role>-{low|high|max}`
  for an explicit effort override.
- `subA-worker-model`: apply the same 5.4 Mini effort selection to writable claim-mapped workers; select `max` only for a material, explicit decision gate.

Roles:

- `subA`: inspect-only by default; writes only via `subA-worker`.
- `subA-ro`: read-only scout/reviewer/auditor; no edits; output evidence+files+risks.
- `subA?`: use if scope/risk/shared/multi-file/unclear and `subA-speed`; if used, `subA-bg/wait` applies.
- `subA-gate`: use if high blast, unclear ownership, security/auth/data risk, multi-file/core, failed first validation, or clear wall-clock gain.
- `subA-worker`: writable only with claim-map; edits direct; no revert others; no out-of-scope; final `{files,diff,val,risks}`.

## Hybrid canary route

`hybrid=canary` is an explicit workflow flag for paired experiments. It does
not change the private provider policy or authorize the main chat to call an
MCP directly.

- The GPT orchestrator owns the objective, invariants, claim map, acceptance,
  integration, and escalation.
- `scout`, `researcher`, and read-only `reviewer` work continue through the
  standard `relay` → `opencode_worker` route.
- A writer task must carry the exact `HYBRID_ROUTE=writer` marker, absolute
  `HYBRID_WORKTREE` and `HYBRID_MAIN_CHECKOUT` paths that differ, the expected
  full-commit `HYBRID_BASELINE`, allowed files, no-touch files, and its
  validation contract. Before any other shell or edit command, the writer
  verifies the worktree top-level, that `git rev-parse HEAD` equals the
  baseline, and that `git status --porcelain` is empty; otherwise it reports
  `blocked`. The relay then forwards it to `opencode_hybrid_worker`.
- Before spawning a mutable writer, the parent counts active hybrid writers;
  when two are active it waits and never starts a third. They cannot commit,
  push, merge, reset, rebase, install dependencies, delegate nested tasks, or
  access external directories.
- At the merge gate, the parent runs `git -C <HYBRID_WORKTREE> diff --check`
  and `git -C <HYBRID_WORKTREE> diff -- <claim-map files>`, verifies every
  changed path against the claim map/no-touch list, runs the assigned
  validation, and applies only the accepted diff/hunks to the main checkout.
  The writer never promotes its own changes. A hybrid
  child failure or unavailable MCP remains blocked; it never silently falls
  back to a native writer or a read-only agent.
- Use `hybrid=off` for the paired baseline and record the same acceptance,
  task state, and validation for both runs. Do not add product instrumentation
  solely for this canary; use existing tool evidence.

## Internal backend route

- The private backend policy defaults to
  `internal_subagent_backend=opencode`; users do not need to add a provider flag
  to each prompt. An explicit maintenance change to
  `internal_subagent_backend=native` restores the native route.
- The default transport is `internal_subagent_transport=native_relay`: spawn a
  fresh `relay` with `multi_agent_v1__spawn_agent(agent_type=relay)` for every
  sidecar request. Pass `{target_agent,cwd,task}`, omit `fork_context`, `model`,
  and `reasoning_effort`, and do not store or forward a session identifier.
  Do not call the OpenCode MCP directly from the main chat when the relay is
  available.
- The canonical MCP server name is `opencode_worker`, backed by the pinned
  `sub-agents-mcp@0.12.0` package with `AGENT_TYPE=opencode`,
  `AGENT_MODEL=opencode-go/deepseek-v4-flash`, `AGENT_EFFORT=max`,
  `AGENT_PERMISSION=yolo` coarse launch profile, a bounded execution timeout,
  and a Windows
  `PATH` entry for the directory containing `opencode.exe`.
- `AGENT_EFFORT` is forwarded to OpenCode as the provider-specific
  `--variant`. Validate that `max` is accepted by the selected model before
  treating the route as ready; do not degrade silently to another variant.
- `sub-agents-mcp@0.8.0` is incompatible with OpenCode; official support began
  at `0.11.0`, and `0.12.0` is the explicit stable pin for this route.
- Use this route for any configured read-only OpenCode sidecar. All such agents
  may use `task` and `external_directory`; their agent definitions must deny
  `edit` and `bash`, while `question`, `skill`, `todowrite`, and `lsp` remain
  denied by default. Native `worker` profiles own all writes, patches, tests,
  and claim-map implementation. The parent owns routing and synthesis.
- `AGENT_PERMISSION=yolo` is only the coarse package launch profile required to
  remove the package's hardcoded `task`/`external_directory` denials. Effective
  no-edit behavior comes from each OpenCode agent definition and is validated
  before delegation. These permissions are not an OS-level sandbox; do not pass
  secrets or rely on them to contain arbitrary child-process side effects. The
  normal `codegraph` MCP is an explicitly authorized exception and may remain
  available; review any other custom/MCP tool separately before enabling it.
- If the requested MCP server, CLI, credentials, model, or variant is missing,
  preserve the gate as blocked and report the exact preflight failure. Do not silently fall back or switch provider, model, effort, permission, or native/external route.

Delivery loop:

- `preflight-subA`: scouts may map ownership/risk and claim-mapped workers may implement parallel-safe slices from the start; this does not open the reviewer gate.
- `review-embargo`: independent reviewers remain blocked during implementation and after phase checkpoints; `phase-val` is deterministic validation, not review. A failed or unclear check may use a targeted scout without starting general review.
- `review-snapshot`: open the reviewer spawn gate only after all approved phases and workers complete, main integrates and inspects their diffs, and `integrated-freeze` passes; never review a moving diff.
- `review-tier`: contained work gets main validation plus one independent reviewer; shared/core, materially failed validation, or high-risk work gets two non-overlapping reviewer lenses. Add a separate scout only for a real evidence gap.
- `review-lenses`: split behavior/regression/test gaps from contracts/types/auth/data/concurrency; reviewers return proven actionable findings or clearly nonblocking suggestions.
- `fix-Q`: main deduplicates and prioritizes all findings before edits; main fixes serial/shared ownership while `subA-worker` gets batched independent clusters with a fresh claim-map.
- `clean-shortcut`: if integrated validation passes and reviewers return no actionable finding, finish through `clean-gate`; do not spawn a redundant closure reviewer.
- `fix-embargo`: do not spawn a reviewer per finding or individual fix; complete the full correction batch, merge, and revalidate first.
- `closure-review`: only after a nonempty fix batch changes the diff and passes validation, one fresh read-only reviewer checks the correction delta and stable affected flow; repeat both reviewer lenses only if fixes materially changed the risk surface.

Parallel work:

- `parallel-safe`: parallelize only independent files/modules/tests/contracts; shared core/contract/state is serial.
- `critical-path`: blocking serial work main should do first.
- `sidecars`: independent packages workers can do while main continues.
- `batch-size`: use few high-value workers; prefer 2-4 unless clear reason.
- `claim-map`: assign owner/files/modules/contracts/no-touch/validation before writable subA.
- `worker-brief`: goal + allowed files + no-touch files + expected behavior + done + validation + output.
- `merge-gate`: wait worker -> inspect diff -> run validation -> accept/patch/reject; no blind merge.

Suggested custom agents:

- `scout`: read-only evidence gathering, owner/path mapping, quick risk notes.
- `researcher`: read-only web/GitHub evidence gathering for an assigned, non-overlapping research front.
- `reviewer`: read-only strict risk/regression/validation review.
- `worker`: writable claim-map implementation only.
