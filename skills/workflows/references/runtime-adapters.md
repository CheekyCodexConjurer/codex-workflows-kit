# Runtime adapters

`$workflows` is one workflow contract with host-specific execution adapters.
Select the adapter from the tools and agent surfaces actually exposed in the
current session; never infer it from a user-supplied provider flag.

## Common contract

Every adapter must preserve the same:

- `mode=<MODE>` routing and left-to-right alias expansion;
- evidence, no-edit, write, review, commit, and clean-gate boundaries;
- sub-agent role lock, claim maps, validation, and no-silent-fallback rules;
- parent ownership of integration when OpenCode is selected, with delegated
  claim-map writes performed by OpenCode through the watcher bridge on the
  exposed MCP.

An adapter may change how a tool or sub-agent is invoked. It must not change
what the mode means, weaken a gate, or turn missing capabilities into a
success claim.

## Codex

Normal text readers, reviewers and writers use the native watcher bridge: the
parent spawns the native `watcher` (`agent_type=watcher`, `gpt-5.6-luna`,
`high`) which keeps one `run_agent` call open on the exposed `opencode_worker` MCP
and returns its compact result; it is not an analytical role. Each brief must
carry the explicit `OPEN_CODE_ROLE` token, one of {scout, researcher,
reviewer, worker}; the watcher never guesses a role. The parent
never calls `run_agent`/`start_agent` directly for normal work; its exposure is
status/result/cancel for declared recovery. For detached jobs and recovery,
`start_agent` is an explicit exception used only after the route is declared
and evidence requires it: the parent keeps the returned `job_id`, consults
status at progress checkpoints, and owns integration. Native analytical
profiles are blocked while the OpenCode backend is active. A native relay is
permitted only to convert real image items into a text-only
`[VISUAL_PACKET v1]`; attachment paths and raw image data never reach OpenCode.

## Google Antigravity

Use the Antigravity-native tool and agent surface that is actually exposed in
the current session. Keep the common mode and validation contract; do not
assume that Codex-only MCP, relay, or transport names are available. If a
required capability is not exposed, report the gate as blocked rather than
falling back silently.

## OpenCode

Use the configured `opencode_worker` MCP and role definitions for `scout`,
`researcher`, `reviewer`, and `worker`, reached through the native watcher
bridge for normal handoffs. Read-only roles must not edit or run shell
commands. Writable workers remain claim-map and isolated-worktree scoped
and must pass their merge gate before integration. Each request starts a fresh
job without a session identifier.

## User-facing syntax

The canonical form is:

```text
$workflows mode=BUG.INV
```

`$codex-workflows`, `$antigravity-workflows`, and `$opencode-workflows` are
temporary compatibility forms generated from the same canonical source.
