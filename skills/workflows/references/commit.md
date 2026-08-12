# Commit Series

Use this reference for the delivery-commit gate of write modes and for
`COMMIT`. Commit a coherent, validated series rather than collapsing an
unrelated worktree into one commit.

## Delivery commit gate

Write modes (`IMPL.AUTO`, `IMPL`, `IMPL.PHASE`, `DELIVER.AUTO`, `BUG.FIX`,
`DEBUG`, `R.A.F.V`) close with a validated, reviewed, scoped local commit
series; never push.

- Record the baseline (status, staged and unstaged diffs, untracked files,
  merge/rebase state, branch, remotes, upstream) and the claim-map/path
  ownership before work.
- The series contains only owned changes: never pre-existing, staged, or
  other-front changes. Block without changing the index on ambiguous
  overlap, secrets, or generated/cache/local/ignored candidates.
- Build a coherent commit-map with separate, reversible commits; run
  targeted and integrated validation plus `git diff --check` before
  committing.
- Independent review before commit; follow-up fixes are new commits — no
  amend, reset, rebase, or rewrite; never push.
- `COMMIT` covers pre-existing or exceptional dirty worktrees and remains
  git-only; `REWORK` stays no-write.

## Preflight (`COMMIT`)

These checks and the staged-content preservation rule apply only to
`COMMIT` (pre-existing or exceptional dirty worktrees); the delivery-commit
gate above is the only path that commits owned delivery work, and it never
includes pre-existing or staged changes.

- Inspect status, staged diff, unstaged diff, untracked files, merge/rebase
  state, current branch, remotes, and upstream before staging.
- Classify all staged, unstaged, and untracked candidate paths and content.
  Block without changing the index when a candidate looks secret, generated,
  cache, or local.
- Keep simple commits local. When classification has independent material
  fronts, use a delegated read front before changing the index.
- Preserve existing staged content as an explicit first unit in `COMMIT`;
  never unstage or repartition it automatically. Write-mode delivery never
  carries pre-existing staged content into its commit series.

## Commit map

Build an ordered `commit-map` before the first commit. Each unit has
`{purpose, files/hunks, dependencies, title, context, validation, operator}`.
Keep directly coupled implementation, tests, documentation, configuration, and
ignore rules together. Split hunks only when they are independently
understandable and reversible.

## Message and validation

```text
type(scope): imperative summary

Context: factual behavior and reason.
Validation: checks run and result.
Operator: Codex
```

Before each commit, verify the staged patch is clean and run unit-targeted
validation. Run integrated validation after the series. Follow-up fixes are
new commits; never amend, reset, rebase, force-push, or push without explicit
authorization.
