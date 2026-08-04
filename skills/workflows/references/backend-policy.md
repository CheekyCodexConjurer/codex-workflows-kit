# Internal Sub-Agent Backend Policy

internal_subagent_backend=opencode
internal_subagent_transport=native_relay

This is private routing state for the Codex/Antigravity adapter of the
installed `workflows` skill. It is
not part of the user-facing compact syntax. Do not ask the user to append a
provider or transport flag to any prompt.

## Default OpenCode route

- When the active value is `opencode`, the parent creates a fresh native relay
  for each sidecar request with `multi_agent_v1__spawn_agent` and
  `agent_type=relay`. The relay omits `fork_context`, `model`, and
  `reasoning_effort`, receives `{target_agent,cwd,task}`, calls the
  configured `opencode_worker` MCP without a session identifier, and returns
  the original response as a native sub-agent result.
- A completed relay is not reused for a later prompt. Every prompt therefore
  starts an isolated MCP conversation and there is no continuation state to
  persist or forward. A completed relay remains open and counts toward host
  concurrency until it is closed; after integrating its final response, close
  it to release the slot. A slot-occupied spawn failure follows
  `subA-slot-full`, not backend-unavailability fallback.
- For a one-step read-only smoke or health test with explicit
  `{target_agent,cwd,task}`, use the fast path: do not read repository or
  backend files before the spawn. In a new Desktop relay, the MCP function can
  be deferred, so activate its known capability through the relay's one exact
  `tool_search`, then call only `opencode_worker`; a missing result remains
  blocked rather than searching for another connector.
- The parent continues useful work and joins the relay at the decision/final
  gate. OpenCode `worker` handles claim-map-scoped edits in the supplied
  isolated worktree through the same relay and MCP. Before spawning it, the
  parent verifies `cwd` is the isolated worktree root, differs from the main
  checkout, has a clean baseline, and passes `WRITER_WORKTREE=<cwd>` plus
  `WRITER_BASELINE=<full-commit>`. Afterward, the parent compares the diff to
  the baseline and allowed paths before integration. The parent remains
  responsible for reviewing diffs, running integrated tests, and merging; for
  small or critical integration edits it may write directly. The native
  `worker` profile is only an explicit `internal_subagent_backend=native`
  maintenance override.
- The native relay uses GPT-5.4 Mini with `high`; result-bearing native profiles
  use GPT-5.4 Mini with `xhigh`.
- The mode still owns the decision to use a sidecar; the backend policy does not
  force an unnecessary sub-agent on simple work.

## Relay and OpenCode permissions

- `agents/relay.toml` is the native transport profile. Its own context is
  read-only, but it forwards reader and explicit claim-map writer work to
  `mcp__opencode_worker__run_agent`, preserves the original response, and never
  falls back to a native or direct-CLI provider. For `worker`, `cwd` must equal
  the absolute isolated worktree root and the task must carry matching
  `WRITER_WORKTREE`/`WRITER_BASELINE` tokens; the parent owns the filesystem
  preflight and post-return diff guard.
- The Desktop may defer MCP tools in a new relay. The relay performs exactly
  one built-in `tool_search` for its already-known exact MCP function before
  calling it; this is activation rather than broad tool/route discovery. A
  missing result remains a blocked route.
- All standard OpenCode read-only sub-agents may use the OpenCode `task` tool
  and read paths through `external_directory`. Their per-agent definitions
  must still deny `edit` and `bash`; `question`, `skill`, `todowrite`, and `lsp`
  remain denied unless a future definition explicitly documents a safe
  exception. The OpenCode `worker` definition is the sole default exception:
  it allows `edit`, denies `bash` and nested `task`, and uses only the supplied
  isolated worktree with `external_directory: deny`. The parent runs
  validation and owns integration.
- `sub-agents-mcp@0.12.0` exposes only coarse permission levels. Its
  `AGENT_PERMISSION=read-only` hard-denies `task` and `external_directory`, so
  this route uses `AGENT_PERMISSION=yolo` only to remove those two coarse
  denials. Reader agent frontmatter is the effective no-edit boundary;
  validation must reject any read-only definition missing `edit: deny` or
  `bash: deny`, while the sole default writer must have `edit: allow`,
  `bash: deny`, `task: deny`, and `external_directory: deny`.
- The normal `codegraph` MCP may remain enabled. External directory access does
  not authorize arbitrary side-effectful MCP tools or shell commands.

## Explicit native override

`internal_subagent_backend=native` is a private maintenance override. Change it
only after the user explicitly asks to return the sub-agents to the native
Codex/OpenAI route. With that value, all sub-agent roles use the native
profiles, while the workflow and worker ownership rules remain unchanged.

The canonical source is this file in the repository and the synchronized copy
under `C:\Users\mathe\.agents\skills\workflows\references`. Keep both
copies aligned when changing the backend or relay transport.

## Failure rule

If the active backend is `opencode` and its native relay, MCP, CLI, credentials,
model, or variant is unavailable, preserve the required gate as blocked. Never
silently switch to the native backend or direct MCP call. A native switch is
an explicit policy change. A host capacity/full-slot response is a lifecycle
condition: reclaim only completed/idle integrated relays or wait for an optional
relay, then retry the same role; block only when no safe slot recovery or retry
remains.

The legacy `sub-agent=opencode` token is compatibility-only and must not be
surfaced as a required user prompt flag.
