---
name: workflows
description: Canonical `$workflows` router: backend-aware lifecycle, MCP/native tool semantics, mode contract, and final audit.
---

# Workflows

Use this skill when a prompt invokes `$workflows` with `mode=<MODE>`.
This file is the single detailed policy. Open a reference below only when the
selected mode or an open gate requires it.

## Contract

- `$workflows mode=<MODE>` is the complete contract: the mode defines the
  capabilities, the change permission, the validation, and the done gate.
  Treat trailing text as task context.
- Without an active mode (`$workflows mode=<MODE>`), the system operates in the
  implicit user-facing state `ALINHAMENTO`: conversational no-write discussion, idea
  refinement, and doubts without workflow ceremony (no formal plan, spec, todo list,
  approval gates, or delivery classification); standard output in compact pt-BR
  with short understanding confirmation; for noisy audio transcripts, normalize
  obvious noise with explicit premises and ask only if material ambiguity alters
  the answer or routing; do not narrate internal routing/skills/tools (beyond a
  short notice if the platform requires it); repository inspection occurs only when
  the answer materially depends on it (smallest sufficient read); conditional subagent
  delegation is limited to inspection without mutation (somente leitura); forbidden to trigger tools or
  activations known to create workspace metadata or local state (if a read route
  requires mutation, fail closed and respond without it); no file creation/edit/deletion,
  no tests/builds, no Git index/commit, and no stateful mutation. Imperative verbs
  never infer a mode. When action is the next step, recommend the exact explicit
  workflow mode.
- An explicit workflow mode remains active for the same execution through
  unprefixed clarifications and follow-ups until its done gate, explicit
  cancellation, or explicit permitted replacement. Cancellation does not
  authorize process kills, destructive rollback, or new mutation. Upon closure,
  subsequent demands without an active mode return to ALINHAMENTO.
- Preserve existing work. Define the failure signature and validation before
  editing. No instrumentation without an explicit `obs-gate` contract
  (`observability.md`).
- Write delivery modes close with a validated, reviewed, scoped local commit
  series; never push.
- Material current, external, or high-impact claims use the `evidence-first`
  skill.
- The selected global backend matrix is authoritative for new Codex tasks and
  sessions. An ambiguous or unavailable matrix blocks; there is no silent
  model, provider, or route fallback.

## Division of work

- Decompose, route, prioritize, synthesize, integrate, validate, and decide.
  Delegation is governed by the orthogonal selectors (`subagent_backend`,
  `delegation_policy`, and `subagent_strategy`); see `references/delegation.md`.
- Under `balanced` (default; wall-clock optimization): parent directly performs
  cohesive, sequential, critical-path material work when delegation round-trip
  would not help; delegates for concrete independent parallelism, specialization,
  risk isolation, or large-context compression. No mandatory fan-out.
- Under `aggressive` (parent-token offload): parent acts as architect, decider,
  integrator, and gatekeeper; delegates material bulk without redoing delegated
  work locally; consumes a decision evidence packet (frozen target/diff, critical
  regions, test/review evidence, conflicts). Maintains one persistent track per
  cohesive front; no microdelegation; new track only for an independently
  acceptable deliverable.
- Under `subagent_strategy`: `worker` (default) preserves the existing workflow
  where worker subagents assist the main agent under the active delegation policy (worker mantém o fluxo atual);
  `critical` requires that GPT and Gemini analyze independently, exchange evidence and
  surface contradictions/gaps, and only then synthesize (análise independente rigorosa,
  troca de evidências e contradições, lacunas, e posterior síntese GPT mandatória pelo parent),
  with strict fencing, scope ownership, and no concurrent edit across agents (sem edição concorrente).
  Strategy never grants write; under ALINHAMENTO, no-write rules strictly govern (vigora somente leitura).
- Native mode uses native Codex subagents for delegated material fronts; each
  native spawn passes `model="gpt-5.6-luna"` and `reasoning_effort="max"`
  explicitly, states normal/default mode, and never selects Flash/Fast. Forbids
  SubAgents MCP.
- Under technical backend `deepseek`, use SubAgents MCP (`subagents_spawn`/`subagents_continue`/`subagents_follow`; compatibilidade com aliases `deepseek_*`) for
  delegated material fronts — one agent per front, never duplicate a front, never
  repeat a delegated front locally. DeepSeek-specific daemon recovery is allowed
  only when this technical backend is selected and only under the MCP foundation exception.
  Forbids native work tools.
- The parent owns vision: inspect the image yourself and pass a concise
  `visual_context` to the delegated agent (direct observations, visible
  text, interpretation, uncertainty). Do not delegate blind image
  interpretation.
- Never redo a delegated material front locally.

## Lifecycle

```text
FRAME -> FANOUT -> COLLECT -> ACT -> VERIFY -> REVIEW -> DONE
```

- FRAME: goal, expected behavior, validation, and done gate before acting.
- FANOUT: policy-aware delegation. In `balanced`, fan out conditionally for
  concrete independent parallelism, specialization, risk isolation, or
  large-context compression. In `aggressive`, map all independent fronts,
  dependencies, and exclusive/shared resources before waiting; launch every
  independent material front in batch before the first follow. Keep a stable
  request_id ledger (front, agent, job, state, consumed, closed).
- COLLECT: consume a result when a gate depends on it or no useful work
  remains; consume every job and close each agent after integration.
- ACT: decide from collected evidence; route defects back to the same front
  via `subagents_continue` (or native follow-up), re-plan, or stop.
- VERIFY: prove the affected behavior with deterministic validation; inspect the
  integrated diff.
