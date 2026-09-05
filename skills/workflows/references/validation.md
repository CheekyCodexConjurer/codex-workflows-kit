# Validation

## Before a change

- State the failure signature, affected behavior, and smallest meaningful
  check.
- Aplicar o Gate de Adequação da Correção transversal nos eventos de pre-first-edit e falha, adotando a meta de correção suficiente e sustentável/delimitada em vez de correção mínima, delimitando o blast radius.
- Read the relevant path directly and collect the required delegated
  evidence.
- Record the claim-map, allowed paths, invariants, risks, and validation.

## During delivery

- Run targeted deterministic validation first; broaden it to integrated
  regression as required by the blast radius.
- Inspect the integrated diff, including unintended paths and generated files.
- Executar a checagem pré-revisão do Gate de Adequação da Correção assegurando suficiência e sustentabilidade antes do congelamento.
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
- Blocked reviews use a consolidated repair cycle under the evidence-based repair policy (reparo orientado a evidência; anti-loop ledger recording hypothesis, expected observation, observed delta, next decision; lack of delta requires different diagnostic direction, no duplicate retries or worker swarm duplication; stop only on genuine authority/access/user-decision or no safe actionable path, never a numerical counter; subsequent useful repairs allowed with new hypothesis and delta). Follow-up fixes are new commits — no amend or rewrite.

## Repository and installed mirrors

- Run `scripts/validate.ps1` and `git diff --check`.
- After a workflow contract change, run `scripts/install.ps1 -Profile safe`
  before validating the installed mirrors.
- `scripts/doctor.ps1` verifies managed files and their hashes without making
  changes.
- A fresh delegated handoff may be used as a smoke check only when the host
  exposes that capability. Its result proves the assigned evidence task, not
  a file change.
