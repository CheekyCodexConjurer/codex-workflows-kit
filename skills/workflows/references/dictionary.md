# Dictionary

Syntax: `⇢` left-to-right, `{}` scope/output, `[]` roles/options, `Q` queue, `Σ` scan/map, `∀` each, `→` then, `?` optional by budget/risk.

Core:

- `router`: choose mode by task+risk+blast; simple cannot escalate without checkpoint.
- `proportional-cadence`: universal pacing rule `{risk,blast,uncertainty,reversibility}`: start with the smallest route that can answer the current question or prove the requested behavior; expand scope or depth only when existing evidence or material risk reveals uncertainty, or a required gate is still open; parallelize already-approved independent work only when it saves wall-clock time; before repeating a step that produced no new evidence, use `checkpoint{evidence,gap,cheapest-next}` and, when one exists, take one materially different cheapest action; if no such action exists or it fails to produce progress or close a required gate, report blocked or use the mode's replan path; finish at the current mode's own done/clean gate (`functional-gate→clean-gate` for code delivery); defer unrelated work with `tn-defer`; never cancel active subA solely for slowness, and keep a required subA wait as an explicit gate rather than repeating main work.
- `PLAN.AUTO`: no-edit planning router; start simple and route to PLAN or P.DEEP by evidence; checkpoint before deep; final reports chosen route+why.
- `IMPL.AUTO`: implementation router; start contained and route to IMPL or IMPL.PHASE by evidence; checkpoint before phase split; stop if plan approval/scope is missing.
- `DELIVER.AUTO`: verified delivery router; consume approved `delivery-contract`, route to IMPL or IMPL.PHASE, complete `implementation-wave`, freeze at `integrated-freeze`, then run `review-batch→fix-batch→delta-closure`; never commit. Escalate through `replan-gate` on scope/contract drift, unapproved rework, blocked validation, or no proven progress.
- `internal_subagent_backend=opencode`: private default provider policy. With it, the main chat uses the native `relay` profile to call `opencode_worker` for configured read-only OpenCode agents, while workers remain native. `internal_subagent_backend=native` is an explicit maintenance override; unavailable relay/OpenCode means blocked, never silent fallback. The legacy `sub-agent=opencode` token is not user-facing.
- `internal_subagent_transport=native_relay`: private transport policy. Spawn a fresh native `relay` with `multi_agent_v1__spawn_agent` for each sidecar task, carry `{target_agent,cwd,task}`, and join the original MCP response at the decision/final gate. Do not persist or reuse a relay conversation. It is not a user-facing prompt flag.
- `commit-map`: inspect staged, unstaged, and eligible untracked changes before staging; produce ordered units `{purpose,files/hunks,deps,title,context,val,operator}`.
- `commit-unit`: independently understandable and revertible behavior; keep directly coupled implementation, tests, docs, config, and `.gitignore` rules together; split hunks only when independent.
- `commit-series`: execute ordered proven units; `commit-series=auto` commits each unit without a confirmation pause, but stops on incoherent stage, failed validation, or unresolved dependency.
- `operator`: commit trailer naming the proven implementer; use `user` or `worker:<name>` only with explicit provenance, otherwise `Codex`.
- `commit-gate`: require clean staged patch plus unit-targeted validation before each commit and integrated validation before push; preserve local commits on failure.
- `push=current`: push the current branch without force, branch creation, or upstream changes; use upstream, then `origin`, then a sole remote, and require the matching remote branch to exist; otherwise report blocked and keep commits local.
- `RESEARCH.DEEP`: no-edit evidence-led web/GitHub/literature research; load `research.md`, use adaptive fan-out where it improves evidence, and return a cited solution plus roadmap.
- `academic=screen`: mandatory academic relevance screen; search for material scholarly evidence, or report why it cannot change the decision.
- `literature`: scholarly evidence surface: peer-reviewed studies, reviews, preprints, publishers, and discipline-specific indexes.
- `institutional`: university or research-institute source surface, globally scoped; only original research, reports, or canonical repository records can support a claim.
- `citations{inline|ledger}`: cite each load-bearing external claim inline and finish with an auditable source list.
- `research-map`: turn the topic into the decision, criteria, scoped unknowns, and independent evidence fronts.
- `research-fanout`: main keeps synthesis moving while `researcher` agents investigate non-overlapping fronts; queue further work only for material gaps.
- `source-grade`: assess relevance, directness, methodology, and review status; label every preprint, prefer a publication version of record over its equivalent preprint, then select reviews or primary studies by fit to the claim.
- `source-ledger`: `{id, role, canonical-link, type, review-status, version, access, claim-ids, limitation}` for each material source; only `evidence` sources support conclusions.
- `citation-integrity`: every material external claim has an exact supporting inline citation; distinguish evidence from discovery-only pages and use persistent links where available.
- `source-triangulation`: corroborate load-bearing claims with independent sources, or state the single-source limitation.
- `fact-inference`: distinguish reported facts from the recommendation inferred from them.
- `research-stop`: stop when the decision criteria are met, major claims are supported, and the next search has lower value than synthesis.
- `research-output`: decision, evidence, options, recommendation, roadmap, validation experiments, risks, and open gaps.
- `budget`: depth by risk/blast; enforce turn/read/tool limits; skip ceremony.
- `turn-budget`: checkpoint before broadening/looping; never a timer for active subA.
- `read-budget`: prefer rg/cg/query/snippets; full files only for direct edit/refactor/insufficient snippets.
- `context-prune`: keep objective, decisions, evidence, files, commands/results, risks; drop tool noise.
- `criteria`: goal+expected behavior+done condition+validation before action.
- `plan-sync`: for nontrivial work with 2+ phases, create 2-5 short observable steps in `update_plan`; start the first as `in_progress` and the rest as `pending`; before the first command of the next phase, verify the current phase, mark it `completed`, mark only the next phase `in_progress`, and leave future phases `pending`; after proving the last phase, mark every step `completed` and leave none `in_progress`; update the checklist before continuing when scope changes; the main agent owns the checklist and reconciles it with the final scope; skip it for one-step work and never update it after every command.
- `obs-gate`: before proposing or keeping instrumentation, define the unanswered diagnostic question and follow-on action, inspect existing logs/traces/metrics/tests/repro, then choose `{none|temporary|durable}`; default to `none`.
- `obs-contract`: mandatory for `temporary` or `durable` instrumentation: `{question,event,correlation,allowed-fields,redaction,level,cap/sampling,sink+TTL,access,off/removal,failure-behavior,validation}`.
- `obs-lifecycle`: temporary instrumentation is disabled by default and bounded; durable events use the canonical project logger; retention/rotation and access are enforced by the sink or lifecycle, never only by a comment; logging is `fail-open` by default, and `fail-closed` needs an explicitly approved audit/compliance contract.
- `obs-no-external`: do not add a collector, hook, exporter, external endpoint, or dependency without explicit scope.
- `obs-output`: plans and reviews report the decision or evidence gap; code delivery reports retrieval, disable/removal, retention, and validation.
- `read-direct`: read directly related files first.
- `ctx-loop`: `cg?→rg/query→targeted read→ctx-score→refine→stop-rule`.
- `ctx-score`: score context for relevance; discard low-score immediately.
- `stop-rule`: stop exploration once owner+callpath+expected/actual+validation are enough.
- `plan-cache`: reuse known plan shapes only through `memory-gate`.
- `memory-gate`: reuse prior plan only when similarity/evidence match; no unfiltered history.
- `checkpoint`: before expanding: evidence, gap, cheapest next action.
- `roadmap`: phased plan by deps, risk reduction, reversible value.
- `phase-graph`: critical-path, sidecars, serial-core, parallel-groups, deps, merge-gates, stop-points.
- `parallel-plan`: design worker slices only when speed gain exceeds coordination cost.
- `claim-map-draft`: proposed owners/files/contracts/no-touch/validation for later execution.
- `delivery-contract`: plan-to-delivery handoff `{scope,invariants,acceptance,val,risk-tier,serial-core,parallel-slices?,claim-map?,quality-obligations?,observability?,review-lenses,replan-triggers}`; keep contained plans compact.
- `subA-role-lock`: every read-only spawn selects the exact custom role `scout`, `reviewer`, or `researcher`; never use `default` or omit the role, because that inherits the parent model/effort.
- `subA-custom-spawn`: spawn a custom role with explicit `agent_type` and omit `fork_context`, `model`, and `reasoning_effort`; never combine `fork_context=true` with `agent_type`. A full-history fork intentionally inherits the parent and is not a custom-role spawn.
- `subA-effort`: use the unsuffixed analytical role for the installation default,
  GPT-5.4 Mini with `xhigh`; the native transport `relay` is pinned to `high`
  so MCP activation stays reliable. Select `<role>-{low|high|max}` only for an
  explicit effort override.
