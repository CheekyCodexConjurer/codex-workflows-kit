# MCP Lifecycle & Maintenance

Operational procedures for safe inspection, mirror verification, controlled process shutdown, and authorized DeepSeek daemon recovery.

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

## DeepSeek Sub-Agent Daemon Restart Policy (Fail-Closed Exception)

Automatic restarts, kill operations, and process recycling remain strictly forbidden by default. A tightly scoped, fail-closed exception is permitted only when all of the following gates pass:

### 1. Preconditions & Boundaries
- **Express Human Authorization**: The current user must provide explicit user authorization for recovery of the local owned DeepSeek Sub-Agent daemon. Never initiate recovery autonomously.
- **Non-Triggers (Strictly Prohibited)**:
  - Never trigger on `AntigravityProcessError` or `agy` job failures.
  - Never trigger on generic provider, model, or tool execution errors.
  - Never trigger on an HTTP error response alone without executing the health probe gate.
- **Strict Scope Boundaries**:
  - Never restart Codex, Antigravity, Serena, CodeGraph, Context7, or any other MCP servers.
  - Never run `taskkill`, `Stop-Process`, `kill-all`, or generic process sweep commands.
  - Never create provider fallback, automatic retries, or warm-up/replay logic.

### 2. Required Fail-Closed Gates (All Must Pass)
1. **Pre-Restart Probe Failure**: A fresh GET `/health` probe (the canonical bridge endpoint is `/health`) demonstrably fails (connection refused, timeout, or unhealthy status).
2. **Canonical Lifecycle Command**: The daemon is launched strictly from a validated canonical `deepseek-subagent` installation using the official lifecycle command:
   `dist/cli.js restart --config <known-config> --json`
3. **Ownership Verification**: Verified PID, command line, and data directory ownership matching the current user session and configuration.
4. **Zero Active Jobs in SQLite**: A read-only query against `bridge.sqlite` confirms there are no active or pending jobs.
5. **Bounded Readiness Wait**: After executing the canonical command, perform a bounded readiness wait with GET `/health` until the daemon returns healthy.
6. **Fail-Closed Abort**: If any gate fails, is uncertain, or cannot be verified, do NOT restart; report the failure cleanly.

## Automation Prohibitions

- Auto-init: Never initialize indexes or workspace databases automatically when markers (such as `.codegraph`) are missing.
- Auto-restart: Never restart MCP processes automatically on transient errors outside the explicitly authorized fail-closed DeepSeek daemon exception; report the status cleanly.
- Auto-upgrade: Upgrades to MCP packages or binaries must be performed manually by the operator.
