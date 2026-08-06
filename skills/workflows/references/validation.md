# Validation

Check strategy:

- Start with targeted checks tied to changed behavior.
- Broaden to type/build/lint/tests when shared/core/contracts are touched.
- Use deep security/e2e/perf only when blast justifies it.
- For UI, verify console/network/click path/state flow/responsive/a11y when feasible.
- For bug fixes, preserve failure signature and show before/after delta.
- For phased work, validate and checkpoint each independent unit before continuing.
- For the internal backend policy, validate the default
  `internal_subagent_backend=opencode`, the explicit
  `internal_subagent_backend=native` override, the default
  `internal_subagent_transport=native_relay`, the native `relay` profile, the
  configured `opencode_worker` MCP server, pinned
  `github:CheekyCodexConjurer/sub-agents-mcp#v0.13.1`, exposed `run_agent`,
  `start_agent`, `get_agent_status`, `get_agent_result`, and `cancel_agent`,
  plus durable `JOB_DIR`/heartbeat settings,
  absolute `AGENTS_DIR`, `AGENT_TYPE=opencode`, model
  `opencode-go/deepseek-v4-flash`, `AGENT_EFFORT=max`/OpenCode `--variant max`,
  bounded timeout, Windows `PATH` resolution for `opencode.exe`,
  `AGENT_PERMISSION=yolo`, `SESSION_ENABLED=false` without a session directory
  or retention setting, reader definitions' effective `edit: deny`,
  `bash: deny`, `task: allow`, and `external_directory: allow`, and the
  writer definition's effective `edit: allow`, `bash: deny`, `task: deny`, and
  `external_directory: deny`. Run a direct MCP probe from a fresh native relay
  before delegating required work; prove that the relay preserves the response,
  that reader and writer requests select the intended OpenCode target, that
  each request starts a new isolated MCP conversation, and that a writer
  request carries `WRITER_WORKTREE=<cwd>` and `WRITER_BASELINE=<full-commit>`.
  Before and after any real writer probe, verify the main checkout is unchanged
  and compare the returned worktree diff against the declared allowed paths;
  treat any mismatch as a blocked merge. A selected but failed relay/OpenCode route must remain blocked; it
  must not silently fall back to native, reuse a completed relay, or call the
  MCP directly from the main chat. The configured
  `codegraph` MCP may stay enabled when explicitly authorized, but unreviewed
  external tools must not be inferred safe from the permission profile alone.
- For long-running jobs, prove `JOB_OPERATION=start` returns a `job_id` quickly,
  then use fresh `JOB_OPERATION=status|result` requests with
  `JOB_ID=<opaque id>`. A status timeout or `freshness=stale` must remain
  non-terminal evidence, not an automatic failure or relaunch trigger. Do not
  poll continuously: status is reserved for a concrete suspicion of MCP,
  worker, or heartbeat failure. A slow non-terminal job must not be
  accelerated, shortened, summarized, cancelled, or relaunched. Prove that
  result retrieval waits for `result_available=true` or a terminal state, and
  that explicit `JOB_OPERATION=cancel` reaches the durable cancellation state.
- For image-bearing relay requests, prove `RELAY_VISUAL=success` and a
  `[VISUAL_PACKET v1]` reaches the MCP prompt without an image path, data URL,
  or raw image bytes. For text-only requests, prove the task remains intact and
  `RELAY_VISUAL=none`. If attached items produce `RELAY_VISUAL=none` or a
  missing visual status, the parent treats the sidecar as blocked/unknown; a
  failed visual extraction must return blocked rather than a path-only request.
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
- Read-only validation/review agents must use their exact custom role. After a transient availability error, make one fresh same-role retry; never fall back to `default`, and keep a required gate blocked if that retry also fails. For a slot-full spawn failure, apply `subA-slot-full`: close only completed/idle integrated agents or wait for an optional one to finish, retry the same exact role once, never close active/waiting/required agents, and report explicit capacity evidence if recovery is impossible.
- If integrated validation passes and review has no actionable finding, finish without a redundant closure review.
- After a nonempty deduplicated fix batch changes the diff, revalidate once and run a delta-focused closure review; repeat full review only after a material risk-surface change.
- Validação Pré-Voo de Símbolos via AST: Antes da aplicação de um patch pelo worker, verificar se todas as novas chamadas de método, funções ou imports existem e correspondem à definição no banco SQLite (.codegraph/codegraph.db) via CodeGraph.
- Final must include checks run, relevant failures, skipped checks with reason, files touched, and regression risk.

AHK prompt pad:

```powershell
$script = Join-Path $env:USERPROFILE 'Documents\Codex\PromptPad\codex_prompt_pad.ahk'
$exe = (Get-Command AutoHotkey64.exe -ErrorAction Stop).Source
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
python "$env:CODEX_HOME\skills\.system\skill-creator\scripts\quick_validate.py" "$env:AGENTS_HOME\skills\workflows"
```
