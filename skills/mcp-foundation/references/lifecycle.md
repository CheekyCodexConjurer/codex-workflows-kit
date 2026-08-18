# MCP Lifecycle & Maintenance

Operational procedures for safe inspection, mirror verification, and controlled process shutdown.

## Mirror Verification

- Canonical skill mirrors (`skills/workflows`, `skills/evidence-first`, `skills/mcp-foundation`) and host templates (`codex/AGENTS.md`, `antigravity/GEMINI.md`) are tracked by SHA256 checksums in the install state.
- `scripts/doctor.ps1` runs in read-only mode to detect drift or stale copies without altering disk state.

## Serena Shutdown Gate

When an explicit manual request is received to terminate or cycle a Serena process, enforce the following safety checks before proceeding:

1. **Explicit Request**: Automatic shutdowns during normal task flow are strictly prohibited.
2. **Ownership Check**: Verify the process PID matches the active workspace instance and belongs to the current user session.
3. **Idleness Verification**: Ensure no active LSP transactions, tool calls, or locks are held.
4. **Absence of Jobs**: Confirm all parent orchestration jobs and sub-agent fronts are completed and closed.
5. **No Generic Kill**: Never run `taskkill` or wildcard process sweeps.

## Automation Prohibitions

- Auto-init: Never initialize indexes or workspace databases automatically when markers (such as `.codegraph`) are missing.
- Auto-restart: Never restart MCP processes automatically on transient errors; report the status cleanly.
- Auto-upgrade: Upgrades to MCP packages or binaries must be performed manually by the operator.
