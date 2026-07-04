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
- `subA-mgmt`: if no slot, reuse open+context-fit first; close only completed/idle unrelated stale/low-context subA; if all slots active/relevant, wait.

Models:

- `subA-model`: read-only/review uses 5.4 Mini high default; 5.4 Mini xHigh only for deep repo-wide strict audit; never 5.5 xHigh.
- `subA-worker-model`: writable worker inherits main model/effort; cap effort at high if main is xHigh unless explicit user request.

Roles:

- `subA`: inspect-only by default; writes only via `subA-worker`.
- `subA-ro`: read-only scout/reviewer/auditor; no edits; output evidence+files+risks.
- `subA?`: use if scope/risk/shared/multi-file/unclear and `subA-speed`; if used, `subA-bg/wait` applies.
- `subA-gate`: use if high blast, unclear ownership, security/auth/data risk, multi-file/core, failed first validation, or clear wall-clock gain.
- `subA-worker`: writable only with claim-map; edits direct; no revert others; no out-of-scope; final `{files,diff,val,risks}`.

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
- `reviewer`: read-only strict risk/regression/validation review.
- `worker`: writable claim-map implementation only.
