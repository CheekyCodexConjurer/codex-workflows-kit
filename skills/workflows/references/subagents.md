# Subagents

Principles:

- `orchestrator`: main owns plan, contracts, claim-map, integration, final quality.
- `main-path`: main keeps critical path moving; delegate only sidecar/non-overlap work.
- `subA-speed`: use subA when it improves wall-clock or evidence; for non-trivial work, evidence quality is sufficient even without a speed gain.
- `subA-cost`: optimize main-GPT context/tokens and evidence quality, not latency; avoid redundant fronts and unnecessary synthesis/merge work.
- `quality-first-subA`: for non-trivial work, fan out one read-only scout/researcher per independent front by default; time is secondary when the user permits it, while simple tasks remain local.

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
- `must-subA`: required before decision/final only when the mode or delivery contract marks it required; quality-first read-only fan-out is the default dispatch for non-trivial work when independent fronts exist, but is not automatically a blocking gate.
- `subA-wait`: wait until replies arrive and integrate; tool timeout is polling noise, wait again unless cancelled.
- `subA-life`: timeout/slow/not-in-time is not failure; never close active/waiting/required subA before final reply is integrated or explicit user cancel.
- `subA-block`: if must-subA cannot return due tool/external failure, leave it open and report blocked; do not pretend gate passed.
- `subA-slot-full`: if a spawn fails because all host sub-agent slots are occupied, reclaim only completed/idle subA whose final replies are already integrated, or wait for an optional subA to finish, then retry the same exact role with the same custom-spawn shape; never close active/waiting/required subA. If no slot is reclaimable, report the explicit capacity block rather than silently skipping a required gate.
- `subA-role-lock`: every read-only spawn explicitly selects `scout`, `reviewer`, `researcher`, or the native transport role `relay`; never use `default` or omit the role for read-only work, because that inherits the parent model/effort.
- Slot-full recovery permits one retry of the same exact role after safe reclamation or an optional-agent wait; if that retry fails, report the explicit capacity block and do not loop.
- `subA-custom-spawn`: custom-role spawns set only the exact `agent_type` plus their task input; omit `fork_context`, `model`, and `reasoning_effort`. Never combine `fork_context=true` with `agent_type`; full-history forks inherit the parent role/model/effort and are a separate operation.
- `visual-preflight`: when a sidecar task has images, attach the real native image
  items to the relay spawn and keep `{target_agent,cwd,task}` path-free. The relay
  emits a text-only `[VISUAL_PACKET v1]` block with source ids, visible facts, confidence,
  and uncertainties, never raw image data or paths; extraction failure blocks the
  request instead of degrading to path text. If items were attached but the relay
  returns `RELAY_VISUAL=none` or omits the status, the parent treats the result as
  blocked/unknown and does not use it for image-bearing work.
- `subA-retry`: on a transient launch, stream, or account-availability error, continue useful local work and make one fresh retry with the same exact role and the same valid custom-spawn shape; route a slot-occupied failure through `subA-slot-full` first; omit `fork_context`, `model`, and `reasoning_effort`, do not retry in a tight loop, and never fall back to `default`.
- `subA-retry-block`: if the same-role retry fails, optional scouting may be skipped with evidence; any required read-only gate remains blocked and must be reported rather than bypassed.
- `subA-isolation`: allocate one native relay and one MCP conversation per sidecar request; do not reuse completed relays or persist continuation state; close each completed relay after integrating its final response.
- `nested-opencode`: when one or more independent fronts exist, a configured OpenCode reader delegates one or more read-only tasks under `quality-first-subA` using nested types `explore` or `general`; choose the count by the independent fronts, do not cap it at one, delegate only explicit uncovered subfronts supplied by the parent, never re-delegate the assigned front, and allow at most one nested level after the main fan-out. Wait for and integrate all results, and keep simple serial work local.

Modes:

- `mode-conservative`: preserves the existing proportional behavior: simple
  write tasks may stay local and claim-mapped writers stay optional.
