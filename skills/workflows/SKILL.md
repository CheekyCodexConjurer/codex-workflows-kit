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
  series; never push. `DELIVER.AUTO` and `IMPL.AUTO` are identical aliases for
  automated end-to-end delivery: both implement, test, freeze the integrated
  diff, review, and commit locally without intermediate user approval prompts.
  Autonomous execution permission in write delivery modes: local tests use
  disposable fixtures without production access: run them, fix failures caused
  by the change, and rerun affected tests without stopping to ask for approval
  at each step. End-to-end delivery persistence: do not stop after a partial draft
  or first pass; persist until the implementation is running, tested, reviewed,
  and committed locally. Delivery quality review gate enforces P0-P2 severity rule:
  veredicto BLOCKED exige defeito comprovado P0, P1 ou P2; apontamentos P3/P4 são
  advisories não-impeditivos (APPROVED com testes verdes); revisão em rodada única sem
  loops de réplica subjetiva. Padrão de engenharia de prompts e skills em `references/astra-standards.md`.
  Read supporting documentation in `references/` contextually on demand when an active
  mode or gate requires it, avoiding blanket full-file reads for simple tasks.
- Material current, external, or high-impact claims use the `evidence-first`
  skill.
- All workflow modes perform an MCP maintenance preflight before acting (`skills/mcp-foundation/SKILL.md`; specialist skills `context7-mcp` and `codebase-memory-mcp` load on relevant tool trigger). Modos sem escrita apenas verificam; write modes may sync CodeGraph on stale/pending delay via status -> sync -> recheck, falling back to Serena/rg with a warning on failure/unknown. Serena runs via `--project-from-cwd` with one instance per project, read configuration check, no-onboarding/no-memories in no-write modes, and edits only in write modes. Codebase Memory (CBM gratuito): grafo de código estrutural (não memórias genéricas de projeto); auto preparação apenas quando útil em modos write autorizados (`IMPL`, `IMPL.AUTO`, `IMPL.PHASE`, `DELIVER.AUTO`, `BUG.FIX`, `DEBUG`, `R.A.F.V`) sob exclusions verificadas e owner único por raiz canônica/lock entre frentes paralelas, sem .codegraph init; sem instalações/indices/cache/monitores induzidos em PLAN/RESEARCH/ALINHAMENTO/COMMIT; Index não é autoridade: validar fonte original e freshness; preserve CodeGraph prioridade existente quando .codegraph existe e Serena LSP, escolha ferramenta por necessidade sem multiplicar todas. Context7 (gratuito): política credential-free sem plano pago, consulta atômica sanitizada em vez de pergunta completa, ID confiável estritamente retornado na tarefa ou fornecido pelo usuário (nunca inferir de versão), resolver só sem ID confiável, versão explícita, compartilhar pacote docs entre workers, 429 stop e docs oficiais com aviso sem trocar modelo/provider. Never auto-install, auto-upgrade, or auto-restart MCP servers (CodeGraph strictly manual init; authorized CBM repo prep exception in write delivery modes only).
- MCP automatic-use contract: the parent and every sub-agent run the canonical preflight; each relevant allowlisted MCP is routed by purpose before reading or editing. The preflight checks availability, repository scope, configuration, and freshness; it applies `Get-CodexMcpMaintenanceDecision` and, in authorized write modes, performs the permitted repository preparation (`CodeGraph` sync only when an index already exists, `Serena` project activation, and `CBM` initialization/refresh after exclusion and canonical-root lock checks), then rechecks before use. No-write modes inspect and report only. Missing or unknown MCP state is fail-closed for that route, with the documented Serena/rg or official-docs fallback; never install, authenticate, upgrade, restart, or initialize a server silently. Context7 is automatically selected when the task needs current external documentation, but remains resolve -> query and has no repository index. CodeGraph prioritizes structural questions while direct textual searches (rg) serve exact errors, literals, and configuration keys; the parent shares curated task context with sub-agents to avoid redundant discovery from root.
- Optional TypeSafe/Jev semantic optimization: skill routing (`references/skill-routing.md`) evaluates candidate skills during FRAME before FANOUT; context reranking (`references/context-reranking.md`) prioritizes search retrieval candidates (e.g. via `select-context-from-rg.ps1`) within an exact UTF-8 byte budget and privacy containment boundary before delivering context to the parent orchestrator or delegated subagents under deterministic activation gates (`MinCandidates = 8`, `ContextBudgetTriggerBytes = 12000`), hard global cost circuit breakers (`MaxCandidatesToEvaluate = 100`, `MaxJevCalls = 5`, `MaxTotalPayloadBytes = 262144`), and PINNED capacity bounds, preserving parent authority and canonical workflow lifecycle.
- The selected global backend matrix is authoritative for new Codex tasks and
  sessions. An ambiguous or unavailable matrix blocks; there is no silent
  model, provider, or route fallback.
