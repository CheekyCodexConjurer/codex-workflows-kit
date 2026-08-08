# Commit Series

Use this reference for `COMMIT`. Commit a coherent, validated series rather
than collapsing an unrelated worktree into one commit.

## Preflight

- Inspect status, staged diff, unstaged diff, untracked files, merge/rebase
  state, current branch, remotes, and upstream before staging.
- Classify all staged, unstaged, and untracked candidate paths and content.
  Block without changing the index when a candidate looks secret, generated,
  cache, or local.
- Keep simple commits local. When classification has independent material
  fronts, use a delegated scout before changing the index.
- Preserve existing staged content as an explicit first unit. Never unstage or
  repartition it automatically.

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
validation. Run integrated validation after the series. Never reset, amend,
rebase, force-push, or push without explicit authorization.
