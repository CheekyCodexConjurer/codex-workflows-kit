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

## DeepSeek Sub-Agent Daemon Operational Recovery Matrix (Fail-Closed)

Operating policy for the local owned DeepSeek Sub-Agent daemon under standing explicit user authorization on this host. Maintenance across other MCP servers remains read-only.

### Absolute Boundaries & Non-Triggers

- **Antigravity Protection**: Never restart, close, login, or logout Antigravity desktop. Never touch auth, profile, cookies, or cache.
- **Strict Scope**: Never restart Codex, Serena, CodeGraph, Context7, or any other MCP servers. Never run generic kill commands (`taskkill`, `Stop-Process`, `kill-all`).
- **Non-Triggers**: Never trigger on `AntigravityProcessError`, agy job failures, HTTP errors alone, provider/model timeouts, or quota errors. No provider/model fallback.
- **Budget**: Bounded single attempt per incident. If recovery fails, report blocked status with evidence; never loop or retry indefinitely.
- **Job Preservation**: Active jobs only allow recovery when all have proven durable spool/recovery in `bridge.sqlite`. Stale-running with absent daemon reconciles only with installed durable capacity; do not assume database status alone indicates live activity. Fail closed if unproven.
- **Lineage**: After ready, resume, follow, or recover the original job via the same lineage; never duplicate front, agent, or logical job.
- **Timeout Differentiation & Liveness**: Bounded timeouts for transport, handshake, probe/health (`GET /health`), and connect remain active and bounded; differentiate them explicitly from execution timeout. Accepted and healthy jobs run indefinitely under events, heartbeat, and lease; no window of 900s, 20m, or 25m proves failure or triggers graceful finalize or abort. An expired lease alone does not prove death; takeover or termination requires verified PID absence, dead process, heartbeat verification, fence token check, quiescence, or a persisted terminal error.

### Operational Decision Matrix

| Observed State | Probe / Evidence Gate | Required Action | Boundary / Verification |
|---|---|---|---|
| Transport closed + health ready | MCP transport fails or closes, but `GET /health` probe is ready | Reconnect / retry MCP call | Never restart daemon or Antigravity; no process kill |
| `recovering` | `GET /health` returns starting or recovering status | Await bounded readiness | Poll `GET /health` until ready or timeout; no duplicate start or restart |
| `absent` | Daemon process missing; `GET /health` probe unreachable | Canonical start: `dist/cli.js start --config <known-config> --json` | Verify PID, command line, and data directory ownership; await bounded readiness on `GET /health`; stale-running jobs require proven durable capacity |
| `owned-unhealthy` | Daemon process alive, PID/command/data-dir ownership verified, but `GET /health` fails | Canonical restart: `dist/cli.js restart --config <known-config> --json` | Restart only if PID, command line, and data directory ownership are verified and `GET /health` fails; await bounded readiness; active jobs require proven durable spool |

### Required Fail-Closed Gates (All Must Pass)

1. **Explicit Authorization**: Standing explicit user authorization on this host allows diagnosing and recovering the owned local DeepSeek daemon without per-incident prompts.
2. **Probe Check**: Diagnostic `GET /health` probe determines state (`ready`, `recovering`, `absent`, or `owned-unhealthy`).
3. **Ownership Verification**: Verified PID, command line, and data directory ownership matching current user configuration.
4. **Active Jobs Gate**: Query `bridge.sqlite`: active jobs only allow recovery when all have proven durable spool/recovery; otherwise fail-closed.
5. **Bounded Single Attempt**: Execute at most one canonical start/restart/reconnect attempt with bounded readiness on `GET /health`. Fail-closed on error.

## Automation Prohibitions

- Auto-init: Never initialize indexes or workspace databases automatically when markers (such as `.codegraph`) are missing.
- Auto-restart: Never restart MCP processes automatically outside the explicitly authorized fail-closed DeepSeek daemon exception; report the status cleanly.
- Auto-upgrade: Upgrades to MCP packages or binaries must be performed manually by the operator.