- Automated PowerShell execution: nontrivial automated PowerShell scripts (`.ps1`) require mandatory routing through `invoke-safe-powershell.ps1` using `-File`, `-NoProfile`, and `-NonInteractive`, never nested interpolated `-Command` or `Invoke-Expression` (eliminating disappearing variables, quote corruption, and stdin hangs). Resolution: repository skill usage resolves the root helper at `scripts/invoke-safe-powershell.ps1`; an installed skill mirror resolves its own `scripts/invoke-safe-powershell.ps1`. Modes without write permissions (`no-write`) and `ALINHAMENTO` cannot create new or temporary script files to bypass authority; pre-existing non-mutating commands (somente leitura) remain direct invocations with non-interactive flags (`-NoProfile -NonInteractive`). Native binary/command failures require an explicit exit code check (`$LASTEXITCODE`), as PowerShell does not stop native failures automatically. Real-time stdout/stderr streaming must not be hidden or buffered. If the safe helper is unavailable, fail closed against the unsafe route; never attempt ad-hoc package or tool installations (`safehelper unavailable failclosed for unsafe route not packageinstall`). The helper does not intercept or police arbitrary third-party tools outside its explicit execution path.

## Division of work

Adaptive orchestration is the default behavior. The public selectors are only
`subagent_backend` and `subagent_continuation`; the first pins the tool family
and the second governs waiting and wakeup. Neither changes workflow permissions.

At FRAME and whenever a new front, terminal result, blocker, scope change,
contradiction, or pre-review event changes the evidence, the parent separates:

1. **Execution:** do the genuinely immediate work directly, continue a confirmed
   compatible worker, delegate one cohesive material front, or dispatch independent
   fronts in parallel when their expected time gain exceeds coordination cost.
2. **Review:** enforce every mode's mandatory validation and independent delivery
   review; add focused GPT analysis for security, concurrency, public contracts,
   ambiguity, or contradictory evidence. The implementer's own conversation is
   never the independent reviewer.

Use `scripts/decide-orchestration.ps1` through `invoke-safe-powershell.ps1`
with a short, sanitized request at those decision events. The script checks
permissions, consumed dependencies, ownership, worker-session eligibility,
backend capabilities, and available capacity; the parent supplies objectives,
design decisions, time estimates, risk, and final judgment. A returned decision
never authorizes a tool call by itself. Preserve the decision fingerprint while
inputs are unchanged; re-evaluate only on the listed events.

The parent GPT is architect, orchestrator, and decider. On the selected backend,
workers investigate, implement, test, and correct within explicit ownership.
The parent does not repeat delegated bulk. Reuse requires an idle open session,
provider-confirmed continuity, relevant context, compatible scope, and fresh
sources. Send a versioned compact work order with objective, scope/ownership,
context_refs, design_decisions, invariants, acceptance_criteria with stable IDs,
validation_commands, and escalation_conditions; omit genuinely irrelevant
fields. A continuation names the contract version and sends the delta only
when provider memory is confirmed. Never silently truncate requirements.

Map dependencies and shared resources before dispatch. Parallel writers require
disjoint ownership or isolation; choose the ready set that materially shortens
the task without artificial fragmentation. Respect bridge backpressure and
native exposed capacity. For MCP parallel dispatch, prove the callable batch
tool and authoritative `batch_scheduler` capability. No automatic backend,
model, or provider switch.

Before material FANOUT, compute the adaptive decision first, then call
`scripts/subagent-gate.ps1 -Gate delegation` with compact metadata only. Treat
Jev's bounded choice as advice for the parent GPT's final decision; it cannot
override permissions, dependencies, ownership, capacity, or backend selection.
The technical gate defaults to `on`; `off` makes no Jev call and `shadow`
reports a recommendation without changing the decision. See
`references/delegation.md` for its input and failure contract.

