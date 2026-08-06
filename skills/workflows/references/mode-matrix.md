# Mode Matrix

The canonical launcher is `$workflows mode=<MODE>`. Compatibility aliases use
the same entries and gates. Text after the mode is task context or an explicit
override.

## Shared route

The installed route is:

```text
GPT orchestrator -> opencode_worker MCP -> OpenCode role
```

The GPT parent owns plan, diagnosis, tests, diff inspection and acceptance;
it never authors a code patch. The native `scout`, `researcher`, `reviewer`
and `worker` profiles are blocked while `internal_subagent_backend=opencode`.
The native relay is visual preflight only. The only implementation role is the
OpenCode `worker` in a clean isolated worktree with claim-map,
`WRITER_WORKTREE` and `WRITER_BASELINE`.

For long work use `start_agent`, retain `job_id`, and consult
`get_agent_status` at the first prolonged-wait or decision checkpoint. A live
running heartbeat permits waiting; a terminal/result-available job permits
result retrieval. Stale or unknown evidence requires diagnosis and then
repair, replan or block.

For two or more independent uncovered reader fronts, include
`NESTED_REQUIRED=<fronts>`. The OpenCode reader must delegate one read-only
nested task per front and integrate all results. Missing `task` returns
`NESTED_DELEGATION=blocked`. Simple/serial work stays local; writers never
delegate.

## Modes

- `PLAN.AUTO`: default no-edit plan; use `PLAN`, escalating to `P.DEEP` only
  when ownership, dependencies, refactor or blast are unclear.
- `PLAN`: concise plan with files, risks, dependencies and validation.
- `P.DEEP`: deep no-edit architecture/rework plan; compare adapt-existing with
  earned rework and return a phase graph and claim-map.
- `RESEARCH.DEEP`: no-edit web/GitHub/literature research; load `research.md`,
  screen academic relevance, use non-overlapping researcher fronts when useful,
  and return source ledger, citations, recommendation and roadmap.
- `IMPL.AUTO`: route to `IMPL` or `IMPL.PHASE` after scope is clear.
- `IMPL`: execute approved scope through the OpenCode writer loop.
- `IMPL.PHASE`: execute approved phases, validating each before continuing.
- `DELIVER.AUTO`: consume the approved delivery contract, execute all approved
  writer units, freeze the integrated diff, review once, fix in one batch and
  close only when acceptance and validation pass. Never commit.
- `REVIEW`: no-edit review of a frozen diff; use a read-only OpenCode reviewer
  only as a test/review sidecar.
- `COMMIT`: parent-owned git/index operation; validate coverage and never push
  unless explicitly requested.
- `BUG.INV`: no-edit root-cause investigation; no writer.
- `BUG.FIX`: approved fix through the OpenCode writer loop.
- `DEBUG`: root-cause-first repair through writer -> verify -> diagnosis ->
  fresh writer until functional or blocked.
- `REWORK`: no-edit simplification plan; remove duplicated policy, preserve
  behavior and validate the bounded rework.
- `R.A.F.V`: bounded audit/fix loop through the same writer contract; no commit.
- `TN.SKILL`: no-edit quality audit and rework roadmap.

## Quality and validation

Use the quality-ratchet profile assigned by the mode. Start with targeted
checks, broaden for shared contracts, and record `quality-delta` for changes.
Two or more phases require `update_plan` transitions at phase boundaries.
`validation.md` owns the evidence contract for MCP route, writer loop,
nested-delegation markers, job status, installed mirrors and no-native bypass.

## Permissions

- Reader: OpenCode `edit: deny`, `bash: deny`; `task: allow` only when
  `NESTED_REQUIRED` requires it.
- Worker: OpenCode `edit: allow`, `bash: deny`, `task: deny`,
  `external_directory: deny`; claim-map and isolated worktree are mandatory.
- Native analytical roles: blocked under the default backend.
