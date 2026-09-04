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
- All workflow modes perform an MCP maintenance preflight before acting (`skills/mcp-foundation/SKILL.md`). Modos sem escrita apenas verificam; write modes may sync CodeGraph on stale/pending delay via status -> sync -> recheck, falling back to Serena/rg with a warning on failure/unknown. Serena runs via `--project-from-cwd` with one instance per project, read configuration check, no-onboarding/no-memories in no-write modes, and edits only in write modes. Never auto-init, auto-upgrade, or auto-restart MCPs.
- The selected global backend matrix is authoritative for new Codex tasks and
  sessions. An ambiguous or unavailable matrix blocks; there is no silent
  model, provider, or route fallback.

## Division of work

- Decompose, route, prioritize, synthesize, integrate, validate, and decide.
  Delegation is governed by the orthogonal selectors (`subagent_backend`,
  `delegation_policy`, `subagent_strategy`, and `subagent_continuation`); see `references/delegation.md`.
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
  where worker subagents assist the main agent under the active delegation policy (worker mantém o fluxo atual) with punctual adequacy assessment;
  `critical` executes independent and adaptive-by-depth analysis internally (análise independente e adaptativa por profundidade internamente)
  where GPT and Gemini analyze independently, exchange evidence, and surface contradictions/gaps (troca de evidências, contradições e lacunas),
  followed by mandatory parent GPT synthesis (posterior síntese GPT mandatória pelo parent),
  with strict fencing, scope ownership, no concurrent edit across agents (sem edição concorrente),
  and pinned routing without automatic route or provider switching (sem troca automática de rota/provedor).
  Strategy never grants write; under ALINHAMENTO and in no-write modes, no-write rules strictly govern (vigora somente leitura).
  Integration contract across modes: structured receipt (`recibo`) upon job consumption, decision evidence packet (`evidence packet`: frozen target/diff, critical regions, test/review evidence, contradictions, gaps), semantic progress tracking (`semantic progress`) along the track, and early-exit (`early-exit`) upon decisive proof or blocker, operating within existing SubAgents MCP tools without promising capabilities that the bridge does not yet expose (sem prometer capacidades que o bridge ainda não expõe).
  Gate de Adequação da Correção: transversal e acionado em eventos determinísticos (`pre-first-edit`, `falha`/`failure`, `causa estrutural`/`structural-cause`, `expansão de escopo`/`scope-expansion`, `pré-revisão`/`pre-review`), nunca a cada turno, e sem trocar automaticamente de modo. Substitui a meta de "correção mínima" por correção suficiente e sustentável/delimitada, mantendo o limite de blast radius, `tn-paydown-gate`, `replan-gate`, debug ledger (`debug_ledger.md`) e no máximo duas rodadas de reparo. Emite decisões `LOCAL_FIX`, `ROBUST_FIX`, `REWORK`, `RESEARCH`, `RESEARCH_THEN_REWORK` e `BLOCKED` com evidência, confiança, causa-raiz, contradições, validação exigida, escopo pertencente/adiado e próximo modo recomendado. O SubAgents MCP e o daemon bridge operam como transporte neutro (`neutral transport`), reutilizando `EvidenceBundle`, `ExecutionReceipt`, `ProgressSnapshot`, heartbeat, fence token, relation `correction`/`review`; nenhuma regra de workflow ou aprovação no bridge (sem regras de workflow no bridge). Integra explicitamente `PLAN`/`PLAN.AUTO` (no-write), `DEBUG`/`BUG.FIX` (write), `DELIVER`/`IMPL` (write), `REWORK` (no-write) e `RESEARCH.DEEP` (no-write), preservando `ALINHAMENTO` (no-write, sem metadados) e `COMMIT` (git-only).
