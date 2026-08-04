# Mode Matrix

AHK launchers paste the canonical `$workflows` prefix with `mode=<MODE>`.
`$codex-workflows`, `$antigravity-workflows`, and `$opencode-workflows` remain
compatibility aliases generated from the same source. Each mode entry below
is the canonical default execution contract; optional trailing user text
provides task context or an explicit override.

## Internal provider and transport route

The installed internal policy defaults to
`internal_subagent_backend=opencode` with
`internal_subagent_transport=native_relay`; neither is a user-facing prompt
flag. If a mode decides that a read-only or claim-map writer sidecar is useful
or required, spawn a fresh native `relay` profile with
`multi_agent_v1__spawn_agent` for that task. Each allocation uses
`{target_agent,cwd,task}` without a session
identifier. The relay calls `opencode_worker`, which uses
`opencode-go/deepseek-v4-flash` with `variant=max`. Reader definitions remain
no-edit; the claim-map-scoped OpenCode `worker` may edit only its supplied
isolated worktree, with `cwd` equal to that root and `external_directory:
deny`. The parent verifies the baseline and allowed paths; keep the native
relay as transport-only and keep the parent responsible for tests and
integration.

All configured OpenCode read-only agents may use the OpenCode `task` tool and
`external_directory`; their definitions must keep `edit: deny` and `bash: deny`.
The parent continues useful non-overlap work and joins the relay only at the
decision/final gate. Preserve the MCP response and its provenance instead of
silently translating it into an unverified conclusion. Implementation workers
are OpenCode claim-map workers through the relay; the native `worker` profile is
only an explicit maintenance override.

An explicit maintenance change to `internal_subagent_backend=native` routes
all sub-agents through the native custom-role profiles. If OpenCode is selected
but the relay, MCP, or model is unavailable, leave the required gate blocked; do
not silently fall back to another provider, model, effort, permission,
transport, or a direct main-chat MCP call.

## Observability

Use `obs-gate` before adding or keeping instrumentation. No-edit modes record
only the decision or the evidence gap. Code-changing modes may use temporary or
durable instrumentation only under `obs-contract`, inside the approved scope,
and through the canonical project path. Do not add a collector, hook, exporter,
external endpoint, or dependency without explicit scope.

