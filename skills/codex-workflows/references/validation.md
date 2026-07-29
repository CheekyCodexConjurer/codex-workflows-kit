# Validation

Check strategy:

- Start with targeted checks tied to changed behavior.
- Broaden to type/build/lint/tests when shared/core/contracts are touched.
- Use deep security/e2e/perf only when blast justifies it.
- For UI, verify console/network/click path/state flow/responsive/a11y when feasible.
- For bug fixes, preserve failure signature and show before/after delta.
- For phased work, validate and checkpoint each independent unit before continuing.
- For nontrivial work shown in the Codex checklist with two or more phases, verify `update_plan` transitions at phase boundaries: at the start, the first phase is `in_progress` and future phases are `pending`; before the first command of the next phase, the previous phase is proven and `completed`, exactly one next phase is `in_progress`, and future phases remain `pending`; after the last phase is proven, every phase is `completed` and none is `in_progress`; scope changes update the checklist before work continues, and routine commands do not trigger updates. One-step or simple work does not need a checklist.
- For approved temporary or durable instrumentation, validate the exact question it answers, canonical logger path, field allowlist/redaction, volume cap or sampling, sink-enforced retention and access, disable/removal path, and `failure-behavior`: fail-open by default, with fail-closed only under an explicitly approved audit/compliance contract, so a logging failure does not break the primary flow.
- Do not accept a retention promise written only in source text; identify the real sink, rotation, cleanup, or lifecycle mechanism.
- Under `tn-enforce`, validate the requested behavior and any structural paydown
  as separate units; capture the final `quality-delta`.
- Before splitting a file, establish a baseline check, preserve public
  API/exports/contracts/order, and rerun the affected behavior after the move.
- In `DEBUG`, preserve root-cause-first ordering and rerun the full functional
  path after any bounded paydown.
- In `DELIVER.AUTO`, phase validation is targeted checking only and must not spawn an independent reviewer; finish all approved implementation phases before review.
- At `integrated-freeze`, run integrated validation and risk-tiered reviewers in parallel on the same stable diff.
- Read-only validation/review agents must use their exact custom role. After a transient availability error, make one fresh same-role retry; never fall back to `default`, and keep a required gate blocked if that retry also fails.
- If integrated validation passes and review has no actionable finding, finish without a redundant closure review.
- After a nonempty deduplicated fix batch changes the diff, revalidate once and run a delta-focused closure review; repeat full review only after a material risk-surface change.
- Validação Pré-Voo de Símbolos via AST: Antes da aplicação de um patch pelo worker, verificar se todas as novas chamadas de método, funções ou imports existem e correspondem à definição no banco SQLite (.codegraph/codegraph.db) via CodeGraph.
- Final must include checks run, relevant failures, skipped checks with reason, files touched, and regression risk.

AHK prompt pad:

```powershell
$script = 'C:\Users\mathe\Documents\Codex\2026-07-01\pod\outputs\codex_prompt_pad.ahk'
$exe = 'E:\Programs\AHK\v2\AutoHotkey64.exe'
& $exe /ErrorStdOut /Validate $script
```

Restart AHK:

- Capture old PID for the script.
- Stop only `AutoHotkey64.exe` running that exact script.
- Start with the same exe/script.
- Confirm new PID differs from old PID.

CodeGraph:

- Validate availability with `codegraph --version` or configured MCP exposure.
- Do not update npm/package during normal repo work.
- If `.codegraph` exists, `codegraph sync --quiet` before structural exploration.
- If missing and cg-worthy, run `codegraph init -i` once and leave generated local files uncommitted unless user asks.

Skill validation:

```powershell
python 'C:\Users\mathe\.codex\skills\.system\skill-creator\scripts\quick_validate.py' 'C:\Users\mathe\.agents\skills\codex-workflows'
```
