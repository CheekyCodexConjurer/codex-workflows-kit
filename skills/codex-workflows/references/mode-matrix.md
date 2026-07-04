# Mode Matrix

AHK launchers paste `$codex-workflows mode=<MODE> ...`. Route as:

- `PLAN`: simple no-edit plan. Read direct files, map flow/files, optional read-only subA only if it saves time, final ordered plan with files/risks/deps/validation and optional parallel slices.
- `P.DEEP`: deep no-edit plan for refactor/restructure/migration/compat/hidden deps. Use AE, specs/docs, CodeGraph, background read-only subA, phase graph, claim-map draft, and final roadmap with critical path, parallel groups, assumptions, unknowns, blockers.
- `IMPL`: implement approved scope. Use plan-cache/memory-gate, direct reads, optional subA gate, smallest safe diff, size-check, verify-tier, final changes/files/validation/risks.
- `IMPL.PHASE`: implement approved phased roadmap. Consume phase graph/claim-map draft if present. Main owns critical path. Use sidecars/workers only when parallel-safe. Execute unit phases, validate each, checkpoint, continue only if clean.
- `REVIEW`: no-edit diff review. Inspect changed flow/tests, use approval-bar and size-check, require read-only risk/regression subA, findings first with severity/evidence/fix/tests/risk.
- `COMMIT`: inspect status/diff/untracked, clean residue, run relevant validation, commit with clear message, report commit/checks/push status.
- `BUG.INV`: no-edit investigation. Define repro/failure signature, use ctx-loop/CodeGraph if useful, prove or reject hypotheses one by one, final root-cause evidence/minfix plan.
- `BUG.FIX`: approved fix. Confirm evidence/path/root cause, smallest diff, regression test if feasible, final before/after validation and risks.
- `DEBUG`: end-to-end debug with repro/path/root-cause gate. Use required read-only subA when risk/core/unclear, prove RC before fix, verify.
- `REWORK`: no-edit simplification/rework plan. Use code-judo/canonical-home, map ownership/dup/state/tests, prove complexity harm, final preserve/remove/simplify/minsafe roadmap.
- `R.A.F.V`: repo audit/fix loop until P0-P2 clear. No commit. Strictly prove each item, minfix, validate, rerun scan, report compact.
- `TN.SKILL`: no-edit thermo-nuclear review. Apply TN skill, full pass without early return, produce coverage/findings/strategic phased plan/good/uncertainty.

Default outputs:

- Plans: ordered phases, files+why, risks/deps, validation, parallelization only where safe.
- Implementations: changes, files, validation, risks, remaining work.
- Reviews: findings first, ordered severity, evidence, impact, smallest fix.