- `subA-same-role-retry`: after a transient launch/stream/account-availability error, continue useful local work and make one fresh retry with the same explicit role and the same valid custom-spawn shape: omit `fork_context`, `model`, and `reasoning_effort`; never retry in a tight loop or fall back to `default`. If the retry fails, skip only optional scouting with evidence; any required read-only gate stays blocked.
- `subA-isolation`: each sidecar request uses a fresh relay and MCP conversation; do not persist a session identifier or send follow-ups through a completed relay.
- `preflight-subA`: read-only scouts and claim-mapped implementation workers may start before/during implementation when `subA-speed`; independent reviewers remain gated by `integrated-freeze`.
- `implementation-wave`: complete all approved IMPL/IMPL.PHASE units before independent review; keep main on critical path, run parallel-safe workers, merge-gates, and targeted `phase-val`; phase validation is checks, not review, and must not spawn a reviewer.
- `integrated-freeze`: after all approved phases and workers complete, main integrates and inspects their diffs, passes merge-gate plus targeted validation, and freezes one stable affected diff; only then open the reviewer spawn gate.
- `review-batch`: run integrated `val` and risk-tiered read-only reviewer lenses in parallel on the same frozen snapshot, then deduplicate proven actionable findings through `finding-gate` into one `fix-Q`; if the queue is empty and acceptance passes, go directly to `clean-gate`.
- `fix-batch`: only when `fix-Q` is nonempty, resolve the deduplicated queue in one correction wave; main owns serial/shared concerns, claim-mapped workers handle only independent clusters, no reviewer is spawned per finding or fix, then merge and revalidate once.
- `delta-closure`: only after a nonempty fix batch changes the diff and passes validation, use one fresh read-only reviewer on the correction delta and stable affected flow; repeat full reviewer lenses only if fixes materially changed contracts, architecture, security, auth, data, concurrency, or broad behavior.
- `early-review-exception`: before `integrated-freeze`, allow only a targeted read-only checkpoint for explicit contract/API/schema/auth/security/data/migration/irreversibility risk or an unresolved validation failure; it is not a general review and cannot start a review-fix cycle.
- `review-fix-loop`: compatibility alias for `implementation-wave→integrated-freeze→review-batch→fix-batch→delta-closure`; never review after each phase or individual fix.
- `finding-gate`: actionable findings require evidence, impact, affected path, smallest safe fix, and validation; speculative or aesthetic suggestions never reopen delivery.
- `clean-gate`: finish only when acceptance and functional gates pass, required validation passes, and no actionable in-scope `regdiff`, risk, or approval-bar finding remains.
- `replan-gate`: stop delivery and return to planning/approval if a fix changes approved scope, contract/API/schema/behavior, needs unapproved rework, or the cycle stops making proven progress.
- `earned-rework`: do not preserve inferior structure by default; compare adapt-existing vs rework; choose bounded rework when evidence shows lower net complexity/risk or better clarity/testability/evolution; preserve behavior/contracts; phase+validate+reversible; no aesthetic rewrite.
- `earned-rework-approved`: execute only if roadmap/claim-map approves rework; keep phases bounded/reversible; preserve contracts; validate each phase; stop on drift.
- `rework-checkpoint`: if a simple implementation starts requiring broad/unclear rework or legacy malabarism, stop and recommend P.DEEP/IMPL.PHASE rather than improvising.
- `adaptive-route`: choose per unit: PLAN for simple no-edit orientation, P.DEEP for unclear/refactor/multi-file architecture, IMPL for known contained fix, IMPL.PHASE for approved multi-phase/parallel-safe roadmap.
- `feature-debug-loop`: consume user feature/bug plan; define functional path+done; reproduce current break; fix one proven bug at a time; rerun path; discover next blocker; repeat until functional or blocked.
- `functional-gate`: do not final-success until target user path/check passes end-to-end; if infeasible, report exact blocker, evidence, remaining failing path, and next cheapest action.
- `bug-chain`: after each fix, rerun validation/repro before continuing; new failures become next queue item, not a reason for early final.