- REVIEW: after material write output in write modes, collect bounded operational proof on the frozen target when risk-triggered (live process/daemon/service, persistence/migration, concurrency/exactly-once, routing, external integration, or scale/volume), and run independent review over target and runtime evidence (`references/delivery-review.md`).
- DONE: run the final audit and close the local commit series before the
  final response.

## Backend tool semantics

- Under technical backend `deepseek` via SubAgents MCP, `subagents_spawn` opens one independent front;
  `subagents_continue` follows the same open front after a result, correction, or
  review; and `subagents_follow` consumes a result when a gate depends on it.
- Under technical backend `deepseek`, `subagents_consult` is an exceptional snapshot of a
  running agent and never a poll; `subagents_abort` is only for an obsolete or
  explicitly stopped front; `subagents_close` retires an agent after its result
  is consumed; and `subagents_recover_result` is delivery recovery only.
- A persistent lane under technical backend DeepSeek normally continues the same open agent with
  `subagents_continue`, without `allow_respawn`. A DeepSeek correction after a
  premature close is limited to `allow_respawn=true` for the same
  request/scope/cwd/ownership/model route, with a new session/agent with lineage,
  no new consent prompt, and never a fake continuation. A terminal result is
  required; never recover running jobs, missing final responses, explicitly
  aborted fronts/jobs, divergent scope, or material changes; provider fallback
  stays forbidden; never use `allow_respawn` as routine persistence; active jobs
  only allow recovery when all have proven durable spool/recovery; stale-running
  with absent daemon reconciles only with installed durable capacity.
- In native mode, use native subagents with the same completion,
  review, and no-fallback rules; do not contact the SubAgents MCP.

## Completion contract

Completion contract: for every required job, the parent must wait for a
`final response` before `synthesis or advancement`. While a job is `running`,
do not send an `interruptive follow-up` or `replace` it. `interrupted`,
`errored`, `timed out`, or `missing final response` means unavailable: keep
the gate `open/BLOCKED`; do not use a `silent fallback`.

Liveness and status contract:
- 900s é apenas janela mínima e limite de espera (timeout window), nunca prova de morte do agente ou processo.
- Consultar status/heartbeat/lease para verificar liveness antes de inferir indisponibilidade.
- Takeover só é autorizado com morte provada do executor anterior; estado unknown bloqueia o avanço (gate open/BLOCKED).
- Fence tokens, attempt counters e PID impedem stale writes em transições de execução.
- Quiescência deve ser provada antes de liberar recursos ou abrir nova tentativa.
- Sem fallback silencioso de rota, modelo ou provedor.

Slices are designed to close terminally within the window. Upon timeout or
missing closure (ausência de fechamento), continue on the same track (mesma trilha):
request a minimal inventory (inventário mínimo) and then execute small closure
slices (closure slices pequenos). Proibido repetir integralmente a frente; proibido
abrir novo agente / substituto.

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

Write modes (`IMPL.AUTO`, `IMPL`, `IMPL.PHASE`, `DELIVER.AUTO`, `BUG.FIX`,
`DEBUG`) and manual `R.A.F.V` end with a validated, reviewed, scoped local
commit series; never push. `references/delivery-review.md` and
`references/commit.md` own the gate details:

- Record the baseline and claim-map/path ownership before work; the series
  commits only owned changes — never pre-existing, staged, or other-front
  changes.
- Freeze target with staging- and host-code-page-invariant identity (baseline, owned HEAD-relative
  content status, integrated diff against HEAD, per-file hashes; raw porcelain
  captured as evidence outside digest). When touching live processes/daemons/services,
  persistence/migration, concurrency/exactly-once, routing, external integration, or realistic data
  volume/resource scale, capture bounded operational proof (observed runtime evidence, health/readiness
  latency, persistent scale state, and artifact identity) on that exact target before review;
  independent review consumes both target and runtime evidence, rejecting static-only false greens
  and issuing an APPROVED/BLOCKED verdict; blocked on unavailable/unauthorized proof without implicit
  authority broadening; blocked verdicts use at most 2 consolidated repair rounds and fail closed if
  blockers persist.
- Block without changing the index on ambiguous overlap, secrets, or
  generated/cache/local/ignored candidates.
- Build a coherent commit-map with separate commits; run targeted and
  integrated validation plus `git diff --check`.
- Commit only after APPROVED review with zero blockers on matching frozen target:
  verify exact target_id before staging; after staging and immediately before commit,
  recompute staging- and host-code-page-invariant target_id, require exact equality, verify the staged
  path set matches the approved owned set, and verify every staged blob matches the
  Git-normalized approved content; follow-up fixes are new commits — no amend or rewrite.
- `COMMIT` stays git-only for pre-existing or exceptional dirty worktrees;
  `REWORK` stays no-write: roadmap only, never implementation; `R.A.F.V` is
  an explicitly requested separate mode, never auto-run.

## Final audit

Before the final response, prove and report: every required job consumed
(`completed`, `completed_partial`, `failed`, `timed_out`, `aborted`, or
`explicitly unavailable-blocked`), deterministic validation run, exact frozen
target (staging- and host-code-page-invariant identity: baseline, HEAD-relative status, diff, hashes),
approved delivery review with zero blockers and verified operational proof when triggered, repaired findings revalidated, local
commit series closed without push, and remaining risks. Never declare success with
an open required gate.

## References

Open only when the mode or a gate requires it:

- `references/delegation.md` — `balanced` vs `aggressive` delegation policies
- `references/delivery-review.md` — delivery quality review gate and repair loop
- `references/research.md` — `RESEARCH.DEEP`
- `references/observability.md` — logging decisions
- `references/validation.md` — delivery gate and installed mirrors
- `references/commit.md` — delivery commit gate and `COMMIT`
- `references/quality-ratchet.md` — `TN.SKILL` and code quality