- `mode-aggressive`: default delegate-first lifecycle. The main remains the
  architect, integrator, tester, and final fallback rather than the default
  code implementer; it keeps the critical path and plans the claim-map.
- `agg-writer-default`: on every authorized write task in aggressive mode,
  dispatch a fresh claim-mapped `subA-worker` by default. The main writes
  directly only as final fallback/no-progress or critical shared integration.
  Explicit no-edit prevents writer spawns.
- `agg-no-cap`: aggressive mode has no arbitrary numeric worker or launch
  cap. Parallelism follows independent fronts, free slots, and risk; it never
  relaxes per-writer scope/diff limits, the serial treatment of shared-core
  work, or merge gates. A serial shared-core implementation uses one
  claim-mapped writer rather than fan-out; the main retains only its
  decision/integration and direct-fallback responsibilities.
- `agg-worker-rules`: aggressive changes dispatch frequency only, never
  worker rules; the same isolated worktree, baseline, no-touch, permission,
  and review/merge gates apply to every writer.

Models:

- `subA-model`: every custom profile uses GPT-5.4 Mini. The custom-role spawn
  itself still omits `model` and `reasoning_effort`.
- `subA-effort`: analytical unsuffixed roles use the installation default,
  GPT-5.4 Mini with `xhigh`; the native transport `relay` is intentionally
  pinned to `high` so it reliably activates the known deferred MCP function. Use
  `<role>-{low|high|max}` for an explicit effort override.
- `subA-worker-model`: apply the 5.4 Mini effort selection only to writable
  native-override workers; the default OpenCode writer uses the configured
  `opencode-go/deepseek-v4-flash` with `AGENT_EFFORT=max` through the relay.

Roles:

- `subA`: inspect-only by default; writes only via `subA-worker`.
- `subA-ro`: read-only scout/reviewer/auditor; no edits; output evidence+files+risks.
- `subA?`: use by default for non-trivial scope/risk/shared/multi-file/unclear work under `quality-first-subA`; it is not a hard gate unless `must-subA` applies; if used, `subA-bg/wait` applies.
- `subA-gate`: use if high blast, unclear ownership, security/auth/data risk, multi-file/core, failed first validation, or an explicit required quality obligation.
- `subA-worker`: writable only with claim-map; before spawning, verify the
  absolute `cwd` is a distinct clean isolated worktree and pass matching
  `WRITER_WORKTREE=<cwd>`/`WRITER_BASELINE=<full-commit>` tokens. The OpenCode
  `worker` edits that worktree through the native relay; no revert others; no
  out-of-scope; final `{files,diff,val,risks}`; the parent owns integrated
  tests, post-return path checks, and merge-gate. Under `conservative`, the
  parent may write small direct or critical integration edits; under the
  default `aggressive`, it writes only as final fallback/no-progress or
  critical shared integration.

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
- Use this route for any configured OpenCode reader or claim-map writer
  sidecar. Read-only agents may use `task` and `external_directory`; their
  definitions must deny `edit` and `bash`, while `question`, `skill`,
  `todowrite`, and `lsp` remain denied by default. The OpenCode `worker` is the
  sole default write role: it allows `edit`, denies `bash`, nested `task`, and
  `external_directory`, and edits only the supplied isolated worktree. The native `worker` profile
  remains only for an explicit native-backend maintenance override. The parent
  owns routing, integrated tests, and synthesis.
- `AGENT_PERMISSION=yolo` is only the coarse package launch profile required to
  remove the package's hardcoded `task`/`external_directory` denials. Effective
  reader no-edit and writer edit-only behavior comes from each OpenCode agent
  definition and is validated before delegation. These permissions are not an
  OS-level sandbox; do not pass secrets or rely on them to contain arbitrary
  child-process side effects. The normal `codegraph` MCP is an explicitly
  authorized exception and may remain available; review any other custom/MCP
  tool separately before enabling it.
- If the requested MCP server, CLI, credentials, model, or variant is missing,
  preserve the gate as blocked and report the exact preflight failure. Do not silently fall back or switch provider, model, effort, permission, or native/external route.

Delivery loop:

