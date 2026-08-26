# Validation

## Before a change

- State the failure signature, affected behavior, and smallest meaningful
  check.
- Read the relevant path directly and collect the required delegated
  evidence.
- Record the claim-map, allowed paths, invariants, risks, and validation.

## During delivery

- Run targeted deterministic validation first; broaden it to integrated
  regression as required by the blast radius.
- Inspect the integrated diff, including unintended paths and generated files.
- Freeze the target with staging- and host-code-page-invariant deterministic identity (`target_id`: baseline, owned HEAD-relative content status, integrated diff against HEAD with Git stdout normalized as UTF-8, per-file SHA256 hashes, excluding index placement; raw porcelain captured as evidence outside digest; validation evidence) and execute an independent review covering the 5 explicit pillars
  (`references/delivery-review.md`).

## Delivery commit gate

Write modes (`IMPL.AUTO`, `IMPL`, `IMPL.PHASE`, `DELIVER.AUTO`, `BUG.FIX`,
`DEBUG`) and manual `R.A.F.V` end with a validated, reviewed, scoped local
commit series and never push. `R.A.F.V` remains a separate explicitly
requested mode, never run automatically.

- Record the baseline and claim-map/path ownership before work; block on
  pre-existing, staged, or other-front changes and on generated/cache/local/ignored
  candidates.
- Run `git diff --check` plus targeted and integrated deterministic validation.
- An independent review must yield an `APPROVED` verdict with zero blockers
  (`zero blockers`) against the matching frozen target before committing.
- Commit gate: verify exact `target_id` before staging; after staging and immediately before commit, recompute the staging-invariant identity (`target_id`) and require equality, verify the staged path set is exactly the approved owned set, and verify every staged blob equals the Git-normalized approved content.
- Blocked reviews use a consolidated repair cycle (maximum 2 rounds, then fail
  closed). Follow-up fixes are new commits — no amend or rewrite.

## Repository and installed mirrors

- Run `scripts/validate.ps1` and `git diff --check`.
- After a workflow contract change, run `scripts/install.ps1 -Profile safe`
  before validating the installed mirrors.
- `scripts/doctor.ps1` verifies managed files and their hashes without making
  changes.
- A fresh delegated handoff may be used as a smoke check only when the host
  exposes that capability. Its result proves the assigned evidence task, not
  a file change.
