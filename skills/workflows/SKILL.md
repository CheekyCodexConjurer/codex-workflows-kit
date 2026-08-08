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

## Roles

- The parent GPT is the brain and maestro: decompose, delegate, integrate,
  validate, and decide. Local work is atomic and only for integration or
  spot-check.
- DeepSeek Sub-Agent MCP is the primary executor: every material bounded
  front is delegated (`scout` evidence, `researcher` research, `writer`
  implementation, `reviewer` review) — one worker per front, never duplicate
  a front, never repeat a delegated front locally.
- The parent owns vision: inspect the image yourself and pass a concise
  `visual_context` to the worker (direct observations, visible text,
  interpretation, uncertainty). Do not delegate blind image interpretation.

## Lifecycle

```text
FRAME -> FANOUT -> COLLECT -> ACT -> VERIFY -> REVIEW -> DONE
```

- FRAME: goal, expected behavior, validation, and done gate before acting.
- FANOUT: spawn one MCP worker per independent front; continue useful local
  orchestration while they run.
- COLLECT: consume a worker result when a gate depends on it or no useful
  work remains.
- ACT: decide from collected evidence; route defects back to the same worker
  via `deepseek_continue`, re-plan, or stop.
- VERIFY: prove the affected behavior with the mode's validation; inspect the
  integrated diff.
- REVIEW: after material writer output, ask an independent reviewer.
- DONE: run the final audit before the final response.

## MCP tool semantics

- `deepseek_spawn`: open one independent front.
- `deepseek_continue`: follow up the same front after a result, correction,
  or review; never spawn a replacement for it.
- `deepseek_follow`: consume a result when no useful work remains or a gate
  depends on it; normal close of a required job.
- `deepseek_consult`: exceptional snapshot of a running worker; never poll.
- `deepseek_abort`: stop a front only when it is obsolete or the stop is
  explicit; consume the obligation as `aborted`.
- `deepseek_close`: retire a worker after its result is consumed.
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

Each row is `capabilities | change permission | done gate`. Capability labels
describe the delegated jobs on the MCP runtime.

| Mode | Capabilities | Permission | Done gate |
|---|---|---|---|
| `PLAN.AUTO` | scout when evidence requires | no write | route and rationale proven |
| `PLAN` | scout | no write | required evidence joined |
| `P.DEEP` | scout, researcher | no write | phase graph and claim-map joined |
| `RESEARCH.DEEP` | researcher | no write | research fronts joined |
| `IMPL.AUTO` | scout preflight; writer | write | change implemented and validated without an extra approval gate |
| `IMPL` | scout; reviewer on risk | write | scoped behavior validated |
| `IMPL.PHASE` | scout/reviewer at phase gates | write | each phase validated before the next |
| `DELIVER.AUTO` | scout; reviewer | write | integrated freeze reviewed; never commit |
| `REVIEW` | reviewer | no write | proven findings joined |
| `COMMIT` | scout when classification is material | index only | commit evidence complete; never push |
| `BUG.INV` | scout, researcher | no write | evidence-backed hypotheses joined |
| `BUG.FIX` | scout; reviewer | write | regression check passes |
| `DEBUG` | scout, researcher; reviewer on repair | write | functional gate, then clean gate |
| `REWORK` | scout, researcher | no write | rework roadmap joined |
| `R.A.F.V` | reviewer; scout | write | repair batch revalidated; no commit |
| `TN.SKILL` | reviewer; scout | no write | quality roadmap joined |

No-edit rows never change files. `COMMIT` touches only the Git index and
never pushes. `DELIVER.AUTO` ends at the reviewed integrated diff and never
commits. No reset, pull, merge, push, publication, or destructive action
without an explicit request.

## Final audit

Before the final response, prove and report: every required job consumed
(`completed`, `completed_partial`, `failed`, `timed_out`, `aborted`, or
`explicitly unavailable-blocked`), validation run, integrated diff inspected,
independent review requested after material writer output, and remaining
risks. Never declare success with an open required gate.

## References

Open only when the mode or a gate requires it:

- `references/research.md` — `RESEARCH.DEEP`
- `references/observability.md` — logging decisions
- `references/validation.md` — delivery gate and installed mirrors
- `references/commit.md` — `COMMIT`
- `references/quality-ratchet.md` — `TN.SKILL` and code quality
