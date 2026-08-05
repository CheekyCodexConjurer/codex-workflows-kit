# Commit Series

Use this reference for `COMMIT`. Commit a coherent, validated series rather than collapsing an unrelated worktree into one commit.

## Preflight

- Inspect status, staged diff, unstaged diff, untracked files, merge/rebase state, current branch, remotes, and upstream before staging.
- Classify all staged, unstaged, and untracked candidate paths and content. Block without changing the index when a staged candidate looks secret, generated, cache, or local.
- Run `gitignore-hygiene` first. Ignore generated, cache, local, or secret material; do not commit secrets. Include every remaining nonignored new file in the commit map.
- When a candidate is confidently local, generated, cache, or secret and has no narrow matching rule, add the smallest evidence-based rule to the nearest `.gitignore` and include that `.gitignore` change in its `commit-unit`; if classification or scope is ambiguous, block and report.
- Simple commits stay local. When candidate classification is non-trivial with independent candidate fronts, use the `quality-first-subA` read-only scout fan-out; Git/index/commit/push remain parent-owned.
- When an existing ignore rule hides likely source, documentation, or configuration without explicit evidence, block the automatic series and report the rule. Do not rewrite user-authored ignore rules automatically.
- Block before changing the index when a merge, rebase, cherry-pick, detached HEAD, or incoherent pre-staged unit prevents a safe series.

## Commit Map

- Build an ordered `commit-map` before the first commit. Each unit has `{purpose, files/hunks, dependencies, title, context, validation, operator}`.
- A `commit-unit` is one independently understandable and revertible behavior. Keep implementation, tests, docs, configuration, and `.gitignore` rules that directly support that behavior together.
- Split same-file hunks only when they are independent. Do not split a unit when its validation or contract depends on a later unit.
- Order foundation before consumers. Do not create a commit only to satisfy a file-count or agent-count target.
- Preserve existing staged content as an explicit first unit. Never unstage or repartition it automatically. If it is not coherent, stop and report the required map.
- Place untracked source/docs/config in their nearest unit. When no relationship is provable, create a factual independent unit rather than leaving an eligible file behind.

## Message And Operator

Use this format for every commit:

```text
type(scope): imperative summary

Context: factual behavior and reason.
Validation: checks run and result.
Operator: Codex
```

- Allowed types: `feat`, `fix`, `refactor`, `docs`, `test`, `build`, `chore`.
- Use the dominant owner/capability as `scope`; omit it only when no scope is clear.
- Set `Operator: user` or `Operator: worker:<name>` only with explicit provenance. Otherwise use `Operator: Codex`.
- Keep the existing Git author/committer identity. Do not add `Co-authored-by` unless explicitly requested.

## Execution And Validation

- With `commit-series=auto`, stage and commit each proven unit without a confirmation pause.
- Before each commit, verify the staged patch is clean and run validation tied to that unit. If a unit cannot be validated without a later unit, merge them.
- After the series, run integrated validation. Do not push when any unit validation or final validation fails.
- On failure, preserve existing local commits and worktree changes. Never reset, amend, rebase, or force-push to recover.
- Before push, ensure every eligible mapped change was committed; ignored artifacts may remain.

## Coverage Gate

- Run `commit-coverage-gate` before each commit and before push: refresh `git status --porcelain=v1 --untracked-files=all` and block any nonignored candidate outside the `commit-map`.
- Excluded generated/cache/local/secret paths require `git check-ignore -v` evidence; preserve tracked files and negation exceptions. No candidate may disappear only through an unverified verbal classification.

## Push

- `push=current` pushes the current branch, including `main` or `master`. Do not create or switch branches.
- Use the current upstream when configured. Otherwise use `origin`; if absent, use the only configured remote. With no unambiguous remote, report push blocked and keep commits local.
- Verify that `refs/heads/<current-branch>` already exists on the selected remote before any push. If it is absent or cannot be checked, report push blocked and keep commits local.
- Push only `HEAD:refs/heads/<current-branch>` to that existing remote ref. Do not set upstream automatically.
- Never use `--force`, publish tags, or change remote configuration. A rejected or failed push leaves the local series intact.

## Final Report

Report the commit map, hashes, titles, operators, validation for each unit, final validation, push outcome, ignored files, and any local-only commits.
