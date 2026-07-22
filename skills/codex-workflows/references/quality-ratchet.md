# TN Quality Ratchet

Apply a stable local subset of the thermo-nuclear quality philosophy passively
to code-facing workflows. Do not load the full remote TN skill during ordinary
work; reserve it for explicit `TN.SKILL` audits.

Core rule:

- Leave the touched or directly relevant slice structurally no worse than it
  started.
- Prevent debt introduced or materially worsened by the current change.
- Pay down pre-existing debt only when the improvement is bounded, relevant,
  reversible, and independently validatable.
- Keep repo-wide discovery in `TN.SKILL` or an explicitly approved audit.
- Treat line count as an inspection trigger, never a split instruction; every
  decomposition must pass `size-fix-gate`.

Profiles:

- `tn-observe`: no edits. Inspect the active path and return proven
  `quality-obligations` plus deferred structural work.
- `tn-enforce`: inspect before and after the change, block new structural debt,
  and execute at most one opportunistic bounded paydown unit per primary task
  unit when `tn-paydown-gate` passes.
- `tn-verify`: no feature or refactor edits. Inspect the current diff, block a
  structural regression, and route required corrections back to implementation.
- `tn-audit`: run the full no-edit TN review, `size-scan`, `size-fix-gate`,
  `earned-rework`, and `refactor-sizing-plan`.
- `tn-none`: skip code-quality scanning unless the codebase itself is the
  subject of the task; when it is, delegate to `tn-observe`.

Classify each relevant finding:

1. `new-debt`: introduced or worsened by the current change; mandatory fix
   under `tn-enforce`.
2. `task-coupled-debt`: pre-existing and causal to the bug, feature, or safety
   of the active change; eligible for bounded paydown.
3. `opportunistic-debt`: pre-existing and locally removable without broadening
   ownership or risk; optional by budget.
4. `strategic-debt`: broad, unrelated, contract-changing, or weakly validated;
   use `tn-defer`.

`tn-paydown-gate` requires all of:

- The file is touched, directly owned by the active flow, or on the proven
  root-cause path.
- Complexity, duplication, ownership drift, testability pain, or boundary
  leakage supports the change; size alone does not.
- Read the complete file before splitting it.
- Preserve behavior, public API, exports, schemas, ordering, and external
  contracts.
- Stay inside one ownership boundary without new dependencies or migrations.
- Keep the refactor to one independently reversible unit that does not obscure
  or dominate the primary task.
- Define and pass targeted validation before and after the structural change.

If any requirement fails, use `tn-defer`. If the structural work is necessary
to complete the active task safely, stop at `replan-gate` and route to
`P.DEEP` or `IMPL.PHASE` rather than improvising.

Sequencing:

- Planning, investigation, review, and rework modes observe or verify only.
- In bug/debug work, prove the root cause first. Refactor as part of the fix
  only when structure is causal; otherwise validate the primary fix before a
  bounded paydown, then rerun the functional path.
- In implementation, validate any preparatory refactor separately from the
  requested behavior.
- In delivery, execute only approved `quality-obligations`; newly discovered
  broad work triggers `replan-gate`.
- Finish code-changing work with `quality-delta`
  `{prevented,new-debt-fixed,paydown,deferred,reason}`.