- Under `subagent_continuation`: `active_follow` (default; backward-compatible) maintains synchronous tracking with `subagents_follow` until job completion without ending the current turn; `park_and_wake` (Sub-agent Autonomy) implements a two-path hybrid lifecycle without model polling: for a loaded task in Desktop/host, one event-driven `subagents_park`/`deepseek_park` wait suspends inference until an event returns in the same turn (no model polling); for a disconnected/notLoaded task, a durable externally armed barrier may wake the exact task via the compatible CLI path; active writer represents durable deferred delivery (`deferred_active_writer`), never a terminal failure, fallback, or permission to auto-archive/unload; the parent may end its turn with open obligations exclusively in the nonterminal `SUSPENDED` state once an armed `ParkReceipt` explicitly proves an externally armed continuation; if the receipt returns `deliveryMode=none` or unarmed, the parent must remain active and resolve obligations; after wake, consume listed ready jobs with `subagents_follow`, integrate them, and either continue or re-park remaining jobs; bridge payload contains trusted metadata only (never worker result text or synthetic user prompt instructions); goal pause ownership remains separate: chat/task continuation does not require a goal and never automatically resumes a paused goal; if parking fails to arm, fail closed without silent fallback to active_follow; final `DONE` remains strictly impossible until all required jobs are terminally consumed and agents closed; the bridge remains a neutral transport without deciding workflow approvals or interpreting AGENTS flags; Gemini emits worker progress/completion events without controlling Codex chat/goal; zero flags or state are injected into consumer repos.
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
Under `subagent_continuation = park_and_wake`, the cycle includes autonomous suspension:
```text
FRAME -> FANOUT -> [PARK -> SUSPENDED -> WAKE ->] COLLECT -> ACT -> VERIFY -> REVIEW -> DONE
```

- FRAME: goal, expected behavior, validation, and done gate before acting.
- FANOUT: policy-aware delegation. In `balanced`, fan out conditionally for
  concrete independent parallelism, specialization, risk isolation, or
  large-context compression. In `aggressive`, map all independent fronts,
  dependencies, and exclusive/shared resources before waiting; launch every
  independent material front in batch before the first follow. Keep a stable
  request_id ledger (front, agent, job, state, consumed, closed).
- PARK -> SUSPENDED -> WAKE: under `subagent_continuation = park_and_wake`, once
  accepted subagent jobs are launched, the parent calls `subagents_park` to establish
  a durable wait barrier. In a loaded task, this is an in-turn event wait suspending
  inference until an event returns without model polling. For a disconnected/notLoaded
  task, the durable barrier arms an external wake via compatible CLI. Active writer
  is treated as durable deferred delivery (`deferred_active_writer`) and never permits
  auto-archive or auto-unload. The parent transitions to nonterminal `SUSPENDED` and ends
  its turn only if the durable receipt confirms an externally armed continuation (if unarmed
  or `deliveryMode=none`, the parent must remain active). When a terminal or needs-approval
  event occurs, the bridge returns trusted metadata only (never worker result text).
  Goal ownership remains separate (no goal required for continuation, and never auto-resume
  a paused goal). Upon wake, the parent calls `subagents_follow` to resume COLLECT.
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
- Under technical backend `deepseek`, `subagents_park` (or legacy `deepseek_park`) arms
  a wait barrier in the bridge for accepted jobs without consuming them, returning a durable
  `ParkReceipt` with stable park id, generation, deliveryMode, armed state, target identity, and pending obligations.
  In loaded tasks, inference waits in-turn without model polling; for disconnected/notLoaded tasks, external CLI wake is armed.
  Active writer conflict is a durable deferred state (`deferred_active_writer`); auto-archive and auto-unload are strictly prohibited.
  The parent may end its turn only when `ParkReceipt` proves an externally armed continuation; if unarmed or `deliveryMode=none`, the parent must remain active.
  Upon wake, results are consumed with `subagents_follow`, and the parent continues or re-parks remaining jobs.
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
Under `park_and_wake`, ending the current turn with obligations pending is permitted
exclusively in the nonterminal `SUSPENDED` state backed by an armed `ParkReceipt` proving
an externally armed continuation (if unarmed or `deliveryMode=none`, the parent must remain active).
Final `DONE` remains strictly forbidden until all required jobs are terminally consumed
and all agents closed.

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
Subagent execution remains strictly bounded by the mode matrix: in no-write modes and in
ALINHAMENTO, subagents operate strictly under no-write (somente leitura); strategy never grants
write permissions. In write modes, strict path ownership and independent review
govern all output before commit. Integration adheres to the receipt (`recibo`), decision
evidence packet, semantic progress, and early-exit contract without promising capabilities
that the bridge does not yet expose.

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
  authority broadening; blocked verdicts apply the Gate de Adequação da Correção via consolidated repair rounds oriented to sufficient and sustainable fix (`correção suficiente e sustentável/delimitada`, preserving `required_fix`), at most 2 rounds, and fail closed if
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
- `COMMIT` stays git-only for pre-existing or exceptional dirty worktrees,
  never alters .gitignore, and never updates MCP indexes; it classifies
  staged, unstaged, and untracked candidates and blocks without changing
  the index on local/generated/cache/secret candidates, reporting path, category,
  and suggested rule; `REWORK` stays no-write: roadmap only, never implementation; `R.A.F.V` is
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