Quality:

- `minsafe`: smallest safe change preserving local patterns.
- `minfix`: smallest safe fix; delete/simplify before abstraction.
- `prove`: evidence with files/functions/diff/repro.
- `val`: targeted checks first; broaden if shared/core.
- `verify-tier`: targeted -> build/type/lint/tests -> security/e2e/perf by blast.
- `eval-first`: define failure signature/check before change; rerun and compare delta.
- `phase-val`: validate each independent unit before next phase.
- `risk-review`: invariants, edge cases, errors, auth/security, coupling, rollout/migration.
- `regdiff`: compare behavior, tests, diff, regression surface.
- `no-broad`: no unrelated cleanup/refactor/abstraction/layer/deps.
- `no-residue`: no dead/dup/unmanaged debug or temporary logs/vague TODO/loose accidental changes; approved `obs-contract` instrumentation is not residue.
- `code-judo`: behavior-preserving reframe that deletes concepts/branches/layers.
- `canonical-home`: use existing owner/helper/module/layer; flag duplicate helpers/leaks.
- `atomic-flow`: flag needless sequential orchestration or partial updates.
- `approval-bar`: structural regressions, spaghetti, wrappers/casts/optionality churn, bloat, leaks, duplicate helpers, missed simplification are blockers.
- `tn-ratchet`: leave the touched/relevant slice no worse; prevent new debt, allow only gated bounded paydown, and defer broad or unrelated structural work.
- `tn-observe`: no-edit quality pass over the active path; return proven `quality-obligations` and deferred work.
- `tn-enforce`: block debt introduced/worsened by the change; execute at most one opportunistic bounded paydown unit per primary task unit only through `tn-paydown-gate`.
- `tn-verify`: no feature/refactor edits; inspect the diff and route structural regressions back to implementation.
- `tn-audit`: full no-edit TN review with size-scan, earned-rework, and strategic sizing plan.
- `tn-none`: skip code-quality scanning unless the codebase itself is the task subject; then delegate to `tn-observe`.
- `tn-paydown-gate`: require touched/causal scope, structural evidence beyond size, full-file read, preserved behavior/contracts, one ownership boundary, one reversible unit, and before/after validation.
- `tn-defer`: record broad/unrelated/contract-changing or weakly validated structural work; use replan-gate when it blocks safe completion.
- `quality-delta`: final `{prevented,new-debt-fixed,paydown,deferred,reason}` for code-changing work.
- `size-check`: inspect touched/relevant files for dup, over-abstraction, redundant branches, unused code, bloat.
- `size-thresh`: smells: Java300 Go400 Vue/TSX/JSX200 TS/JS/Py300; exclude config/lock/build/vendor; MD duplicate headings.
- `size-scan`: repo/file scan using `size-thresh`; exclude node_modules/vendor/dist/build/.git/cache/venv/config/lock/minified; include MD duplicate-heading and CSS inline/global checks.
- `size-fix-gate`: do not split just for line count; propose fix only when size correlates with complexity, dup, ownership drift, testability pain, CSS leak, or active refactor scope.
- `refactor-sizing-plan`: for size-gated findings, propose behavior-preserving split phases; preserve API/exports/contracts; read full file before split; prioritize worst offenders by risk/value, not file chores.
- `split-safe`: before split/refactor read full file, preserve API/exports, fields/columns/branches/count/order/names.
- `css-check`: Vue/TSX/JSX style >30 lines or non-scoped Vue style => suggest/extract only if shared/global.