- `preflight-subA`: for non-trivial work, start the quality-first read-only fan-out across independent fronts; simple tasks stay local, parallel-safe claim-mapped slices may fan out from the start, and aggressive serial shared-core implementation uses one claim-mapped writer; this does not open the reviewer gate.
- `review-embargo`: independent reviewers remain blocked during implementation and after phase checkpoints; `phase-val` is deterministic validation, not review. A failed or unclear check may use a targeted scout without starting general review.
- `review-snapshot`: open the reviewer spawn gate only after all approved phases and workers complete, main integrates and inspects their diffs, and `integrated-freeze` passes; never review a moving diff.
- `review-tier`: contained work gets main validation plus one independent reviewer; shared/core, materially failed validation, or high-risk work gets two non-overlapping reviewer lenses. Add a separate scout only for a real evidence gap.
- `review-lenses`: split behavior/regression/test gaps from contracts/types/auth/data/concurrency; reviewers return proven actionable findings or clearly nonblocking suggestions.
- `fix-Q`: main deduplicates, prioritizes, and resolves serial/shared ownership before edits; under aggressive, an authorized serial/shared correction goes to one fresh claim-mapped repair writer unless final fallback/no-progress or critical shared integration applies, while independent clusters may fan out.
- `clean-shortcut`: if integrated validation passes and reviewers return no actionable finding, finish through `clean-gate`; do not spawn a redundant closure reviewer.
- `fix-embargo`: do not spawn a reviewer per finding or individual fix; complete the full correction batch, merge, and revalidate first.
- `closure-review`: only after a nonempty fix batch changes the diff and passes validation, one fresh read-only reviewer checks the correction delta and stable affected flow; repeat both reviewer lenses only if fixes materially changed the risk surface.
- `repair-writer`: after a validation failure, dispatch a fresh claim-mapped
  repair `subA-worker` carrying the exact error, the prior diff, and a
  materially changed hypothesis for the cause; never resubmit an equivalent
  patch.
- `repair-ledger`: after a repeat failure of the same item, record the
  attempt in the debug ledger (`.scratchpad/debug_ledger.md` with attempt
  number, assumed cause, patch hash/syntax, and error obtained) before any
  further attempt; repeating syntax-equivalent patches is forbidden.
- `repair-escalate`: if a repair writer makes no material progress, stop that
  repair loop and replan or have the main fix the item directly; do not
  respawn the same repair role with the same hypothesis.
- `session-summary`: only when the user asks, report the current session's
  readers/writers, parallel fronts, repair cycles, validation failures or
  blocks, deduplicated work, out-of-scope diffs, GPT direct fallback, elapsed
  time, and outcome. Keep it ephemeral: no telemetry collector, persistence,
  or GPT-main token metric.

Parallel work:

- `parallel-safe`: parallelize only independent files/modules/tests/contracts; shared core/contract/state is serial.
- `critical-path`: main resolves blocking architecture or contract decisions
  first; under aggressive, authorized serial implementation then goes to one
  claim-mapped writer rather than the main by default.
- `sidecars`: independent packages workers can do while main continues.
- `batch-size`: conservative uses few high-value workers and may prefer 2-4;
  aggressive has no arbitrary numeric cap and selects by independent fronts,
  free slots, and risk.
- `claim-map`: assign owner/files/modules/contracts/no-touch/validation before writable subA.
- `worker-brief`: goal + allowed files + no-touch files + expected behavior + done + validation + output.
- `repair-brief`: the minimal `worker-brief` plus the exact error, the
  prior diff, and a materially changed hypothesis for the cause; repair writers
  never repeat an equivalent patch.
- `merge-gate`: wait worker -> inspect diff -> run validation -> accept/patch/reject; no blind merge.

Suggested custom agents:

- `scout`: read-only evidence gathering, owner/path mapping, quick risk notes.
- `researcher`: read-only web/GitHub evidence gathering for an assigned, non-overlapping research front.
- `reviewer`: read-only strict risk/regression/validation review.
- `worker`: writable claim-map implementation only.