Jev advises only on narrow ambiguous questions with a short sanitized objective,
valid candidates, and relevant signals. Deterministic rules make no Jev call.
Jev cannot invent dependencies, grant permission, select the backend, or approve
code. The technical `off` and `shadow` controls affect only Jev assistance;
shadow results never change execution. Timeout, invalid response, or missing
Jev uses conservative rules and GPT judgment. The official TypeSafe contract
must be verified before changing live request syntax.

On return, consume criterion_id, status (met, failed, unverified), and
evidence_refs tied to the exact result/diff version. Keep worker claims distinct
from bridge-observed facts. Denied commands, failed or absent validation,
stale evidence, and scope conflicts remain visible and block approval. Correct
proven defects on the same worker track with specific guidance and fresh
discriminating evidence; repeated attempts without information require a new
diagnosis or escalation.

For correction adequacy, apply the event-driven gate at pre-first-edit, failure,
structural cause, scope expansion, and pre-review. Record hypothesis,
discriminating observation, delta, and next decision in the debug ledger.
Choose sufficient bounded repair without repeated identical attempts. Preserve
the mode matrix, ALINHAMENTO, COMMIT, receipt/evidence/progress/early-exit
contracts, frozen target, operational proof, independent review, and closure
rules. See `references/delegation.md` for the detailed adaptive decision map.

## Lifecycle

`active_follow` is the only mode that waits inside the run for accepted jobs.
`park_and_wake` starts a new run via CLI in the same task after its barrier fires.
Its wake marker carries trusted metadata, never worker result text or a synthetic user message.

```text
FRAME -> FANOUT -> COLLECT -> ACT -> VERIFY -> REVIEW -> DONE
```
Under `subagent_continuation = park_and_wake`, the cycle includes autonomous suspension:
```text
FRAME -> FANOUT -> [PARK -> SUSPENDED -> WAKE ->] COLLECT -> ACT -> VERIFY -> REVIEW -> DONE
```

- FRAME: goal, expected behavior, validation, and done gate before acting. Skill-routing is a deterministic sub-step executed during FRAME before FANOUT (`references/skill-routing.md`): if routing policy != off: execute skill-routing before FANOUT; if routing policy == off: preserve normal skill resolution without calling Jev. The parent GPT resolves the routing policy (`off`, `advisory`, `enforce`), discovers candidate skills from kit installation (`install-state.json`) and the local repository hierarchy (`.agents/skills` up to repository root), and extracts lightweight frontmatter metadata. When policy != off, the parent executes `skills/workflows/scripts/route-skills.ps1` with a minimized `-RoutingObjective` before FANOUT, evaluating candidates via TypeSafe/Jev System One (noul primitive in parallel batches) and resolving decisions (`forced`, `select`, `review`, `skip`, `unrouted`) under configurable thresholds (`SelectThreshold >= 0.70`, `ReviewThreshold 0.45-0.70`, `skip < 0.45`, `MaxSelectedSkills = 3`). The parent GPT consumes results according to policy: under `advisory`, recommendations guide selection without blocking overrides (`enforced: false`); under `enforce`, `select` and `skip` are enforced deterministically (`enforced: true`) while `review` escalates to the parent; under `off`, unforced candidates remain unrouted (`enforced: false`) and normal resolution proceeds. The parent GPT remains the sole orchestrator and final decider; the selected backend executes material work; Jev serves strictly as a semantic evaluation engine.
- FANOUT: apply the adaptive execution decision to the current ready
  frontier. The parent maps dependencies, ownership, available workers,
  backend capabilities, and expected time gain before dispatch. Send bounded,
  versioned orders to all useful independent fronts before waiting. Keep
  cohesive sequential work on one track and do not duplicate it locally.
  Every accepted job enters the stable request_id ledger. A selected backend
  remains pinned; an unavailable parallel capability is reported, never
  hidden behind a silent route change.