- `PLAN.AUTO`: use `tn-observe`. Default no-edit planning router. Start with `PLAN`; escalate to `P.DEEP` only with evidence of multi-file/shared/core/unclear ownership/refactor/migration/compat/hidden-deps/high blast. Checkpoint before deep, then final ordered plan with chosen route+why and a `delivery-contract` carrying relevant `quality-obligations`.
- `PLAN`: use `tn-observe`. Simple no-edit plan. Read direct files, map flow/files, optional read-only subA only if it saves time, final ordered plan with files/risks/deps/validation and compact `delivery-contract`; add parallel slices only when `parallel-safe`.
- `P.DEEP`: use `tn-observe`. Deep no-edit plan for refactor/restructure/migration/compat/hidden deps. Use AE, specs/docs, CodeGraph, background read-only subA, evaluate adapt-existing vs `earned-rework`, phase graph, claim-map draft, and final roadmap with critical path, parallel groups, assumptions, unknowns, blockers, and a `delivery-contract`.
- `RESEARCH.DEEP`: use `tn-none`; if the codebase itself is the research subject, delegate to `tn-observe`. Deep no-edit web/GitHub/literature research. Load `research.md`; run `academic=screen`, use globally scoped `institutional` sources only for original research or canonical records, define independent evidence fronts, keep local/repo context on the main path, and use read-only `researcher` agents only where parallel research improves evidence or wall-clock time. Start with a small adaptive fan-out, queue later fronts for material gaps, integrate every required result, enforce `citation-integrity`, triangulate load-bearing claims, and return a cited solution, source ledger, and prioritized roadmap. Do not implement, publish, or claim platform capacity is unlimited.
- `IMPL.AUTO`: use `tn-enforce`. Default implementation router. Start with `IMPL`; escalate to `IMPL.PHASE` only with evidence of multi-phase/refactor/shared-core/parallel-safe roadmap/earned-rework-approved. Checkpoint before phase split; stop if approved plan/scope is missing or drift appears.
- `IMPL`: use `tn-enforce`. Implement approved scope. Use plan-cache/memory-gate, direct reads, optional subA gate, smallest safe diff, `rework-checkpoint`, size-check, verify-tier, and `quality-delta`; final changes/files/validation/risks.
- `IMPL.PHASE`: use `tn-enforce`. Implement approved phased roadmap. Consume phase graph/claim-map draft and `quality-obligations` if present. Execute `earned-rework-approved` only inside approved contracts. Main owns critical path. Use sidecars/workers only when parallel-safe. Execute unit phases, validate each, checkpoint, continue only if clean.
- `DELIVER.AUTO`: use `tn-enforce` and execute only approved `quality-obligations`; broad discoveries trigger `replan-gate`. Consume an approved `delivery-contract` and route to `IMPL` or `IMPL.PHASE`. Allow `preflight-subA` scouts and claim-mapped OpenCode workers when they save wall-clock, then complete the full approved `implementation-wave`: main keeps the critical path moving, workers handle only parallel-safe isolated-worktree slices through the native relay, and each unit gets merge-gate plus targeted `phase-val`; phase validation does not spawn reviewers. Under the internal backend policy, the relay remains transport-only, the parent runs integrated tests, and the native `worker` profile is only an explicit maintenance override. After every approved phase and worker is complete, pass `integrated-freeze` and only then run integrated validation plus the risk-tiered `review-batch` in parallel on one stable snapshot. Every read-only spawn uses its exact custom role and every writer request uses the `worker` target with a claim-map; every relay request omits `fork_context`, `model`, and `reasoning_effort`; never combine `fork_context=true` with `agent_type`. A transient availability error gets one fresh retry of that same valid custom-spawn shape after useful local work, never a fallback to `default`, and an unavailable required reviewer leaves the review gate blocked. Triage once through `finding-gate`; if no actionable finding remains and acceptance passes, go directly to `clean-gate`. Otherwise execute one batched `fix-batch`, merge and revalidate, then run `delta-closure`; do not spawn reviewers per phase, finding, or individual fix, and repeat full reviewer lenses only after a material risk-surface change. Use `early-review-exception` only for an explicit high-impact contract/security/data/migration risk or unresolved validation failure. `clean-gate` completes delivery; `replan-gate` stops/escalates. No commit.
- `REVIEW`: use `tn-verify`. No-edit diff review. Inspect changed flow/tests, use approval-bar and size-check, require read-only risk/regression subA, findings first with severity/evidence/fix/tests/risk.
- `COMMIT`: use `tn-verify`; never start feature or structural refactoring here. Inspect status/index/diff/untracked/remotes, classify every candidate including staged content, and run `gitignore-hygiene`; block on suspected staged secret/generated/cache/local material or broad existing ignores of likely source/docs/config. Build `commit-map` units by independently revertible behavior rather than file or agent. Preserve coherent pre-staged content as an explicit unit; `commit-series=auto` validates and commits ordered units with conventional title, Context, Validation, and `Operator` trailer. Run integrated validation, then `push=current` only when the current remote branch already exists, without force, branch creation, or upstream changes; preserve local commits and report when validation or push blocks.
- `BUG.INV`: use `tn-observe`. No-edit, evidence-first investigation. Define repro/failure signature, use ctx-loop/CodeGraph if useful, prove or reject hypotheses one by one, distinguish observation/inference/unknown, and finish with root-cause evidence plus a minfix plan and causal `quality-obligations`; when an evidence gap remains material, record the `obs-gate` result for the next approved unit without instrumenting here.
- `BUG.FIX`: use `tn-enforce`. Approved fix. Confirm evidence/path/root cause, run `obs-gate` with a no-log default, make the smallest diff, add a regression test if feasible, and report before/after validation, `quality-delta`, and risks.
- `DEBUG`: use `tn-enforce` after the root cause is proven or `obs-gate` proves that bounded temporary capture is the cheapest next evidence. Consume the user's feature/bug plan, define expected functional path, then use `adaptive-route` per unit: PLAN/P.DEEP for orientation when needed, IMPL for contained fixes, IMPL.PHASE for multi-step/parallel-safe repair. Apply `feature-debug-loop`, `bug-chain`, and `functional-gate`; fix one proven blocker at a time, validate the primary fix before optional paydown unless structure is causal, then rerun the functional path until functional or blocked with evidence.
- `REWORK`: use `tn-observe`. No-edit simplification/rework plan. Use code-judo/canonical-home/`earned-rework`, map ownership/dup/state/tests, prove complexity harm, final preserve/remove/simplify/minsafe roadmap.
- `R.A.F.V`: use `tn-enforce`. Repo audit/fix loop until P0-P2 clear. No commit. Strictly prove each item, minfix, validate, rerun scan, report compact. Flag `earned-rework` when bounded rework is safer than legacy patching; execute only if within P0-P2 scope and smallest safe fix, otherwise roadmap it.
- `TN.SKILL`: use `tn-audit`. No-edit thermo-nuclear review. Apply the full TN skill, run `size-scan`, pass `size-fix-gate`, evaluate `earned-rework`, produce coverage/findings/strategic phased plan plus `refactor-sizing-plan`; do not edit or split here.

Default outputs:

- Plans: ordered phases, files+why, risks/deps, validation, relevant `quality-obligations`, observability decision when relevant, and parallelization only where safe.
- Implementations: changes, files, validation, `quality-delta`, observability outcome when relevant, risks, and remaining work.
- Deliveries: changes, acceptance/validation evidence, review/fix cycles, observability outcome when relevant, residual nonblocking suggestions, risks, and remaining work.
- Reviews: findings first, ordered severity, evidence, impact, smallest fix.

## Matriz de Permissões por Papéis

- `Scout` / `Researcher`: Permissão APENAS para Read/Search/Graph-Query. Ferramentas de Write/Edit/Patch estão BLOQUEADAS (Plan Mode Estrito).
- `Worker`: o OpenCode writer recebe apenas `edit` em worktree isolada, sem `bash`/`task`; o GPT principal executa testes e integra. O worker nativo só pode usar `Run-Tests` no override explícito `internal_subagent_backend=native`. Ambos exigem claim-map e diffs cirúrgicos de no máximo 300 linhas ou 4 arquivos por task.
- `Reviewer`: Permissão para Inspect-Diff/Run-Linter/Approval-Signoff (sem edição de arquivos). Rejeita código preguiçoso e violações de Slice-Guard.