Tools:

- `safe-op`: no destructive/prod/db/reset/force-push/secret/publish ops without explicit confirmation.
- `spec-check`: if specs/contracts/PRD/ADR/API docs exist, verify alignment/drift.
- `doc-live`: for modern libs/frameworks/APIs, fetch current versioned docs before coding.
- `skill-probe`: inspect 0-2 relevant skills/docs only when warranted.
- `ui-trace`: handler -> state/store -> effects -> async/race -> stale closure -> render.
- `ui-proof`: verify console+network+click path+state flow+responsive/a11y when feasible.
- `regression-memory`: test what broke; repeated bug/fix becomes test or rule.
- `rule-distill`: extract reusable rule only for repeated pattern.
- `compliance-check`: audit whether active prompt/dictionary were followed.
- `gitignore-hygiene`: before commit/stage, classify staged, unstaged, and untracked candidates; block without index changes when staged content looks secret/generated/cache/local; add generated/cache/local/secret/build artifacts to the nearest correct `.gitignore`; never ignore likely source/docs/config without evidence; block and report existing broad ignore rules that hide likely source/docs/config rather than rewriting user rules; include every remaining eligible nonignored file in its nearest `commit-unit` or a factual independent unit; stage `.gitignore` with intended tracked files; report ignored vs tracked.

CodeGraph:

- `cg`: if cg-worthy, use CodeGraph MCP when exposed else CLI; `cg-init→cg-sync→cg-map`; fallback if unavailable/stale/no hits.
- `cg?`: optional only when cg-worthy.
- `cg-worthy`: medium/large repo, multi-file/shared/core/unclear task, or search would fan out.
- `cg-init`: if `codegraph` exists and `.codegraph` missing and cg-worthy, run `codegraph init -i` once; keep local/uncommitted.
- `cg-sync`: if `.codegraph` exists, run `codegraph sync --quiet` before structural exploration.
- `cg-map`: use MCP `codegraph_*` or CLI files/query/context with tight limits; avoid broad dumps.
- `cg-tests`: use MCP impact/affected or CLI `codegraph affected` on changed files.
- `cg-fallback`: fallback to rg/read/direct inspection.
- `cg-proc`: do not manage CodeGraph MCP processes normally; only clean stale duplicate `serve --mcp` while debugging/upgrading.
- `cg-upkeep`: scheduled task owns package updates/stale cleanup; do not npm-update during repo work.

Composites:

- `AE`: criteria first + eval-first + risk-scoped units + phase-val + regdiff + risk-review.
- `TN`: read/apply thermo-nuclear code quality review skill from `https://github.com/cursor/plugins/blob/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review/SKILL.md`.