- PARK -> SUSPENDED -> WAKE: under `subagent_continuation = park_and_wake`, once
  accepted subagent jobs are launched and useful local work is drained (after all useful parent work ends), the parent calls `subagents_park` with predicate `ANY`, `ALL` (default), `QUORUM(k)` (`1 <= k <= total jobs`), or `REQUIRED(job ids)` (non-empty subset) to establish a durable wait barrier, then ends its run. Successful park returns immediately with `ParkReceipt` without in-turn wait. The parent emits a concise user-visible suspension message stating which condition will wake the task, and ends its current run transitioning to nonterminal `SUSPENDED` exclusively backed by an externally armed continuation (if unarmed or `deliveryMode=none`, the parent must remain active). Active writer is treated as durable deferred delivery (`deferred_active_writer`) and never permits auto-archive or auto-unload. When the predicate is satisfied, the proven dual CLI wake contract starts a new run in the exact same task: for a loaded Desktop session, enqueue a metadata-only marker with `codex queue` so the App automatically starts the next run; for an unloaded session, use `codex exec resume`; queue-first deterministic error routing attempts `codex queue` first and routes to `codex exec resume` on unloaded session errors; no in-turn wait, no polling; bridge returns trusted metadata only (metadata-only marker, never raw worker output or synthetic user text). Goal ownership remains separate (no goal required for continuation, and never auto-resume a paused goal). Follow and close obligations occur only after wake: upon wake in the new run, the parent calls `subagents_follow` to consume listed ready/required jobs and `subagents_close` to retire finished agents, integrates evidence, and resumes COLLECT or re-parks remaining jobs. A suspected progress wake is not a completed job and not follow-blocking (`suspectedprogresswake not completedjob/followblocking`); maintains strict separation with no new goal or provider controls. Failure states fail closed without silent fallback to active_follow; worker exceptions trigger immediate wake; active writer retries with backoff. Exactly one wake is emitted per barrier generation coalescing simultaneous completions without premature partial wake; generation supersession ensures a new barrier generation supersedes prior ones and discards stale markers.
- Checklist de andamento do parent: o parent Codex mantém uma lista curta e numerada do que foi concluído, do trabalho atual, do que falta e de bloqueios. Atualize quando uma resposta do worker for consumida, após o wake e antes de pausar ou retomar. Confira evidência antes de marcar como concluído; sem polling ou progresso inventado. Use `✓` para concluído, `◌` para em andamento e nenhum símbolo para pendente. Consulte `references/delegation.md` para o formato.
- COLLECT: consume a result when a gate depends on it or no useful work
  remains; consume every job and close each agent after integration.
- ACT: decide from collected evidence; route defects back to the same front
  via `subagents_continue` (or native follow-up), re-plan, or stop.
- VERIFY: prove the affected behavior with deterministic validation; inspect the
  integrated diff. Prioritize fast local CLI linters/formatters (e.g. `ruff` for Python, `biome` for JS/TS) and AST transforms (`ast-grep`) directly via terminal when available to handle mechanical cleanup and multi-file structural edits quickly without MCP overhead; fail open cleanly if unavailable.
- After a worker result and deterministic checks, run
  `scripts/subagent-gate.ps1 -Gate review` with compact metadata. It may only
  waive an extra parent semantic reading of an obviously safe result; failure,
  uncertainty, scope drift, architecture changes, or missing evidence require
  GPT review. It never waives independent delivery review or another workflow
  gate.
- REVIEW: after material write output in write modes, collect bounded operational proof on the frozen target when risk-triggered (live process/daemon/service, persistence/migration, concurrency/exactly-once, routing, external integration, or scale/volume), and run independent review over target and runtime evidence (`references/delivery-review.md`). Independent approval allows idle open writers with consumed jobs (`independent approval allows idle open writers with consumed jobs`), while commit/final requires closure (`commit/final requires closure`). The final unique integrated reviewer does not prohibit useful intermediate independent sharding (`final unique integrated reviewer does not prohibit useful intermediate independent sharding`).
- DONE: in write modes, run final audit, close open agents/obligations, and close the local commit series before the final response; in no-write modes (PLAN, PLAN.AUTO, RESEARCH.DEEP, BUG.INV, REVIEW, CONSULT), close immediately upon delivering the proven mode deliverable without delivery review or commit series.

## Backend tool semantics

- Under technical backend `deepseek` via SubAgents MCP, `subagents_spawn_batch` admits independent ready fronts while unitary `subagents_spawn` opens a single front;
  `subagents_continue` follows the same open front after a result, correction, or
  review; and `subagents_follow` consumes a result when a gate depends on it.
