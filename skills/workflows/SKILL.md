---
name: workflows
description: Canonical `$workflows` router: lifecycle, MCP tool semantics, mode contract, and final audit.
---

# Workflows

Use this skill when a prompt invokes `$workflows` with `mode=<MODE>`.
This file is the single detailed policy. Open a reference below only when the
selected mode or an open gate requires it.

## Contract

- `$workflows mode=<MODE>` is the complete contract: the mode defines the
  capabilities, the change permission, the validation, and the done gate.
  Treat trailing text as task context.
- Preserve existing work. Define the failure signature and validation before
  editing. No instrumentation without an explicit `obs-gate` contract
  (`observability.md`).
- Write delivery modes close with a validated, reviewed, scoped local commit
  series; never push.
- Material current, external, or high-impact claims use the `evidence-first`
  skill.

## Division of work

- The parent GPT is the brain, not the repository workforce: decompose,
  route, prioritize, synthesize, integrate, validate, and decide.
- DeepSeek Sub-Agent MCP is the primary executor: every material bounded
  front is delegated — read, research, write, test, and review work — one
  agent per front, never duplicate a front, never repeat a delegated front
  locally.
- The parent owns vision: inspect the image yourself and pass a concise
  `visual_context` to the delegated agent (direct observations, visible
  text, interpretation, uncertainty). Do not delegate blind image
  interpretation.
- Local work is atomic only: to formulate a delegation, to integrate a
  result, or to spot-check a claim.

## Lifecycle

```text
FRAME -> FANOUT -> COLLECT -> ACT -> VERIFY -> REVIEW -> DONE
```

- FRAME: goal, expected behavior, validation, and done gate before acting.
- FANOUT: map independent fronts, dependencies, and exclusive/shared
  resources before waiting; launch every independent material front as a batch
  before the first follow, keeping only real dependency or shared-resource
  lanes serial; keep a stable request_id ledger (front, agent, job, state,
  consumed, closed); spawn one MCP agent per independent front and continue
  only genuine orchestration while they run.
- COLLECT: consume a result when a gate depends on it or no useful work
  remains; consume every job and close each agent after integration.
- ACT: decide from collected evidence; route defects back to the same front
  via `deepseek_continue`, re-plan, or stop.
- VERIFY: prove the affected behavior with the mode's validation; inspect the
  integrated diff.
- REVIEW: after material write output, ask an independent agent to review it.
- DONE: run the final audit and close the local commit series before the
  final response.

## MCP tool semantics

- `deepseek_spawn`: open one independent front.
- `deepseek_continue`: follow up the same front after a result, correction,
  or review; never spawn a replacement for it. After a premature close with
  a terminal result, a correction strictly within the same request/scope/cwd/
  ownership/model route resumes automatically with `allow_respawn=true` — no
  new consent prompt; recovery creates a new session/agent with lineage, never
  a fake continuation of the original session, and never applies to running
  jobs, missing final responses, explicitly aborted fronts, divergent
  scope/cwd/ownership/model routes, or material changes beyond the original
  request; provider fallback stays forbidden.
- `deepseek_follow`: consume a result when a gate depends on it, or before
  the final response for every still-needed job; normal close of a required
  job.
- `deepseek_consult`: exceptional snapshot of a running agent; never poll.
- `deepseek_abort`: stop a front only when it is obsolete or the stop is
  explicit; consume the obligation as `aborted`.
- `deepseek_close`: retire an agent after its result is consumed; a write
  front closes only after the independent review and the proven corrections,
  and a premature close stays recoverable only through `deepseek_continue`
  with `allow_respawn=true` as described above.
- `deepseek_recover_result`: delivery recovery only; never re-open or re-run
  a finished front.

## Completion contract

Completion contract: for every required job, the parent must wait for a
`final response` before `synthesis or advancement`. While a job is `running`,
do not send an `interruptive follow-up` or `replace` it. `interrupted`,
`errored`, `timed out`, or `missing final response` means unavailable: keep
the gate `open/BLOCKED`; do not use a `silent fallback`.

