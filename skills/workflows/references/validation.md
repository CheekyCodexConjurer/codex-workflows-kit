# Validation

Start with checks tied to the changed behavior. Broaden for shared contracts,
then stop when the acceptance gate is proven. Never report a timed-out or
blocked check as passed.

## Workflow contract

Validate that:

- `backend-policy.md` is the canonical source and the mirrors only point to or
  summarize it;
- `internal_subagent_backend=opencode`, `internal_subagent_transport=direct_mcp`
  and `internal_subagent_policy=writer_only` are present;
- text sidecars use `opencode_worker` directly, with the pinned model/variant,
  durable `JOB_DIR`, `run_agent`, `start_agent`, `get_agent_status`,
  `get_agent_result` and `cancel_agent` exposed;
- native `scout`, `researcher`, `reviewer` and `worker` profiles return
  `NATIVE_ROUTE_BLOCKED` under the OpenCode backend;
- readers deny `edit` and `bash`, writers allow only `edit`, deny `bash` and
  nested `task`, and every writer brief carries claim-map,
  `WRITER_WORKTREE` and `WRITER_BASELINE`;
- the writer loop has W1, repair W2, read-only GPT diagnosis and fresh W3, with
  no GPT-authored patch fallback;
- `NESTED_REQUIRED` requires `NESTED_DELEGATION=used`, while unavailable
  nested `task` returns `NESTED_DELEGATION=blocked`;
- `accepted` is non-terminal, a live heartbeat permits waiting, and stale or
  unknown status triggers diagnosis rather than blind waiting.

## Runtime smoke

Use a fresh direct MCP request only for validation. For a bounded smoke use
`run_agent`; for a progress test use `start_agent`, record its `job_id`, call
`get_agent_status` after a meaningful wait, and call `get_agent_result` only
when `result_available=true` or the job is terminal. Verify that the main
checkout is unchanged. Do not use a native reviewer as the test subject.

For a nested-delegation test, send a reader a brief containing two explicit
fronts and `NESTED_REQUIRED=<front-a,front-b>`. Accept only a result containing
`NESTED_DELEGATION=used` and evidence from both fronts. A blocked nested tool
must remain blocked.

For a writer smoke, use a disposable clean isolated worktree and a claim-map;
compare the returned diff against the baseline and allowed paths before any
mechanical merge. Do not use the main checkout as the writer worktree.

## Other checks

- `git diff --check` and targeted repository validation must pass.
- Run `scripts/validate.ps1` and the skill creator quick validator.
- After source changes, run `scripts/install.ps1 -Profile safe` and validate
  installed workflow files, OpenCode role definitions and native guards.
- Run AHK syntax validation only when `AutoHotkey64.exe` is available.
- If `.codegraph` exists, validate availability and use it for structural
  checks; if it has no relevant result, fall back to targeted reads.

## AHK prompt pad

```powershell
$script = Join-Path $env:USERPROFILE 'Documents\Codex\PromptPad\codex_prompt_pad.ahk'
$exe = (Get-Command AutoHotkey64.exe -ErrorAction Stop).Source
& $exe /ErrorStdOut /Validate $script
```

Restart only the process running that exact script and verify the new PID.

## Final report

Report files touched, checks run, relevant failures, skipped checks and why,
route evidence, regression risk and remaining work.
