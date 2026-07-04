# Validation

Check strategy:

- Start with targeted checks tied to changed behavior.
- Broaden to type/build/lint/tests when shared/core/contracts are touched.
- Use deep security/e2e/perf only when blast justifies it.
- For UI, verify console/network/click path/state flow/responsive/a11y when feasible.
- For bug fixes, preserve failure signature and show before/after delta.
- For phased work, validate and checkpoint each independent unit before continuing.
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
