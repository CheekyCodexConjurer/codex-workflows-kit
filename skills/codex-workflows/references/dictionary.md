# Dictionary

Syntax: `⇢` left-to-right, `{}` scope/output, `[]` roles/options, `Q` queue, `Σ` scan/map, `∀` each, `→` then, `?` optional by budget/risk.

Core:

- `router`: choose mode by task+risk+blast; simple cannot escalate without checkpoint.
- `budget`: depth by risk/blast; enforce turn/read/tool limits; skip ceremony.
- `turn-budget`: checkpoint before broadening/looping; never a timer for active subA.
- `read-budget`: prefer rg/cg/query/snippets; full files only for direct edit/refactor/insufficient snippets.
- `context-prune`: keep objective, decisions, evidence, files, commands/results, risks; drop tool noise.
- `criteria`: goal+expected behavior+done condition+validation before action.
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
- `no-residue`: no dead/dup/debug/temp/logs/vague TODO/loose accidental changes.
- `code-judo`: behavior-preserving reframe that deletes concepts/branches/layers.
- `canonical-home`: use existing owner/helper/module/layer; flag duplicate helpers/leaks.
- `atomic-flow`: flag needless sequential orchestration or partial updates.
- `approval-bar`: structural regressions, spaghetti, wrappers/casts/optionality churn, bloat, leaks, duplicate helpers, missed simplification are blockers.
- `size-check`: inspect touched/relevant files for dup, over-abstraction, redundant branches, unused code, bloat.
- `size-thresh`: smells: Java300 Go400 Vue/TSX/JSX200 TS/JS/Py300; exclude config/lock/build/vendor; MD duplicate headings.
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
