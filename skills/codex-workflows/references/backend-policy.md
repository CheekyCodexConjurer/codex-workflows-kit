# Internal Sub-Agent Backend Policy

internal_subagent_backend=opencode
internal_subagent_transport=native_relay

This is private routing state for the installed `codex-workflows` skill. It is
not part of the user-facing compact syntax. Do not ask the user to append a
provider or transport flag to any prompt.

## Default OpenCode route

- When the active value is `opencode`, the main Codex chat first spawns the
  native read-only `relay` profile in the background. The relay calls the
  configured `opencode_worker` MCP for the requested read-only agent and
  returns the original response as a native sub-agent result.
- Invoke `multi_agent_v1__spawn_agent` with `agent_type=relay`; omit
  `fork_context`, `model`, and `reasoning_effort`, and put only
  `{target_agent,cwd,task}` in the relay message.
- The parent chooses any configured OpenCode read-only agent (`scout`,
  `researcher`, `reviewer`, or a future read-only definition) and passes only
  `{target_agent,cwd,task}` to the relay. The parent continues useful work and
  joins the relay at the decision/final gate.
- The mode still owns the decision to use a sidecar; the backend policy does not
  force an unnecessary sub-agent on simple work.
- Native workers remain responsible for every write, patch, test, and
  claim-map-scoped implementation.

## Relay and OpenCode permissions

- `agents/relay.toml` is the native transport profile. It is read-only,
  forwards only to `mcp__opencode_worker__run_agent`, preserves the original
  response, and never falls back to a native or direct-CLI provider.
- All configured OpenCode sub-agents may use the OpenCode `task` tool and read
  paths through `external_directory`. Their per-agent definitions must still
  deny `edit` and `bash`; `question`, `skill`, `todowrite`, and `lsp` remain
  denied unless a future definition explicitly documents a safe exception.
- `sub-agents-mcp@0.12.0` exposes only coarse permission levels. Its
  `AGENT_PERMISSION=read-only` hard-denies `task` and `external_directory`, so
  this route uses `AGENT_PERMISSION=yolo` only to remove those two coarse
  denials. The OpenCode agent frontmatter is the effective no-edit boundary;
  validation must reject any definition missing `edit: deny` or `bash: deny`.
- The normal `codegraph` MCP may remain enabled. External directory access does
  not authorize arbitrary side-effectful MCP tools or shell commands.

## Explicit native override

`internal_subagent_backend=native` is a private maintenance override. Change it
only after the user explicitly asks to return the sub-agents to the native
Codex/OpenAI route. With that value, all sub-agent roles use the native
profiles, while the workflow and worker ownership rules remain unchanged.

The canonical source is this file in the repository and the synchronized copy
under `C:\Users\mathe\.agents\skills\codex-workflows\references`. Keep both
copies aligned when changing the backend or relay transport.

## Failure rule

If the active backend is `opencode` and its native relay, MCP, CLI, credentials,
model, or variant is unavailable, preserve the required gate as blocked. Never
silently switch to the native backend or direct MCP call. A native switch is
an explicit policy change.

The legacy `sub-agent=opencode` token is compatibility-only and must not be
surfaced as a required user prompt flag.
