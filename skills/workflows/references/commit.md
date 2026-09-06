# Commit Series

Use this reference for the delivery-commit gate of write modes and for
`COMMIT`. Commit a coherent, validated series rather than collapsing an
unrelated worktree into one commit.

## Delivery commit gate

Write modes (`IMPL.AUTO`, `IMPL`, `IMPL.PHASE`, `DELIVER.AUTO`, `BUG.FIX`,
`DEBUG`) and manual `R.A.F.V` close with a validated, reviewed, scoped local
commit series; never push. `R.A.F.V` is an explicitly requested separate
mode, never run automatically.

- Record the baseline (status, staged and unstaged diffs, untracked files,
  merge/rebase state, branch, remotes, upstream) and the claim-map/path
  ownership before work.
- The series contains only owned changes: never pre-existing, staged, or
  other-front changes. Block without changing the index on ambiguous
  overlap, secrets, or generated/cache/local/ignored candidates.
- Register the formal frozen target with staging- and host-code-page-invariant deterministic identity (`target_id`: baseline, owned HEAD-relative content status, integrated diff against HEAD with Git stdout normalized as UTF-8, and per-file SHA256 hashes; raw porcelain/index placement excluded from digest; validation evidence).
- An independent review (`references/delivery-review.md`) must yield an
  `APPROVED` verdict with zero blockers (`zero blockers`) on the matching
  frozen target before the first commit.
- Commit gate: verify exact `target_id` before staging; after staging and immediately before commit, recompute the staging-invariant identity (`target_id`) and require equality, verify the staged path set is exactly the approved owned set, and verify every staged blob equals the Git-normalized approved content; independent approval allows idle open writers with consumed jobs, while commit/final requires closure of all obligations and agents (`commit/final requires closure`).
- Blocked reviews use a consolidated repair cycle under the evidence-based repair policy (reparo orientado a evidência; anti-loop ledger recording hypothesis, expected observation, observed delta, next decision; lack of delta requires different diagnostic direction, no duplicate retries or worker swarm duplication; stop only on genuine authority/access/user-decision or no safe actionable path, never a numerical counter; subsequent useful repairs allowed with new hypothesis and delta). Follow-up fixes are new commits — no amend, reset, rebase, or rewrite; never push.
- `COMMIT` covers pre-existing or exceptional dirty worktrees and remains
  git-only; `REWORK` stays no-write.

## Preflight (`COMMIT`)

These checks and the staged-content preservation rule apply only to
`COMMIT` (pre-existing or exceptional dirty worktrees); the delivery-commit
gate above is the only path that commits owned delivery work, and it never
includes pre-existing or staged changes. `COMMIT` remains strictly git-only:
it never alters `.gitignore` and never updates MCP indexes.

- Inspect status, staged diff, unstaged diff, untracked files, merge/rebase
  state, current branch, remotes, and upstream before staging.
- Classify all staged, unstaged, and untracked candidate paths and content.
  Block without changing the index when a candidate looks secret, generated,
  cache, or local, reporting the candidate path, category, and suggested rule.
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
