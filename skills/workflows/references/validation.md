# Validation

Start with checks tied to the changed behavior. Broaden for shared contracts,
then stop when the acceptance gate is proven. Never report a timed-out or
blocked check as passed.

## Workflow contract

Validate that:

- `backend-policy.md` is the canonical source and the mirrors only point to or
  summarize it;
- `internal_subagent_backend=opencode`, `internal_subagent_transport=native_watcher_mcp`
  and `internal_subagent_policy=writer_only` are present;
- normal text sidecars use the native watcher bridge
  (`parent -> watcher (agent_type=watcher) -> opencode_worker MCP -> exact
  OpenCode role`), the parent never calls `run_agent`/`start_agent` directly
  for normal work, and its exposure is status/result/cancel for declared
  recovery, with the pinned model/variant, durable `JOB_DIR`, `run_agent`,
  `start_agent`, `get_agent_status`, `get_agent_result` and `cancel_agent`
  carried by the installed watcher profile;
- the watcher profile is rendered from portable placeholders during install and
  makes exactly one `run_agent` call per handoff; required readers, reviewers
  and watchers block their gate if unavailable;
- the mandatory sidecar trigger (`sidecar-gate`) covers any non-trivial task,
  any task with two or more independent fronts, an explicit user request for
  sub-agents, shared/core or contract risk, and explicit review/test
  obligations, even without a wall-clock gain;
- native `scout`, `researcher`, `reviewer` and `worker` profiles return
  `NATIVE_ROUTE_BLOCKED` under the OpenCode backend;
- native `watcher.toml` is read-only, pins `gpt-5.6-luna` with `high` effort,
  carries the full handoff MCP config, calls only the MCP handoff, and returns
  `WATCHER_ROUTE_BLOCKED` for analysis or editing;
- every watcher handoff brief carries the explicit `OPEN_CODE_ROLE` token in
  {scout, researcher, reviewer, worker} and the watcher never guesses a role;
  a missing or invalid token blocks (`WATCHER_STATUS=blocked`) before the MCP
  call;
- when images are attached, the parent attaches only the sanitized text-only
  `[VISUAL_PACKET v1]` to the watcher brief and the MCP OpenCode role — never
  image paths, bytes, base64, data URLs, and never direct image reading by the
  OpenCode (DeepSeek) model;
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

A direct MCP request for `run_agent`/`start_agent` is never normal parent work.
For a bounded smoke, exercise `run_agent` only through the native watcher
handoff, which must keep one MCP call open and return one compact envelope;
parent-exposed `get_agent_status`/`get_agent_result`/`cancel_agent` are used
only for declared recovery. For detached progress use `start_agent` as the
declared exception, record its `job_id`, call `get_agent_status` after a
meaningful wait, and call `get_agent_result` only when `result_available=true`
or the job is terminal. Verify that the main checkout is unchanged. Do not use a native reviewer
as the test subject.

For an OpenCode CLI preflight, run one bounded direct OpenCode CLI smoke
that reproduces the sub-agents-mcp OpenCode invocation: exact role markdown
as system context, same configured model/variant and cwd, role-appropriate
no-edit permissions. Accept only exit success with the explicit
`CLI_PREFLIGHT=passed` evidence token; a failed smoke blocks the MCP route
until the cause is diagnosed and it passes. The smoke is diagnostic only:
it handles no user work, never replaces the watcher -> MCP handoff, and is
not a direct CLI fallback.

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