- Under technical backend `deepseek`, `subagents_park` (or legacy `deepseek_park`) arms
  a wait barrier in the bridge for accepted jobs without consuming them, returning an immediate durable
  `ParkReceipt` with stable park id, generation, deliveryMode, armed state, target identity, and pending obligations, without waiting in-turn. The parent dispatches independent fronts and drains useful local work before arming (after all useful parent work ends, arm durable predicate barrier then end run), emits a concise user-visible suspension message stating which condition will wake the task, and ends the run as `SUSPENDED`.
  Active writer conflict is a durable deferred state (`deferred_active_writer`); auto-archive and auto-unload are strictly prohibited.
  The parent may end its turn only when `ParkReceipt` proves an externally armed continuation; if unarmed or `deliveryMode=none`, the parent must remain active.
  External wake follows the proven dual CLI wake contract in the exact same task: for a loaded Desktop session, enqueue a metadata-only marker with `codex queue` so App automatically starts next run; for an unloaded session, use `codex exec resume`. Queue-first deterministic error routing attempts `codex queue` first and routes to `codex exec resume` if the session is unloaded; no in-turn wait, no polling, no raw worker output; exactly one wake per barrier generation coalescing simultaneous completions without premature partial wake; generation supersession discards stale markers.
  Follow and close obligations occur only after wake: upon wake in the new run, results are consumed with `subagents_follow`, agents are retired with `subagents_close`, and the parent continues or re-parks remaining jobs.
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

Completion contract: completion is dependency-scoped; for each dependency or wave, the parent must wait for a `final response` before `dependent synthesis or advancement` (global barrier across independent waves is forbidden; global-ready frontier allows safe prefix execution where consumed dependencies like A and Bprep permit Btail to launch while unrelated front C remains unconsumed, with versioned consumed dependency reuse and selective invalidation; no phase barriers except explicit IMPL.PHASE user gates). While a job is `running`, do not send an `interruptive follow-up` or `replace` it. `interrupted`, `errored`, `timed out`, or `missing final response` means unavailable: keep the gate `open/BLOCKED`; do not use a `silent fallback`.
Under `park_and_wake`, after all useful parent work ends, the parent dispatches independent fronts and drains useful local work before arming, emits a user-visible suspension message with waking condition, and ending the current run with obligations pending is permitted exclusively in the nonterminal `SUSPENDED` state backed by an armed `ParkReceipt` proving an externally armed continuation (if unarmed or `deliveryMode=none`, the parent must remain active). External wake follows the proven dual CLI wake contract starting a new run in the exact same task: for a loaded Desktop session, enqueue a metadata-only marker with `codex queue` so App automatically starts next run; for an unloaded session, use `codex exec resume`; queue-first deterministic error routing attempts `codex queue` first and routes to `codex exec resume` on unloaded session errors; no in-turn wait, no polling, no raw worker output, no automatic goal resume; a suspected progress wake is not a completed job and not follow-blocking (`suspectedprogresswake not completedjob/followblocking`), with no new goal or provider controls; follow and close obligations occur only after wake to consume ready jobs with `subagents_follow` and close retired agents with `subagents_close`. Exactly-once wake per generation and generation supersession apply; failure states fail closed without silent fallback to active_follow.
Commit/final requires closure: final `DONE` remains strictly forbidden until all required jobs are terminally consumed and all agents closed (incomplete final closure is forbidden; independent approval allows idle open writers with consumed jobs, but idle open writers cannot close before delivery review).

Liveness and status contract:
- Remoção de timeout rígido de conclusão: jobs aceitos e saudáveis podem rodar indefinidamente sob eventos, heartbeat e lease ativas (accepted and healthy jobs can run indefinitely under events/heartbeat/lease).
- Nenhuma janela de 900s, 20m ou 25m prova falha ou dispara graceful finalize/abort (no 900s/20m/25m window proves failure or triggers graceful finalize/abort).
- park_and_wake encerra a run e acorda por evento/predicado, sem polling e sem deadline de modelo (ends run and wakes on event/predicate, zero polling, no model deadline).
- Lease expirada sozinha não prova morte; takeover ou terminalização exige verificação de PID, heartbeat, fence tokens, quiescência comprovada ou erro terminal persistido.
- Timeouts bounded de transporte, handshake, health e connect são rigorosamente preservados, diferenciando-se explicitamente do execution timeout (bounded transport, handshake, health, and connect timeouts preserved; explicitly differentiated from execution timeout).
- Consultar status/heartbeat/lease para verificar liveness antes de inferir indisponibilidade; estado unknown bloqueia o avanço (gate open/BLOCKED).
- Fence tokens, attempt counters e PID impedem stale writes em transições de execução.
- Quiescência deve ser provada antes de liberar recursos ou abrir nova tentativa.
- Sem fallback silencioso de rota, modelo ou provedor.

Slices are designed to close terminally. Upon missing closure (ausência de fechamento)
or proven terminal error, continue on the same track (mesma trilha): request a minimal
inventory (inventário mínimo) and then execute small closure slices (closure slices pequenos).
Proibido repetir integralmente a frente; proibido abrir novo agente / substituto.

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
| `CONSULT` | read | no-write | external consultation prompt delivered |