Normative contract:
`completion_policy = { required = "final_response", running = "no_interrupt_or_replace", missing = "gate_open_blocked", fallback = "forbidden" }`

## Modes

Each row is `capabilities | change permission | done gate`. Capability names
are read, research, write, test, review, verify, index, and commit. Modes
grant exactly these capabilities; no mode with a no-write or git-only
permission may grant write, and commit is granted only to write and git-only
permissions.

| Mode | Capabilities | Change permission | Done gate |
|---|---|---|---|
| `PLAN.AUTO` | read | no-write | route and next steps proven |
| `PLAN` | read | no-write | plan backed by evidence |
| `P.DEEP` | read, research | no-write | phase graph and claim-map joined |
| `RESEARCH.DEEP` | research | no-write | research fronts joined |
| `IMPL.AUTO` | read, write, test, review, commit | write | change implemented and validated without an extra approval gate; local commit series; never push |
| `IMPL` | read, write, test, review, commit | write | scoped behavior validated; local commit series; never push |
| `IMPL.PHASE` | read, write, test, review, commit | write | each phase validated before the next; final local commit series; never push |
| `DELIVER.AUTO` | read, write, test, review, commit | write | integrated freeze reviewed; local commit series; never push |
| `REVIEW` | review | no-write | proven findings |
| `COMMIT` | read, verify, index, commit | git-only | commit evidence complete; never push |
| `BUG.INV` | read, test | no-write | evidence-backed hypotheses |
| `BUG.FIX` | read, write, test, review, commit | write | regression check passes; local commit series; never push |
| `DEBUG` | read, test, write, review, commit | write | functional gate, then clean gate; local commit series; never push |
| `REWORK` | read, research | no-write | rework roadmap backed by evidence |
| `R.A.F.V` | review, write, test, commit | write | repair batch revalidated; local commit series; no push |
| `TN.SKILL` | read, review | no-write | quality roadmap backed by evidence |

No-edit rows never change files. `COMMIT` touches only the Git index, never
pushes, and is reserved for pre-existing or exceptional dirty worktrees.
Write delivery modes close with a validated, reviewed, scoped local commit
series and never push; `DELIVER.AUTO` freezes the integrated diff and commits
it locally. No reset, pull, merge, push, publication, or destructive action
without an explicit request.

## Delivery commit gate

Write modes — `IMPL.AUTO`, `IMPL`, `IMPL.PHASE`, `DELIVER.AUTO`, `BUG.FIX`,
`DEBUG`, `R.A.F.V` — end with a validated, reviewed, scoped local commit
series; never push. `references/commit.md` owns the gate details:

- Record the baseline and claim-map/path ownership before work; the series
  commits only owned changes — never pre-existing, staged, or other-front
  changes.
- Block without changing the index on ambiguous overlap, secrets, or
  generated/cache/local/ignored candidates.
- Build a coherent commit-map with separate commits; run targeted and
  integrated validation plus `git diff --check`.
- Independent review before commit; follow-up fixes are new commits — no
  amend or rewrite.
- `COMMIT` stays git-only for pre-existing or exceptional dirty worktrees;
  `REWORK` stays no-write: roadmap only, never implementation.

## Final audit

Before the final response, prove and report: every required job consumed
(`completed`, `completed_partial`, `failed`, `timed_out`, `aborted`, or
`explicitly unavailable-blocked`), validation run, integrated diff inspected,
independent review requested after material write output, local commit series
closed without push, and remaining risks. Never declare success with an open
required gate.

## References

Open only when the mode or a gate requires it:

- `references/research.md` — `RESEARCH.DEEP`
- `references/observability.md` — logging decisions
- `references/validation.md` — delivery gate and installed mirrors
- `references/commit.md` — delivery commit gate and `COMMIT`
- `references/quality-ratchet.md` — `TN.SKILL` and code quality
