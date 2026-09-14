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
- Prova operacional em tempo de execução: obrigatória sob gatilhos de risco (processos ativos, persistência, roteamento, serviços e telas/rotas de UI/web como AERA). Em entregas visuais/frontend, a prova inclui teste automatizado em navegador local pelo worker com captura de screenshot nos artefatos e verificação de integridade do console, poupando tokens do parent.
- An independent review must yield an `APPROVED` verdict with zero blockers
  (`zero blockers`) against the matching frozen target before committing.
- Commit gate: verify exact `target_id` before staging; after staging and immediately before commit, recompute the staging-invariant identity (`target_id`) and require equality, verify the staged path set is exactly the approved owned set, and verify every staged blob equals the Git-normalized approved content; independent approval allows idle open writers with consumed jobs, while commit/final requires closure of all obligations and agents (`commit/final requires closure`).
- Blocked reviews use a consolidated repair cycle under the evidence-based repair policy (reparo orientado a evidência; anti-loop ledger recording hypothesis, expected observation, observed delta, next decision; lack of delta requires different diagnostic direction, no duplicate retries or worker swarm duplication; stop only on genuine authority/access/user-decision or no safe actionable path, never a numerical counter; subsequent useful repairs allowed with new hypothesis and delta). Follow-up fixes are new commits — no amend or rewrite.

## Repository and installed mirrors

- Run `scripts/validate.ps1` and `git diff --check`.
- After a workflow contract change, run `scripts/install.ps1 -Profile safe`
  before validating the installed mirrors.
- `scripts/doctor.ps1` verifies managed files and their hashes without making
  changes.
- Safe PowerShell routing: automated non-trivial scripts must run through `scripts/invoke-safe-powershell.ps1` (resolved from repo root `scripts/invoke-safe-powershell.ps1` in repository context, or from the skill mirror's own `scripts/invoke-safe-powershell.ps1` in installed workflows mirrors) using `-File`, `-NoProfile`, and `-NonInteractive`. Never use string-interpolated `-Command` or `Invoke-Expression`. In no-write modes and ALINHAMENTO, creating temporary or new scripts is forbidden; existing non-mutating commands (somente leitura) remain direct with non-interactive flags. Native command failures require an explicit exit code check (`$LASTEXITCODE`). Real-time stdout/stderr streaming must remain visible. If the safe helper is unavailable, fail closed without falling back to unsafe command strings or package installations (`safehelper unavailable failclosed for unsafe route not packageinstall`). The helper does not intercept arbitrary third-party tools outside its explicit execution path.
- A fresh delegated handoff may be used as a smoke check only when the host
  exposes that capability. Its result proves the assigned evidence task, not
  a file change.
