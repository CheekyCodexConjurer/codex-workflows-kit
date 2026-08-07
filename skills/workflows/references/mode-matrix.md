# Mode Matrix

The canonical launcher is `$workflows mode=<MODE>`. Compatibility aliases use
the same entries and gates. Text after the mode is task context or an explicit
override.

## Shared route

The installed route is:

```text
GPT orchestrator -> native watcher (agent_type=watcher) -> opencode_worker MCP -> OpenCode role
```

The GPT parent owns plan, diagnosis, tests, diff inspection and acceptance;
it never authors a code patch. It spawns the native watcher for every normal
reader, reviewer and worker handoff and never calls `opencode_worker`
`run_agent`/`start_agent` directly for normal work; its own exposure is
status/result/cancel for declared recovery. The native `scout`, `researcher`,
`reviewer` and `worker` profiles are blocked while
`internal_subagent_backend=opencode`. The native `watcher` is a transport-only
exception; it does not analyze or edit. The native relay is visual preflight
only. Each watcher brief carries the explicit `OPEN_CODE_ROLE` token in
{scout, researcher, reviewer, worker}; the watcher never guesses a role, and
the parent attaches only the sanitized text-only `[VISUAL_PACKET v1]` — never
paths, bytes, base64, data URLs, and never direct image reading by the
OpenCode (DeepSeek) model. The only implementation role is the OpenCode
`worker` in a clean isolated
worktree with claim-map, `WRITER_WORKTREE` and `WRITER_BASELINE`.

Fan-out is mandatory per `sidecar-gate`: any non-trivial task, any task with
two or more independent fronts, an explicit user request for sub-agents,
shared/core or contract risk, or an explicit review/test obligation requires
one or more read-only readers, even without a wall-clock gain; required fronts
are never absorbed locally. Only strictly simple, serial, one-surface tasks
stay local.

For normal long work the watcher keeps one `run_agent` call open, so the parent
chat does not poll. `start_agent` with a retained `job_id` is an explicit
detached/recovery exception used only after the route is declared and evidence
requires it; consult `get_agent_status` at a decision checkpoint. A live
running heartbeat permits waiting; a terminal/result-available job permits
result retrieval. Stale or unknown evidence requires diagnosis and then
repair, replan or block.

For two or more independent uncovered reader fronts, include
`NESTED_REQUIRED=<fronts>`. The OpenCode reader must delegate one read-only
nested task per front, integrate all results, and return
`NESTED_DELEGATION=used`. Missing `task` returns `NESTED_DELEGATION=blocked`.
Simple/serial work stays local; writers never delegate.

## Modes

| Mode | Default sidecar role(s) | Writer allowance | Fan-out required | Join/blocked |
|---|---|---|---|---|
| `PLAN.AUTO` | reader `scout` | writer-free (no-edit) | `sidecar-gate`; escalate to `PLAN`/`P.DEEP` | join required readers before route report |
| `PLAN` | reader `scout` | writer-free (no-edit) | `sidecar-gate` | join readers before plan final |
| `P.DEEP` | readers `researcher`/`scout` | writer-free (no-edit) | `sidecar-gate`; ownership/refactor unclear | join before phase graph and claim-map |
| `RESEARCH.DEEP` | reader `researcher` | writer-free (no-edit) | `sidecar-gate`; non-overlapping fronts | join all before recommendation |
| `IMPL.AUTO` | reader `scout` preflight | routes to `IMPL`/`IMPL.PHASE` | `sidecar-gate` | route decided by evidence; stop without approval |
| `IMPL` | reader `reviewer` at delivery gate | OpenCode `worker` writer loop | `sidecar-gate` | worker merge gates; review after freeze |
| `IMPL.PHASE` | reader `reviewer` at phase gates | OpenCode `worker` per phase | `sidecar-gate` per phase | phase validation before next phase |
| `DELIVER.AUTO` | readers `scout`/`reviewer` | OpenCode `worker` units | `sidecar-gate` | review-batch after integrated-freeze; never commit |
| `REVIEW` | reader `reviewer` | writer-free (no-edit) | one reviewer on the frozen diff; more lenses for 2+ fronts | join reviewers before verdict |
| `COMMIT` | reader `scout` per `sidecar-gate` | writer-free; parent-owned git/index | `sidecar-gate`; required for non-trivial/coverage/contract/multi-front; only strictly simple serial one-surface stays local | join required scout evidence before commit; missing evidence blocks |
| `BUG.INV` | readers `scout`/`researcher` | writer-free (no-edit) | `sidecar-gate`; 2+ hypotheses | join before root-cause conclusion |
| `BUG.FIX` | reader `reviewer` at gate | OpenCode `worker` writer loop | `sidecar-gate` | worker gates; regdiff before close |
| `DEBUG` | readers `researcher`/`scout` | OpenCode `worker` repairs | `sidecar-gate`; per blocker | functional-gate before clean-gate |
| `REWORK` | readers `researcher`/`scout` | writer-free (no-edit) | `sidecar-gate` | join before rework roadmap |
| `R.A.F.V` | readers `reviewer`/`scout` | OpenCode `worker` fixes | `sidecar-gate` | fix-batch revalidate before close |
| `TN.SKILL` | readers `researcher`/`reviewer` | writer-free (no-edit) | `sidecar-gate` | join before quality roadmap |

Mode notes:

- `PLAN.AUTO`: default no-edit plan; use `PLAN`, escalating to `P.DEEP` only
  when ownership, dependencies, refactor or blast are unclear.
- `PLAN`: concise plan with files, risks, dependencies and validation.
- `P.DEEP`: deep no-edit architecture/rework plan; compare adapt-existing with
  earned rework and return a phase graph and claim-map.
- `RESEARCH.DEEP`: no-edit web/GitHub/literature research; load `research.md`,
  screen academic relevance, use non-overlapping researcher fronts per
  `sidecar-gate`, and return source ledger, citations, recommendation and
  roadmap.
- `IMPL.AUTO`: route to `IMPL` or `IMPL.PHASE` after scope is clear.
- `IMPL`: execute approved scope through the OpenCode writer loop.
- `IMPL.PHASE`: execute approved phases, validating each before continuing.
- `DELIVER.AUTO`: consume the approved delivery contract, execute all approved
  writer units, freeze the integrated diff, review once, fix in one batch and
  close only when acceptance and validation pass. Never commit.
- `REVIEW`: no-edit review of a frozen diff; a read-only OpenCode reviewer is
  the default sidecar.
- `COMMIT`: parent-owned git/index operation; a non-trivial, coverage-check,
  contract or multi-front commit requires a read-only scout through the
  watcher, joined before the commit and blocking without it; a strictly simple
  serial one-surface commit may stay local. Never push unless explicitly
  requested.
- `BUG.INV`: no-edit root-cause investigation; writer-free.
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
`validation.md` owns the evidence contract for MCP route, watcher bridge,
writer loop, nested-delegation markers, job status, installed mirrors and
no-native bypass.

## Permissions

- Reader: OpenCode `edit: deny`, `bash: deny`; `task: allow` only when
  `NESTED_REQUIRED` requires it.
- Worker: OpenCode `edit: allow`, `bash: deny`, `task: deny`,
  `external_directory: deny`; claim-map and isolated worktree are mandatory.
- Watcher: native transport-only bridge spawned with `agent_type=watcher`,
  `gpt-5.6-luna` and `high` effort; requires the explicit `OPEN_CODE_ROLE`
  token and holds one `run_agent` call per handoff.
- Native analytical roles: blocked under the default backend.
