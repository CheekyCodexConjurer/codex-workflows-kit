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
- FANOUT: spawn one MCP agent per independent front; continue only genuine
  orchestration while they run.
- COLLECT: consume a result when a gate depends on it or no useful work
  remains.
- ACT: decide from collected evidence; route defects back to the same front
  via `deepseek_continue`, re-plan, or stop.
- VERIFY: prove the affected behavior with the mode's validation; inspect the
  integrated diff.
- REVIEW: after material write output, ask an independent agent to review it.
- DONE: run the final audit before the final response.

## MCP tool semantics

- `deepseek_spawn`: open one independent front.
- `deepseek_continue`: follow up the same front after a result, correction,
  or review; never spawn a replacement for it.
- `deepseek_follow`: consume a result when a gate depends on it, or before
  the final response for every still-needed job; normal close of a required
  job.
- `deepseek_consult`: exceptional snapshot of a running agent; never poll.
- `deepseek_abort`: stop a front only when it is obsolete or the stop is
  explicit; consume the obligation as `aborted`.
- `deepseek_close`: retire an agent after its result is consumed.
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
permission may grant write.

| Mode | Capabilities | Change permission | Done gate |
|---|---|---|---|
| `PLAN.AUTO` | read | no-write | route and next steps proven |
| `PLAN` | read | no-write | plan backed by evidence |
| `P.DEEP` | read, research | no-write | phase graph and claim-map joined |
| `RESEARCH.DEEP` | research | no-write | research fronts joined |
| `IMPL.AUTO` | read, write, test, review | write | change implemented and validated without an extra approval gate |
| `IMPL` | read, write, test, review | write | scoped behavior validated |
| `IMPL.PHASE` | read, write, test, review | write | each phase validated before the next |
| `DELIVER.AUTO` | read, write, test, review | write | integrated freeze reviewed; never commit |
| `REVIEW` | review | no-write | proven findings |
| `COMMIT` | read, verify, index, commit | git-only | commit evidence complete; never push |
| `BUG.INV` | read, test | no-write | evidence-backed hypotheses |
| `BUG.FIX` | read, write, test, review | write | regression check passes |
| `DEBUG` | read, test, write, review | write | functional gate, then clean gate |
| `REWORK` | read, research | no-write | rework roadmap backed by evidence |
| `R.A.F.V` | review, write, test | write | repair batch revalidated; no commit |
| `TN.SKILL` | read, review | no-write | quality roadmap backed by evidence |

No-edit rows never change files. `COMMIT` touches only the Git index and
never pushes. `DELIVER.AUTO` ends at the reviewed integrated diff and never
commits. No reset, pull, merge, push, publication, or destructive action
without an explicit request.

## Final audit

Before the final response, prove and report: every required job consumed
(`completed`, `completed_partial`, `failed`, `timed_out`, `aborted`, or
`explicitly unavailable-blocked`), validation run, integrated diff inspected,
independent review requested after material write output, and remaining
risks. Never declare success with an open required gate.

## References

Open only when the mode or a gate requires it:

- `references/research.md` — `RESEARCH.DEEP`
- `references/observability.md` — logging decisions
- `references/validation.md` — delivery gate and installed mirrors
- `references/commit.md` — `COMMIT`
- `references/quality-ratchet.md` — `TN.SKILL` and code quality
