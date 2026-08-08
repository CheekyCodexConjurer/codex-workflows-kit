# Validation

## Before a change

- State the failure signature, affected behavior, and smallest meaningful
  check.
- Read the relevant path directly and collect the required delegated
  evidence.
- Record the claim-map, allowed paths, invariants, risks, and validation.

## During delivery

- Run targeted validation first; broaden it only when the contract or blast
  radius demands it.
- Inspect the integrated diff, including unintended paths and generated files.
- Use an independent review of the frozen result when the selected mode
  or risk requires it.

## Repository and installed mirrors

- Run `scripts/validate.ps1` and `git diff --check`.
- After a workflow contract change, run `scripts/install.ps1 -Profile safe`
  before validating the installed mirrors.
- `scripts/doctor.ps1` verifies managed files and their hashes without making
  changes.
- A fresh delegated handoff may be used as a smoke check only when the host
  exposes that capability. Its result proves the assigned evidence task, not
  a file change.
