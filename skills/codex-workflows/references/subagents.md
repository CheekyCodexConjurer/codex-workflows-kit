# Subagents

Principles:

- `orchestrator`: main owns plan, contracts, claim-map, integration, final quality.
- `main-path`: main keeps critical path moving; delegate only sidecar/non-overlap work.
- `subA-speed`: use subA only when expected wall-clock gain/evidence exceeds coordination+merge cost.
- `subA-cost`: optimize wall-clock and evidence, not maximum reasoning.

Lifecycle:

- `subA-bg`: spawn/message subA, then immediately continue main-path/local non-overlap work.
- `subA-join`: collect/integrate at decision/final/merge-gate or when critical path is blocked.
- `wait-smart`: `subA-bg→main-path until no useful non-overlap work→subA-join`; long waits are correct only at join gate.
- `must-subA`: required before decision/final; not required before independent local work.
- `subA-wait`: wait until replies arrive and integrate; tool timeout is polling noise, wait again unless cancelled.
- `subA-life`: timeout/slow/not-in-time is not failure; never close active/waiting/required subA before final reply is integrated or explicit user cancel.
- `subA-block`: if must-subA cannot return due tool/external failure, leave it open and report blocked; do not pretend gate passed.
- `subA-role-lock`: every read-only spawn explicitly selects `scout`, `reviewer`, or `researcher`; never use `default` or omit the role for read-only work, because that inherits the parent model/effort.
- `subA-custom-spawn`: custom-role spawns set only the exact `agent_type` plus their task input; omit `fork_context`, `model`, and `reasoning_effort`. Never combine `fork_context=true` with `agent_type`; full-history forks inherit the parent role/model/effort and are a separate operation.
- `subA-retry`: on a transient launch, stream, or account-availability error, continue useful local work and make one fresh retry with the same exact role and the same valid custom-spawn shape; omit `fork_context`, `model`, and `reasoning_effort`, do not retry in a tight loop, and never fall back to `default`.
- `subA-retry-block`: if the same-role retry fails, optional scouting may be skipped with evidence; any required read-only gate remains blocked and must be reported rather than bypassed.
- `subA-mgmt`: if no slot, reuse open+context-fit first; close only completed/idle unrelated stale/low-context subA; if all slots active/relevant, wait.
- `subA-reuse`: prefer reusing a context-fit agent for the same ownership or lens instead of spawning one per phase, file, finding, or fix.

Models:

- `subA-model`: every custom profile uses 5.6 Sol. The custom-role spawn itself still omits `model` and `reasoning_effort`.
- `subA-effort`: select the unsuffixed role for `medium`, or `<role>-{low|high|xhigh|max}` for the effort warranted by the current task.
- `subA-worker-model`: apply the same 5.6 Sol effort selection to writable claim-mapped workers; select `max` only for a material, explicit decision gate.

Roles:

- `subA`: inspect-only by default; writes only via `subA-worker`.
- `subA-ro`: read-only scout/reviewer/auditor; no edits; output evidence+files+risks.
- `subA?`: use if scope/risk/shared/multi-file/unclear and `subA-speed`; if used, `subA-bg/wait` applies.
- `subA-gate`: use if high blast, unclear ownership, security/auth/data risk, multi-file/core, failed first validation, or clear wall-clock gain.
- `subA-worker`: writable only with claim-map; edits direct; no revert others; no out-of-scope; final `{files,diff,val,risks}`.

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
