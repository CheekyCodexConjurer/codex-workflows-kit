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
  claim-map writes performed by OpenCode through the native relay.

An adapter may change how a tool or sub-agent is invoked. It must not change
what the mode means, weaken a gate, or turn missing capabilities into a
success claim.

## Codex

Use the native Codex tool and agent surface. When a read-only or claim-map
writer sidecar is required, follow `references/backend-policy.md` and create a
fresh configured native relay for that request. The relay owns transport and
isolation; OpenCode owns delegated writer edits, while the main agent owns
integration and final quality. Native workers remain only for the explicit
native-backend maintenance override.

## Google Antigravity

Use the Antigravity-native tool and agent surface that is actually exposed in
the current session. Keep the common mode and validation contract; do not
assume that Codex-only MCP, relay, or transport names are available. If a
required capability is not exposed, report the gate as blocked rather than
falling back silently.

## OpenCode

Use OpenCode's configured Task surface and the role definitions for
`scout`, `researcher`, `reviewer`, and `worker`. Read-only roles must not edit
or run shell commands. Writable workers remain claim-map and isolated-worktree
scoped and must pass their merge gate before integration. Each request starts a fresh task
conversation; session persistence and continuation reuse are disabled.

## User-facing syntax

The canonical form is:

```text
$workflows mode=BUG.INV
```

`$codex-workflows`, `$antigravity-workflows`, and `$opencode-workflows` are
temporary compatibility forms generated from the same canonical source.