No-edit rows never change files. `COMMIT` touches only the Git index, never
pushes, and is reserved for pre-existing or exceptional dirty worktrees.
Write delivery modes close with a validated, reviewed, scoped local commit
series and never push; `DELIVER.AUTO` and `IMPL.AUTO` operate as identical aliases,
freezing the integrated diff and committing it locally. No reset, pull, merge,
push, publication, or destructive action without an explicit request.
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
  persistence/migration, concurrency/exactly-once, routing, external integration, realistic data
  volume/resource scale, or web UI/frontend routes (such as AERA), capture bounded operational proof (observed runtime evidence, health/readiness
  latency, persistent scale state, or worker-driven local browser verification with artifact screenshots without parent vision/browser overhead) on that exact target before review;
  independent review consumes both target and runtime evidence, rejecting static-only false greens
  and issuing an APPROVED/BLOCKED verdict; blocked on unavailable/unauthorized proof without implicit
  authority broadening; blocked verdicts apply the Gate de Adequação da Correção via consolidated repair rounds oriented to sufficient and sustainable fix (`correção suficiente e sustentável/delimitada`, preserving `required_fix`) under evidence-based repair policy (`.scratchpad/debug_ledger.md`, no fixed numerical limit or disguised counters), and fail closed if
  blockers persist without safe actionable path.
- Block without changing the index on ambiguous overlap, secrets, or
  generated/cache/local/ignored candidates.
- Build a coherent commit-map with separate commits; run targeted and
  integrated validation plus `git diff --check`.
- Commit only after APPROVED review with zero blockers on matching frozen target:
  verify exact target_id before staging; after staging and immediately before commit,
  recompute staging- and host-code-page-invariant target_id, require exact equality, verify the staged
  path set matches the approved owned set, and verify every staged blob matches the
  Git-normalized approved content; follow-up fixes are new commits — no amend or rewrite.
  Independent approval allows idle open writers with consumed jobs (`independent approval allows idle open writers with consumed jobs`),
  while delivery commit and final completion require all obligations consumed and all lanes closed (`commit/final requires closure`).
  The final unique integrated reviewer does not prohibit useful intermediate independent sharding (`final unique integrated reviewer does not prohibit useful intermediate independent sharding`).
- `COMMIT` stays git-only for pre-existing or exceptional dirty worktrees,
  never alters .gitignore, and never updates MCP indexes; it classifies
  staged, unstaged, and untracked candidates and blocks without changing
  the index on local/generated/cache/secret candidates, reporting path, category,
  and suggested rule; `REWORK` stays no-write: roadmap only, never implementation; `R.A.F.V` is
  an explicitly requested separate mode, never auto-run.

## Final audit

Before the final response in write delivery modes (`IMPL.AUTO`, `IMPL`, `IMPL.PHASE`, `DELIVER.AUTO`, `BUG.FIX`, `DEBUG`), prove and report: every required job consumed
(`completed`, `completed_partial`, `failed`, `timed_out`, `aborted`, or
`explicitly unavailable-blocked`), deterministic validation run, exact frozen
target (staging- and host-code-page-invariant identity: baseline, HEAD-relative status, diff, hashes),
approved delivery review with zero blockers and verified operational proof when triggered, repaired findings revalidated, local
commit series closed without push, and remaining risks. In no-write modes (`PLAN.AUTO`, `PLAN`, `P.DEEP`, `RESEARCH.DEEP`, `REVIEW`, `BUG.INV`, `REWORK`, `TN.SKILL`, `CONSULT`), the done gate is strictly their mode deliverable; delivery review, frozen target, and commit series do not apply. Never declare success with an open required gate.

## References

Open only when the mode or a gate requires it:

- `references/delegation.md` — adaptive execution and review decisions
- `references/delivery-review.md` — delivery quality review gate and repair loop
- `references/research.md` — `RESEARCH.DEEP`
- `references/observability.md` — logging decisions
- `references/validation.md` — delivery gate and installed mirrors
- `references/commit.md` — delivery commit gate and `COMMIT`
- `references/quality-ratchet.md` — `TN.SKILL` and code quality
- `references/consult.md` — `CONSULT` external consultation prompt
- `references/skill-routing.md` — semantic skill routing gate during FRAME
- `references/context-reranking.md` — TypeSafe/Jev context reranker and budget-bounded candidate packaging
